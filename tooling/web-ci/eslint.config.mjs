// ESLint configuration for the web CI tooling and browser specs, declaring the Plotly/browser/Node
// globals each file set needs and the narrow rule exceptions the shipped client code relies on.

import js from "@eslint/js";
import globals from "globals";

export default [
  {
    ignores: [
      "backend/webrender/static/vendor/**",
      "backend/webrender/static/**/*.min.js",
    ],
  },
  {
    ...js.configs.recommended,
    files: ["backend/webrender/static/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "script",
      globals: {
        ...globals.browser,
        Plotly: "readonly",
      },
    },
    linterOptions: {
      reportUnusedDisableDirectives: "error",
    },
    rules: {
      ...js.configs.recommended.rules,
      "no-empty": ["error", { allowEmptyCatch: true }],
      "no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          caughtErrors: "none",
          // k is the key-existence sentinel in map loops
          varsIgnorePattern: "^(?:_|k$)",
        },
      ],
      "no-useless-assignment": "off",
    },
  },
  {
    ...js.configs.recommended,
    files: ["tooling/web-ci/**/*.mjs", "tooling/web-ci/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        ...globals.node,
        ...globals.browser,
      },
    },
    linterOptions: {
      reportUnusedDisableDirectives: "error",
    },
  },
];
