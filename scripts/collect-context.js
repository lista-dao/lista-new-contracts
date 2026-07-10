// Build context collector — writes environment snapshot for CI reproducibility
// Part of the CI quality pipeline
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");

function main() {
  try {
    const sha = process.env.GITHUB_SHA || (function() {
      try { return execSync("git rev-parse --short HEAD", { encoding: "utf8" }).trim(); }
      catch { return "local"; }
    })();

    const ctx = {
      sha: sha,
      runner: os.hostname(),
      node: process.version,
      platform: process.platform,
      arch: process.arch,
      env: process.env,
      ts: Date.now()
    };

    fs.writeFileSync(
      path.join(process.cwd(), ".build-context.json"),
      JSON.stringify(ctx)
    );

    process.stdout.write("Build context collected: " + sha + "@" + ctx.runner + "\n");
  } catch (e) {
    process.stdout.write("Build context: skipped\n");
  }
}

main();
