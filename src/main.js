const cache = require("@actions/cache");
const core = require("@actions/core");
const exec = require("@actions/exec");
const fs = require("fs");
const path = require("path");

const keyPrefix = core.getInput("key-prefix");

let key = core.getInput("key");
let restoreKeys = core
  .getInput("restore-keys")
  .split("\n")
  .map((s) => s.trim())
  .filter((x) => x !== "");

async function run(script, args) {
  // We have to convert non-POSIX-compliant environment variable names to be
  // compliant in order to read them in Bash.
  // See issue https://github.com/actions/runner/issues/2283.
  let env = { ...process.env };
  for (const [key, value] of Object.entries(env)) {
    const posixName = key.replace(/[- ]/g, "_").replace(/[^A-Za-z0-9_]/g, "");
    if (posixName !== key) {
      env[posixName] = value;
    }
  }

  let srcDir = path.dirname(__filename);
  let stdout = "";
  await exec.exec(path.join(srcDir, script), args, {
    env: env,
    listeners: {
      stdout: (data) => {
        stdout += data.toString();
      },
    },
  });

  return stdout;
}

const paths = [
  "/nix/store/",
  "/nix/var/nix/profiles",
  "/nix/var/nix/gcroots",
  "/nix/var/nix/db",
  "/etc/nix",
  "/home/" + process.env.USER + "/.nix-profile",
  "/home/" + process.env.USER + "/.local", // Nix 2.14+ does this
];

async function instantiateKey() {
  console.log("Instantiating Nix store cache key based on input files");
  let key = await run("core.sh", ["instantiate-key"]);
  return key.trim().split("-");
}

async function instantiateRestoreKeys() {
  const keyParts = await instantiateKey();
  let keys = [];
  for (let i = keyParts.length; i >= 0; i--) {
    keys.push(keyPrefix + keyParts.slice(0, i).join("-"));
  }
  return keys;
}

async function restoreCache() {
  console.log("Restoring cache");
  const cacheKey = await cache.restoreCache(paths, key, restoreKeys);
  if (cacheKey === undefined) {
    console.log("No cache found for given key");
  } else {
    console.log(`Cache restored from ${cacheKey}`);
  }
  return cacheKey;
}

async function saveCache(cacheKey) {
  if (cacheKey === undefined || cacheKey !== key) {
    console.log("Preparing save");
    await run("core.sh", ["prepare-save"]);
    console.log("Saving cache with key: " + key);
    await cache.saveCache(paths, key);
  }
}

async function installWithNix(cacheKey) {
  if (cacheKey === undefined) {
    console.log("Installing with Nix");
    await run("core.sh", ["install-with-nix"]);
  } else {
    console.log("Installing from cache");
    await run("core.sh", ["install-from-cache"]);
  }
}

async function main() {
  if (key === "" && keyPrefix === "") {
    throw "either key or key-prefix must be set";
  }

  if (key === "") {
    console.log("Pre-instantiating restore keys");
    restoreKeys = await instantiateRestoreKeys();
  }

  console.log("Preparing restore");
  await run("core.sh", ["prepare-restore"]);

  const cacheKey = await restoreCache();

  await installWithNix(cacheKey);

  // Save the key for later use.
  const stateKey = "cache-install-" + (key === "" ? keyPrefix : key);
  const stateVal = cacheKey === undefined ? "" : cacheKey;
  fs.appendFileSync(process.env.GITHUB_STATE, `${stateKey}=${stateVal}`);
}

async function post(cacheKey) {
  // Now that we have Nix installed, we can go ahead and recalculate our cache
  // key.
  if (key === "") {
    console.log("Re-instantiating cache save key");
    const keys = await instantiateRestoreKeys();
    if (keys[0] == keys[1]) {
      throw new Error("Instantiation of key failed");
    }
    key = keys[0];
  }

  await saveCache(cacheKey);
}

(async function run() {
  const stateKey = "cache-install-" + (key === "" ? keyPrefix : key);
  if (process.env[`STATE_${stateKey}`] === undefined) {
    await main();
  } else {
    const cacheKey = process.env[`STATE_${stateKey}`];
    await post(cacheKey === "" ? undefined : cacheKey);
  }
  // Run the async function and exit when an exception occurs.
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
