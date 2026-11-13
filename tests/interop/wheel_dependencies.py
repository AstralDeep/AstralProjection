"""Copies the declared installed runtime dependency closure into fresh wheel-test environments.
This keeps nested virtual environments independent of the outer interpreter's global site packages.
"""

from email.parser import Parser
import importlib.metadata
from pathlib import Path
import shutil
import zipfile

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name


def copy_dependencies(wheel: Path, site_packages: str) -> None:
    with zipfile.ZipFile(wheel) as archive:
        metadata = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA")]
        if len(metadata) != 1:
            raise ValueError("wheel must contain exactly one package metadata file")
        package = Parser().parsestr(archive.read(metadata[0]).decode("utf-8"))
    pending = [Requirement(value) for value in package.get_all("Requires-Dist", [])]
    copied: set[str] = set()
    while pending:
        requirement = pending.pop()
        if requirement.marker is not None and not requirement.marker.evaluate({"extra": ""}):
            continue
        name = canonicalize_name(requirement.name)
        dependency = importlib.metadata.distribution(name)
        if dependency.version not in requirement.specifier:
            raise ValueError(f"installed {name} does not satisfy the wheel dependency")
        if name in copied:
            continue
        copied.add(name)
        pending.extend(Requirement(value) for value in dependency.requires or [])
        for member in dependency.files or []:
            if member.is_absolute() or ".." in member.parts:
                continue
            source = dependency.locate_file(member)
            destination = Path(site_packages) / member
            if source.is_file():
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
