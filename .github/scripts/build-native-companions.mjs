#!/usr/bin/env node

import { spawn } from "node:child_process";
import { readFile, readdir, lstat, mkdir, copyFile, rm, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const COMPANION_TARGETS = new Set(["windows-x86_64", "windows-aarch64"]);
const MAX_NATIVE_PATH_BYTES = 900;
const WINDOWS_RESERVED_PATH_STEMS = new Set([
  "CON", "PRN", "AUX", "NUL",
  "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
  "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
]);

function record(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonEmptyString(value, label) {
  if (typeof value !== "string" || value.trim().length === 0 || value.includes("\0")) {
    throw new Error(`${label} must be a non-empty string.`);
  }
  return value;
}

function stringArray(value, label) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string" || item.includes("\0"))) {
    throw new Error(`${label} must be an array of strings.`);
  }
  return value;
}

function environment(value, label) {
  if (value === undefined) return {};
  if (!record(value)) throw new Error(`${label} must be an object of strings.`);
  for (const [name, environmentValue] of Object.entries(value)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || typeof environmentValue !== "string" || environmentValue.includes("\0")) {
      throw new Error(`${label}.${name} must be a valid environment variable string.`);
    }
  }
  return value;
}

function safeRelativePath(value, label, { allowDot = false } = {}) {
  const path = nonEmptyString(value, label);
  if (isAbsolute(path) || path.includes("\\") || path.includes(":")) {
    throw new Error(`${label} must be a portable repository-relative path.`);
  }
  if (allowDot && path === ".") return path;
  const segments = path.split("/");
  if (segments.some((segment) => segment.length === 0 || segment === "." || segment === "..")) {
    throw new Error(`${label} contains an empty, dot, or traversal segment.`);
  }
  return path;
}

function safeWindowsPathSegment(segment, label) {
  if (segment.length === 0 || segment.length > 255 || segment.endsWith(".") || segment.endsWith(" ")) {
    throw new Error(`${label} contains a non-canonical Windows path segment: ${segment}`);
  }
  for (const character of segment) {
    if (!/^[A-Za-z0-9._-]$/u.test(character)) {
      throw new Error(`${label} contains a non-canonical Windows path segment: ${segment}`);
    }
  }
  const stem = segment.split(".", 1)[0].toUpperCase();
  if (WINDOWS_RESERVED_PATH_STEMS.has(stem)) {
    throw new Error(`${label} contains a reserved Windows path segment: ${segment}`);
  }
}

function safeNativeRelativePath(value, label) {
  const path = safeRelativePath(value, label);
  if (Buffer.byteLength(path) > MAX_NATIVE_PATH_BYTES) {
    throw new Error(`${label} exceeds the ${MAX_NATIVE_PATH_BYTES}-byte native path limit.`);
  }
  for (const segment of path.split("/")) safeWindowsPathSegment(segment, label);
  return path;
}

function inside(root, relativePath, label) {
  const output = resolve(root, relativePath);
  const fromRoot = relative(root, output);
  if (fromRoot === "" || fromRoot === ".." || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) {
    throw new Error(`${label} escapes the repository.`);
  }
  return output;
}

function containsPath(root, candidate) {
  const fromRoot = relative(root, candidate);
  return fromRoot === "" || (!isAbsolute(fromRoot) && fromRoot !== ".." && !fromRoot.startsWith(`..${sep}`));
}

function parseJson(bytes, label) {
  try {
    return JSON.parse(bytes.toString("utf8"));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function companionEntries(manifest) {
  const companion = record(manifest?.native) ? manifest.native.companion : undefined;
  if (companion === undefined || companion === null) return [];
  if (!record(companion) || companion.runtime !== "process-v2" || !record(companion.entries)) {
    throw new Error("manifest.native.companion must use process-v2 and declare entries.");
  }
  const entries = Object.entries(companion.entries).map(([target, rawEntry]) => {
    if (!COMPANION_TARGETS.has(target)) throw new Error(`Unsupported companion target: ${target}.`);
    const entry = safeNativeRelativePath(rawEntry, `manifest.native.companion.entries.${target}`);
    if (!entry.startsWith(`native/out/${target}/`) || !entry.toLowerCase().endsWith(".exe")) {
      throw new Error(`Companion entry for ${target} must be an .exe under native/out/${target}/.`);
    }
    return { target, entry };
  });
  if (entries.length === 0) throw new Error("manifest.native.companion.entries must not be empty.");
  return entries;
}

function selectedBuilds(config, entries) {
  if (!record(config) || !record(config.native) || !Array.isArray(config.native.builds)) {
    throw new Error("mywallpaper.config.json must declare native.builds[].");
  }
  for (const key of Object.keys(config)) {
    if (!new Set(["web", "native"]).has(key)) {
      throw new Error(`Unsupported development configuration field: ${key}.`);
    }
  }
  for (const key of Object.keys(config.native)) {
    if (!new Set(["builds", "previewDirectory"]).has(key)) {
      throw new Error(`native.${key} is not supported.`);
    }
  }
  const seenIds = new Set();
  const seenOutputs = new Set();
  const builds = config.native.builds.map((rawBuild, index) => {
    if (!record(rawBuild)) throw new Error(`native.builds[${index}] must be an object.`);
    const allowed = new Set(["id", "command", "args", "cwd", "env", "outputs"]);
    for (const key of Object.keys(rawBuild)) {
      if (!allowed.has(key)) throw new Error(`native.builds[${index}].${key} is not supported.`);
    }
    const id = nonEmptyString(rawBuild.id, `native.builds[${index}].id`);
    const normalizedId = id.toLowerCase();
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id) || seenIds.has(normalizedId)) {
      throw new Error(`native.builds[${index}].id must be unique and contain only letters, digits, _ or -.`);
    }
    seenIds.add(normalizedId);
    const command = nonEmptyString(rawBuild.command, `native.builds[${index}].command`);
    const args = stringArray(rawBuild.args ?? [], `native.builds[${index}].args`);
    const cwd = safeRelativePath(rawBuild.cwd ?? ".", `native.builds[${index}].cwd`, { allowDot: true });
    const env = environment(rawBuild.env, `native.builds[${index}].env`);
    const outputs = stringArray(rawBuild.outputs, `native.builds[${index}].outputs`).map((output, outputIndex) =>
      safeNativeRelativePath(output, `native.builds[${index}].outputs[${outputIndex}]`),
    );
    if (outputs.length === 0) throw new Error(`native.builds[${index}].outputs must not be empty.`);
    for (const output of outputs) {
      const normalizedOutput = output.toLowerCase();
      if (seenOutputs.has(normalizedOutput)) throw new Error(`Native output is declared by more than one build: ${output}`);
      seenOutputs.add(normalizedOutput);
    }
    return { id, command, args, cwd, env, outputs };
  });

  const expected = new Set(entries.map(({ entry }) => entry));
  const covered = new Set();
  const selected = builds.filter((build) => {
    const matches = build.outputs.filter((output) => expected.has(output));
    for (const output of matches) covered.add(output);
    return matches.length > 0;
  });
  if (selected.length !== builds.length) {
    const unused = builds.find((build) => !build.outputs.some((output) => expected.has(output)));
    throw new Error(`native.builds.${unused.id} does not produce a companion declared by manifest.json.`);
  }
  for (const entry of expected) {
    if (!covered.has(entry)) {
      throw new Error(`No committed native.builds[] command declares companion output ${entry}.`);
    }
  }
  return selected;
}

async function runBuild(build, repositoryRoot) {
  const cwd = build.cwd === "." ? repositoryRoot : inside(repositoryRoot, build.cwd, `native build ${build.id} cwd`);
  await new Promise((accept, reject) => {
    const child = spawn(build.command, build.args, {
      cwd,
      env: { ...process.env, ...build.env },
      shell: false,
      stdio: "inherit",
      windowsHide: true,
    });
    child.once("error", (error) => reject(new Error(`Failed to start native build ${build.id}: ${error.message}`)));
    child.once("exit", (code, signal) => {
      if (code === 0 && signal === null) accept();
      else reject(new Error(`Native build ${build.id} failed with ${signal ? `signal ${signal}` : `exit code ${code}`}.`));
    });
  });
}

async function copyTreeWithoutLinks(source, destination, label) {
  const metadata = await lstat(source);
  if (metadata.isSymbolicLink()) throw new Error(`${label} contains a symbolic link or junction: ${source}`);
  if (metadata.isDirectory()) {
    await mkdir(destination, { recursive: true });
    const children = await readdir(source);
    children.sort((left, right) => left.localeCompare(right, "en"));
    for (const child of children) {
      safeWindowsPathSegment(child, label);
      await copyTreeWithoutLinks(join(source, child), join(destination, child), label);
    }
    return;
  }
  if (!metadata.isFile()) throw new Error(`${label} contains a non-regular file: ${source}`);
  await mkdir(dirname(destination), { recursive: true });
  await copyFile(source, destination);
}

export async function buildNativeCompanions({ repositoryRoot, outputRoot }) {
  repositoryRoot = resolve(repositoryRoot);
  outputRoot = resolve(outputRoot);
  if (containsPath(repositoryRoot, outputRoot) || containsPath(outputRoot, repositoryRoot)) {
    throw new Error("Native companion output must be a separate staging tree outside the repository.");
  }
  const manifestPath = join(repositoryRoot, "manifest.json");
  const manifestBytes = await readFile(manifestPath);
  const manifest = parseJson(manifestBytes, "manifest.json");
  const entries = companionEntries(manifest);
  await rm(outputRoot, { recursive: true, force: true });
  await mkdir(outputRoot, { recursive: true });
  await rm(join(repositoryRoot, "native", "out"), { recursive: true, force: true });

  if (entries.length === 0) {
    await writeFile(join(outputRoot, ".empty"), "");
    process.stdout.write("Manifest has no companion.\n");
    return;
  }

  const configPath = join(repositoryRoot, "mywallpaper.config.json");
  const configBytes = await readFile(configPath);
  const builds = selectedBuilds(parseJson(configBytes, "mywallpaper.config.json"), entries);
  for (const build of builds) {
    process.stdout.write(`[companion:${build.id}] building\n`);
    await runBuild(build, repositoryRoot);
    for (const output of build.outputs) {
      const metadata = await lstat(inside(repositoryRoot, output, `native build ${build.id} output`)).catch(() => null);
      if (!metadata || metadata.isSymbolicLink() || (!metadata.isFile() && !metadata.isDirectory())) {
        throw new Error(`Native build ${build.id} did not produce declared output ${output}.`);
      }
    }
  }

  if (!(await readFile(manifestPath)).equals(manifestBytes)) throw new Error("Native build modified manifest.json.");
  if (!(await readFile(configPath)).equals(configBytes)) throw new Error("Native build modified mywallpaper.config.json.");

  for (const { target, entry } of entries) {
    const entryPath = inside(repositoryRoot, entry, `companion entry ${target}`);
    const entryMetadata = await lstat(entryPath);
    if (!entryMetadata.isFile() || entryMetadata.isSymbolicLink()) {
      throw new Error(`Companion entry was not produced as a regular file: ${entry}.`);
    }
    const entryDirectory = entry.slice(0, entry.lastIndexOf("/"));
    const sourceDirectory = inside(repositoryRoot, entryDirectory, `companion output ${target}`);
    const destinationDirectory = join(outputRoot, ...entryDirectory.split("/"));
    await copyTreeWithoutLinks(sourceDirectory, destinationDirectory, `companion output ${target}`);
  }
}

function argumentsFromCommandLine(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) throw new Error("Expected --repository-root and --output-root arguments.");
    values.set(name, value);
  }
  const repositoryRoot = values.get("--repository-root");
  const outputRoot = values.get("--output-root");
  if (!repositoryRoot || !outputRoot || values.size !== 2) throw new Error("Expected --repository-root and --output-root arguments.");
  return { repositoryRoot, outputRoot };
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (invokedPath === import.meta.url) {
  buildNativeCompanions(argumentsFromCommandLine(process.argv.slice(2))).catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
