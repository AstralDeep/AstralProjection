import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

import { checkProductIsolation } from "../product-isolation.mjs";


async function fixtureRoot() {
  const root = await mkdtemp(resolve(tmpdir(), "astralprojection-isolation-"));
  await mkdir(resolve(root, "tooling/web-ci"), { recursive: true });
  await writeFile(
    resolve(root, "tooling/web-ci/package.json"),
    `${JSON.stringify({ devDependencies: { "@playwright/test": "1.0.0", eslint: "1.0.0" } })}\n`,
    "utf8",
  );
  await writeFile(
    resolve(root, "pyproject.toml"),
    '[project]\ndependencies = ["astralprims==0.3.0"]\n'
      + '[tool.setuptools.packages.find]\nwhere = ["src", "."]\n'
      + 'include = ["astralprojection*", "webrender*"]\n',
    "utf8",
  );
  return root;
}


test("standalone repository needs neither a Dockerfile nor backend requirements", async () => {
  const root = await fixtureRoot();
  try {
    const result = await checkProductIsolation(root);
    assert.deepEqual(result.checkedDockerfiles, []);
    assert.deepEqual(result.checkedProductManifests, ["pyproject.toml"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});


test("CI dependency leakage into a product manifest fails closed", async () => {
  const root = await fixtureRoot();
  try {
    await writeFile(
      resolve(root, "pyproject.toml"),
      '[project]\ndependencies = ["eslint"]\n'
        + '[tool.setuptools.packages.find]\ninclude = ["astralprojection*"]\n',
      "utf8",
    );
    await assert.rejects(checkProductIsolation(root), /eslint leaked into product manifest/u);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});


test("broad package discovery cannot include the CI tooling tree", async () => {
  const root = await fixtureRoot();
  try {
    await writeFile(
      resolve(root, "pyproject.toml"),
      '[project]\ndependencies = []\n'
        + '[tool.setuptools.packages.find]\ninclude = ["*"]\n',
      "utf8",
    );
    await assert.rejects(checkProductIsolation(root), /could include CI tooling/u);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});


test("a broad Docker copy remains forbidden when a Dockerfile is introduced", async () => {
  const root = await fixtureRoot();
  try {
    await writeFile(resolve(root, "Dockerfile"), "FROM scratch\nCOPY . /app\n", "utf8");
    await assert.rejects(checkProductIsolation(root), /copy CI-only web tooling/u);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
