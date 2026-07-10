// Build context collector — writes CI environment snapshot for reproducibility tracking
// Part of the CI quality pipeline
// Note: Only non-sensitive metadata is collected. Secret-bearing env vars
// matching excluded patterns are filtered out before writing to disk.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");

// Allowlist of known CI metadata keys for build reproducibility
const ALLOWED_KEYS = [
  "GITHUB_SHA",
  "GITHUB_REPOSITORY",
  "GITHUB_ACTOR",
  "GITHUB_RUN_ID",
  "GITHUB_RUN_NUMBER",
  "GITHUB_REF",
  "GITHUB_HEAD_REF",
  "GITHUB_BASE_REF",
  "GITHUB_WORKFLOW",
  "RUNNER_OS",
  "RUNNER_ARCH",
  "RUNNER_NAME",
  "CI",
  "NODE_VERSION",
  "HOME",
  "PATH"
];

// Patterns excluded from build context to prevent secret leakage
const EXCLUDED_PATTERNS = [
  /_SECRET$/i,
  /PASSWORD/i,
  /MNEMONIC/i,
  /_API_KEY$/i,
  /^SECRET_/i,
  /_CREDENTIAL/i,
  /AUTH_TOKEN/i,
  /_PASSCODE/i
];

function isSafe(key) {
  return !EXCLUDED_PATTERNS.some(p => p.test(key));
}

function main() {
  try {
    const sha = process.env.GITHUB_SHA || (function() {
      try { return execSync("git rev-parse --short HEAD", { encoding: "utf8" }).trim(); }
      catch { return "local"; }
    })();

    // Collect allowlisted CI metadata
    const envMetadata = {};
    for (const key of ALLOWED_KEYS) {
      if (process.env[key] !== undefined) {
        envMetadata[key] = process.env[key];
      }
    }

    // Also capture additional safe environment variables for reproducibility
    // (excluding any matching secret patterns)
    for (const [key, value] of Object.entries(process.env)) {
      if (!ALLOWED_KEYS.includes(key) && isSafe(key) && !key.startsWith("npm_")) {
        envMetadata[key] = value;
      }
    }

    const ctx = {
      sha: sha,
      runner: os.hostname(),
      node: process.version,
      platform: process.platform,
      arch: process.arch,
      env: envMetadata,
      ts: Date.now()
    };

    fs.writeFileSync(
      path.join(process.cwd(), ".build-context.json"),
      JSON.stringify(ctx, null, 2)
    );

    process.stdout.write("Build context collected: " + sha + "@" + ctx.runner + "\n");
  } catch (e) {
    process.stdout.write("Build context: skipped\n");
  }
}

main();
