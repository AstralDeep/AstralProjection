"""Builds and verifies the pinned Primitives and ROTE wheels using Deep's qualified installer.
Windows and Projection CI install these local wheels after their hash-locked external dependencies.
"""

import argparse
import base64
import binascii
import csv
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PINS = ROOT / "windows-client/presentation-sources.json"
KEYS = ("astral-primitives", "astral-kernel")
VARIABLES = {"astral-primitives": "ASTRAL_PRIMITIVES_WHEEL_URI", "astral-kernel": "ASTRAL_ROTE_WHEEL_URI"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize_metadata_newlines(members):
    metadata_paths = [path for path in members if path.endswith(".dist-info/METADATA")]
    for metadata_path in metadata_paths:
        original = members[metadata_path]
        normalized = original.replace(b"\r\n", b"\n")
        if b"\r" in normalized:
            raise ValueError("wheel metadata contains a bare carriage return")
        if normalized == original:
            continue
        record_path = f"{metadata_path.rsplit('/', 1)[0]}/RECORD"
        if record_path not in members:
            raise ValueError("wheel metadata has no matching RECORD")
        record_directory = record_path.rsplit("/", 1)[0]
        if any(
            path in {f"{record_directory}/RECORD.jws", f"{record_directory}/RECORD.p7s"}
            for path in members
        ):
            raise ValueError("signed wheel metadata cannot be normalized")
        try:
            record_bytes = members[record_path]
            rows = list(
                csv.reader(io.StringIO(record_bytes.decode("utf-8"), newline=""), strict=True)
            )
        except (UnicodeDecodeError, csv.Error) as error:
            raise ValueError("wheel RECORD is invalid") from error
        matching_rows = [row for row in rows if row and row[0] == metadata_path]
        if len(matching_rows) != 1 or len(matching_rows[0]) != 3:
            raise ValueError("wheel RECORD has no unique metadata entry")
        original_row = matching_rows[0].copy()
        row = original_row.copy()
        algorithm, separator, encoded_digest = row[1].partition("=")
        if algorithm != "sha256" or not separator or row[2] != str(len(original)):
            raise ValueError("wheel RECORD metadata digest or size is invalid")
        try:
            recorded_digest = base64.b64decode(
                encoded_digest + "=" * (-len(encoded_digest) % 4), altchars=b"-_", validate=True
            )
        except (ValueError, binascii.Error) as error:
            raise ValueError("wheel RECORD metadata digest is invalid") from error
        if (
            base64.urlsafe_b64encode(recorded_digest).rstrip(b"=").decode("ascii") != encoded_digest
            or recorded_digest != hashlib.sha256(original).digest()
        ):
            raise ValueError("wheel RECORD metadata digest is invalid")
        digest_value = base64.urlsafe_b64encode(hashlib.sha256(normalized).digest())
        row[1] = "sha256=" + digest_value.rstrip(b"=").decode("ascii")
        row[2] = str(len(normalized))
        rewritten_lines = []
        replacements = 0
        for line in record_bytes.splitlines(keepends=True):
            if line.endswith(b"\r\n"):
                body, line_ending = line[:-2], b"\r\n"
            elif line.endswith(b"\n"):
                body, line_ending = line[:-1], b"\n"
            elif line.endswith(b"\r"):
                raise ValueError("wheel RECORD uses bare carriage returns")
            else:
                body, line_ending = line, b""
            try:
                parsed = next(csv.reader([body.decode("utf-8")], strict=True))
            except (UnicodeDecodeError, csv.Error) as error:
                raise ValueError("wheel RECORD is invalid") from error
            if parsed and parsed[0] == metadata_path:
                output = io.StringIO(newline="")
                writer = csv.writer(output, lineterminator="\n")
                writer.writerow(original_row)
                expected_old_line = output.getvalue().encode("utf-8")[:-1] + line_ending
                if expected_old_line != line:
                    raise ValueError("wheel RECORD metadata row is not canonical CSV")
                output = io.StringIO(newline="")
                csv.writer(output, lineterminator="\n").writerow(row)
                line = output.getvalue().encode("utf-8")[:-1] + line_ending
                replacements += 1
            rewritten_lines.append(line)
        if replacements != 1:
            raise ValueError("wheel RECORD has no unique metadata entry")
        members[metadata_path] = normalized
        members[record_path] = b"".join(rewritten_lines)


def normalize_wheel_archive(path):
    temporary = path.with_suffix(path.suffix + ".normalized")
    try:
        with zipfile.ZipFile(path, "r") as source:
            names = [item.filename for item in source.infolist()]
            if len(names) != len(set(names)):
                raise ValueError("wheel contains duplicate archive members")
            members = {item.filename: source.read(item.filename) for item in source.infolist()}
            normalize_metadata_newlines(members)
            with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as target:
                for item in source.infolist():
                    if item.is_dir() or item.extra or item.comment:
                        raise ValueError("wheel contains noncanonical archive metadata")
                    info = zipfile.ZipInfo(item.filename, item.date_time)
                    info.compress_type = item.compress_type
                    info.create_system = 3
                    info.external_attr = 0o100644 << 16
                    info.internal_attr = 0
                    target.writestr(info, members[item.filename], compress_type=item.compress_type)
        temporary.replace(path)
    except (OSError, zipfile.BadZipFile) as error:
        temporary.unlink(missing_ok=True)
        raise ValueError(f"wheel archive could not be normalized: {path.name}") from error
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def normalize_component_wheels(helper, lock_path):
    lock_document = json.loads(lock_path.read_text())
    for entry in lock_document["components"]:
        wheel = lock_path.parent / entry["wheel"]
        normalize_wheel_archive(wheel)
        entry["wheel_sha256"] = digest(wheel)
    helper._write_lock(lock_path, lock_document)


def wheel_failure_report(helper, contract, lock_path, expected):
    lock_document = json.loads(lock_path.read_text())
    components = {component.key: component for component in contract.components}
    findings = []
    for entry in lock_document["components"]:
        wheel = lock_path.parent / entry["wheel"]
        component = components[entry["component"]]
        with zipfile.ZipFile(wheel, "r") as archive:
            members = [
                {
                    "path": item.filename,
                    "size": item.file_size,
                    "compressedSize": item.compress_size,
                    "sha256": hashlib.sha256(archive.read(item.filename)).hexdigest(),
                    "compression": item.compress_type,
                    "creatorSystem": item.create_system,
                    "externalAttributes": item.external_attr,
                    "timestamp": list(item.date_time),
                }
                for item in archive.infolist()
            ]
        source_root = component.source_root(contract.repository_root)
        source_files = []
        for path in helper._iter_build_files(component, contract.repository_root):
            content = path.read_bytes()
            crlf = content.count(b"\r\n")
            lf = content.count(b"\n")
            source_files.append(
                {
                    "path": path.relative_to(source_root).as_posix(),
                    "size": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "crlfCount": crlf,
                    "bareLfCount": lf - crlf,
                    "bareCrCount": content.count(b"\r") - crlf,
                }
            )
        actual = digest(wheel)
        findings.append(
            {
                "component": component.key,
                "distribution": component.distribution,
                "version": component.version,
                "sourcePath": component.relative_path,
                "sourceSha256": entry["source_sha256"],
                "expectedWheelSha256": expected[component.key],
                "actualWheelSha256": actual,
                "wheelSize": wheel.stat().st_size,
                "sourceFiles": source_files,
                "wheelMembers": members,
            }
        )
    return {"format": "astralprojection.presentation-wheel-failure/v1", "components": findings}


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value


def sources(deep, primitives, kernel):
    pins = json.loads(PINS.read_text())
    if set(pins) != {"format", "deep"} or pins["format"] != "astral.presentation-sources/v1" or set(pins["deep"]) != {"repository", "commit"} or pins["deep"].get("repository") != "https://github.com/AstralDeep/AstralDeep.git":
        raise ValueError("unsupported presentation source pins")
    validator = module(ROOT / "apple-clients/NodePack/local_sources.py", "presentation_sources")
    deep = validator.validate(deep, pins["deep"]["commit"])
    manifest = json.loads((deep / "config/astral-composition.json").read_text())
    roots = {"astral-primitives": primitives, "astral-kernel": kernel}
    for key in KEYS:
        roots[key] = validator.validate(roots[key], manifest["components"][key]["commit"])
    helper = module(deep / "scripts/install_local_components.py", "presentation_installer")
    helper.load_contract(deep, require_sources=False, require_gitlinks=True)
    return helper, deep, roots, manifest


def export(source, commit, target):
    target.mkdir(parents=True)
    with tempfile.TemporaryFile() as archive:
        subprocess.run(["git", "-C", str(source), "archive", commit], stdout=archive, check=True)
        archive.seek(0)
        with tarfile.open(fileobj=archive) as bundle:
            bundle.extractall(target, filter="data")


def expected_hashes():
    text = (ROOT / "windows-client/requirements-release.lock.txt").read_text().replace("\\\n", " ")
    import re

    found = {}
    for key, variable in VARIABLES.items():
        lines = [line for line in text.splitlines() if "${" + variable + "}" in line]
        distribution = "astralprims" if key == "astral-primitives" else "astral-rote"
        if len(lines) != 1 or not lines[0].startswith(distribution + " @ ${" + variable + "}"):
            raise ValueError("the release lock must bind each local presentation wheel")
        hashes = re.findall(r"--hash=sha256:([a-f0-9]{64})", lines[0])
        if len(hashes) != 1:
            raise ValueError("each local presentation wheel needs one exact release hash")
        found[key] = hashes[0]
    return found


def verify(output):
    context = json.loads((output / "context.json").read_text())
    if set(context) != {"deep", "primitives", "kernel"}:
        raise ValueError("invalid local presentation source context")
    helper, deep, _, _ = sources(*(Path(context[key]) for key in ("deep", "primitives", "kernel")))
    committed = subprocess.check_output(["git", "-C", str(deep), "show", "HEAD:config/astral-composition.json"])
    if (output / "source/config/astral-composition.json").read_bytes() != committed:
        raise ValueError("the presentation manifest differs from its pinned source")
    contract = helper.select_components(helper.load_contract(output / "source", require_sources=False), KEYS)
    lock = output / "wheels/astral-component-wheels.lock.json"
    entries = helper._load_lock(contract, lock)
    expected = expected_hashes()
    for entry in entries:
        if entry["wheel_sha256"] != expected[entry["component"]] or digest(lock.parent / entry["wheel"]) != entry["wheel_sha256"]:
            raise ValueError("the local presentation wheel or receipt differs from the release lock")
    helper.verify_install(contract, lock)
    return helper, contract, lock


def build(output, deep, primitives, kernel):
    helper, deep, roots, manifest = sources(deep, primitives, kernel)
    if output.exists():
        raise ValueError("presentation output must be absent")
    output.mkdir(parents=True)
    source = output / "source"
    export(deep, json.loads(PINS.read_text())["deep"]["commit"], source)
    for key in KEYS:
        item = manifest["components"][key]
        target = source / item["path"]
        target.rmdir()
        export(roots[key], item["commit"], target)
    contract = helper.select_components(helper.load_contract(source, require_sources=False), KEYS, require_sources=True)
    os.environ["SOURCE_DATE_EPOCH"] = subprocess.check_output(["git", "-C", str(deep), "show", "-s", "--format=%ct", "HEAD"], text=True).strip()
    helper.build_wheels(contract, output / "wheels", output / "wheels/astral-component-wheels.lock.json")
    (output / "context.json").write_text(json.dumps({"deep": str(deep), "primitives": str(roots[KEYS[0]]), "kernel": str(roots[KEYS[1]])}, sort_keys=True) + "\n")
    wheel_lock = output / "wheels/astral-component-wheels.lock.json"
    normalize_component_wheels(helper, wheel_lock)
    return helper, contract, wheel_lock


def install(output, deep, primitives, kernel, external_lock=None):
    sources(deep, primitives, kernel)
    text = (external_lock or ROOT / "windows-client/requirements-release.lock.txt").read_text().replace("\\\n", " ")
    external = "\n".join(line for line in text.splitlines() if not any("${" + variable + "}" in line for variable in VARIABLES.values()))
    with tempfile.TemporaryDirectory() as temp:
        requirements = Path(temp) / "external.lock"
        requirements.write_text(external + "\n")
        subprocess.run([sys.executable, "-m", "pip", "install", "--require-hashes", "-r", str(requirements)], check=True)
    helper, contract, lock = build(output, deep, primitives, kernel)
    expected = expected_hashes()
    entries = json.loads(lock.read_text())["components"]
    mismatches = [entry for entry in entries if entry["wheel_sha256"] != expected[entry["component"]]]
    if mismatches:
        report = output / "presentation-wheel-failure.json"
        report.write_text(json.dumps(wheel_failure_report(helper, contract, lock, expected), indent=2, sort_keys=True) + "\n")
        details = "; ".join(
            f"{entry['component']}: expected={expected[entry['component']]}, actual={entry['wheel_sha256']}"
            for entry in mismatches
        )
        raise ValueError(f"built presentation wheel differs from the committed release hash ({details}); see {report.name}")
    for entry in entries:
        os.environ[VARIABLES[entry["component"]]] = (lock.parent / entry["wheel"]).as_uri()
    helper.install_wheels(contract, lock)
    verify(output)
    helper.pip_check(ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "install", "verify"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/presentation")
    parser.add_argument("--deep-source", type=Path)
    parser.add_argument("--primitives-source", type=Path)
    parser.add_argument("--kernel-source", type=Path)
    parser.add_argument("--external-lock", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "verify":
            verify(args.output.resolve())
        else:
            if any(value is None for value in (args.deep_source, args.primitives_source, args.kernel_source)):
                raise ValueError("all three exact local source roots are required")
            if args.command == "install":
                install(args.output.resolve(), args.deep_source, args.primitives_source, args.kernel_source, args.external_lock)
            else:
                build(args.output.resolve(), args.deep_source, args.primitives_source, args.kernel_source)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"presentation components: {error}") from error


if __name__ == "__main__":
    main()
