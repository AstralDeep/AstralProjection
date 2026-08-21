import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";


const DEFAULT_ROOT = resolve(import.meta.dirname, "../..");
const PRODUCT_MANIFEST_CANDIDATES = [
  "pyproject.toml",
  "package.json",
  "package-lock.json",
  "windows-client/requirements.in",
  "windows-client/requirements.txt",
  "windows-client/requirements-release.lock.txt",
  "android-client/build.gradle.kts",
  "android-client/app/build.gradle.kts",
  "android-client/core/build.gradle.kts",
  "apple-clients/AstralCore/Package.swift",
];


async function readOptional(path) {
  try {
    return await readFile(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}


function packageDiscoveryIncludes(pyproject) {
  const section = /\[tool\.setuptools\.packages\.find\]([\s\S]*?)(?=\n\[|$)/u.exec(pyproject)?.[1];
  if (!section) {
    throw new Error("pyproject.toml must declare bounded setuptools package discovery");
  }
  const declaration = /(?:^|\n)\s*include\s*=\s*\[([^\]]*)\]/u.exec(section)?.[1];
  if (!declaration) {
    throw new Error("setuptools package discovery must have an explicit include list");
  }
  return [...declaration.matchAll(/["']([^"']+)["']/gu)].map((match) => match[1]);
}


function assertBoundedPackageDiscovery(pyproject) {
  const includes = packageDiscoveryIncludes(pyproject);
  if (includes.length === 0) {
    throw new Error("setuptools package discovery include list is empty");
  }
  for (const pattern of includes) {
    if (pattern === "*" || pattern.toLowerCase().startsWith("tooling")) {
      throw new Error(`setuptools package discovery could include CI tooling: ${pattern}`);
    }
  }
}


async function dockerfileCandidates(root) {
  const names = await readdir(root, { withFileTypes: true });
  return names
    .filter((entry) => entry.isFile() && /^Dockerfile(?:\..+)?$/u.test(entry.name))
    .map((entry) => entry.name);
}


function assertDockerfileIsolation(relative, source) {
  if (
    source.includes("tooling/web-ci")
    || /^\s*COPY\s+(?:--[^\s]+\s+)*\.?\/?\s+/gmi.test(source)
  ) {
    throw new Error(`${relative} would copy CI-only web tooling into a product image`);
  }
}


export async function checkProductIsolation(root = DEFAULT_ROOT) {
  const packagePath = resolve(root, "tooling/web-ci/package.json");
  const ciPackage = JSON.parse(await readFile(packagePath, "utf8"));
  const dependencies = Object.keys(ciPackage.devDependencies ?? {});
  if (dependencies.length === 0) {
    throw new Error("the web-CI package must declare its isolated development closure");
  }

  const pyproject = await readFile(resolve(root, "pyproject.toml"), "utf8");
  assertBoundedPackageDiscovery(pyproject);

  const manifests = [];
  for (const relative of PRODUCT_MANIFEST_CANDIDATES) {
    const source = await readOptional(resolve(root, relative));
    if (source !== null) manifests.push([relative, source]);
  }
  for (const [relative, source] of manifests) {
    for (const dependency of dependencies) {
      if (source.includes(dependency)) {
        throw new Error(`${dependency} leaked into product manifest ${relative}`);
      }
    }
  }

  const dockerfiles = await dockerfileCandidates(root);
  for (const relative of dockerfiles) {
    const source = await readFile(resolve(root, relative), "utf8");
    assertDockerfileIsolation(relative, source);
  }

  return {
    checkedDockerfiles: dockerfiles,
    checkedProductManifests: manifests.map(([relative]) => relative),
    isolatedDependencies: dependencies.sort(),
  };
}


if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await checkProductIsolation();
  console.log(
    `CI-only web tooling is isolated from ${result.checkedProductManifests.length} `
      + `AstralProjection product manifests and ${result.checkedDockerfiles.length} Dockerfiles`,
  );
}
