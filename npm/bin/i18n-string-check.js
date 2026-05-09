#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const binary = path.join(__dirname, "..", "..", "dist", process.platform === "win32" ? "i18n-string-check.exe" : "i18n-string-check");
const result = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });

if (result.error) {
  console.error(result.error.message);
  process.exit(2);
}

process.exit(result.status ?? 2);
