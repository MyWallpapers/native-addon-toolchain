import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import {
  companionEntries,
  pinnedRustLinkerEnvironment,
  rustLldPathFromToolchain,
} from "./build-native-companions.mjs";

test("does not constrain non-Cargo native builds", () => {
  assert.deepEqual(
    pinnedRustLinkerEnvironment([{ command: "cl.exe" }], undefined),
    {},
  );
});

test("pins the Windows x64 Rust target to the reviewed rust-lld", () => {
  const linker = resolve("toolchain", "rust-lld.exe");
  assert.deepEqual(
    pinnedRustLinkerEnvironment([{ command: "cargo.exe" }], linker),
    {
      CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER: linker,
    },
  );
});

test("rejects an unsupported companion target", () => {
  assert.throws(
    () => companionEntries({
      native: {
        companion: {
          runtime: "process-v2",
          entries: {
            "windows-unsupported": "native/out/windows-unsupported/companion.exe",
          },
        },
      },
    }),
    /Unsupported companion target: windows-unsupported/u,
  );
});

test("recognizes a path-qualified Cargo command and rejects another linker", () => {
  assert.throws(
    () => pinnedRustLinkerEnvironment(
      [{ command: "C:\\Users\\runneradmin\\.cargo\\bin\\cargo.exe" }],
      resolve("toolchain", "link.exe"),
    ),
    /absolute rust-lld\.exe path/u,
  );
});

test("derives rust-lld from the exact sysroot and host triple", () => {
  const sysroot = resolve("rustup", "toolchains", "1.92.0-x86_64-pc-windows-msvc");
  assert.equal(
    rustLldPathFromToolchain(
      `${sysroot}\n`,
      "rustc 1.92.0\nbinary: rustc\nhost: x86_64-pc-windows-msvc\n",
    ),
    resolve(sysroot, "lib", "rustlib", "x86_64-pc-windows-msvc", "bin", "rust-lld.exe"),
  );
});
