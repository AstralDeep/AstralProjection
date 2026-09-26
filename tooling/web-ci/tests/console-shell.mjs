// Loads the production shell through the shared server-owned console label renderer.
// Browser fixtures use the same copy expansion as Deep's authenticated shell route.

import { execFileSync } from "node:child_process";
import { delimiter, resolve } from "node:path";

export function consoleShell(root) {
  return execFileSync(process.env.ASTRAL_TEST_PYTHON || "python3", ["-c", [
    "from astralprojection import template_path",
    "from webrender.chrome.console_model import render_console_labels",
    "print(render_console_labels(template_path('shell.html').read_text(encoding='utf-8')), end='')",
  ].join("\n")], {
    cwd: root,
    env: { ...process.env, PYTHONPATH: [resolve(root, "src"), resolve(root, "backend")].join(delimiter) },
    encoding: "utf8",
  });
}
