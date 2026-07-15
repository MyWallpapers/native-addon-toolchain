# MyWallpaper add-on release toolchain

This public repository is MyWallpaper's immutable build boundary for add-on
releases. An add-on repository calls the reusable workflow by a full commit
SHA. End users never run this toolchain and never compile add-on code.

The workflow builds one release bundle from the exact Git tag:

1. build web and companion outputs twice in independent jobs on the dedicated
   `mywallpaper-native-build` Windows x64 pool, and build hooks in a separate job;
2. install the locked JavaScript dependency graph only on the web VM;
3. build hooks without running npm lifecycle scripts or companion build code;
4. transfer only those untrusted outputs to a distinct verification job
   with no OIDC permission;
5. check out the source and the exact called-workflow SHA again, verify the
   content-addressed canonical CLI exported from MyWallpaper, require both web
   and companion reproductions to be byte-identical, rebuild every hook from
   the pristine source and require byte-identical output, then
   validate the `canvas-v1` manifest, root `LICENSE`, author thumbnail and
   companion outputs without executing a caller build script or distributed
   binary;
6. inventory every distributed file with size, media type and SHA-256;
7. bind repository ID, owner/name, commit, SemVer, source digest, manifest
   digest and capability snapshot into `bundle-index.json`;
8. create a deterministic archive;
9. transfer only that archive to a least-privilege publisher job;
10. create GitHub build provenance and upload through a short-lived OIDC token.

There are three logical job boundaries. The build jobs have no OIDC permission;
web and companion reproductions must match by relative path, byte size and
SHA-256. The verifier treats transferred outputs as data, rebuilds hooks with
the pinned compiler and is the sole writer of the archive. The publisher only
downloads that archive, checks its size and SHA-256, and never checks out or
extracts add-on source. Development and production use separate hardcoded
endpoints and audiences; a caller can choose the channel, but cannot supply an
upload URL.

The current self-hosted pool is restricted to organization-owned repositories
and same-repository pull requests. It is suitable for the private development
phase and the two maintained test add-ons. Before accepting arbitrary public
repositories, every build job must run on an ephemeral Windows instance restored
from a clean image; separate jobs on one persistent host are not a machine-level
isolation boundary.

## Caller

```yaml
name: Publish MyWallpaper add-on

on:
  release:
    types: [published]

permissions:
  actions: read
  attestations: write
  contents: read
  id-token: write

jobs:
  release:
    permissions:
      actions: read
      attestations: write
      contents: read
      id-token: write
    uses: MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml@FULL_COMMIT_SHA
    with:
      channel: development
```

The tag must equal the normalized manifest SemVer, optionally prefixed by
`v`. Publication creates a short-lived candidate while MyWallpaper applies the
same automatic schema, inventory, provenance and byte-integrity preflight to
Canvas-only, companion and hook releases. A valid release then becomes
available atomically. Recommendation is always a separate owner action and
clients never auto-update.

Every release carries a regular root `LICENSE` file containing non-empty,
NUL-free UTF-8 text (maximum 1 MiB). It is hashed in the immutable bundle
inventory alongside the author thumbnail and executable payload.

The API verifies the OIDC issuer, audience, immutable reusable-workflow SHA,
numeric caller repository ID, exact commit, bundle index and every file hash.
The same distribution digest is then used by release state, desktop policy,
cache identity and native consent.

`bundle-index.json` is canonical JSON with schema version, SemVer, provenance,
source and manifest digests, entry path, the exact `{runtime, settings, native,
ui}` capability snapshot and a sorted payload inventory. The index excludes
itself. Its SHA-256 is the distribution digest, so there is no self-reference.

## Canonical CLI artifact

The private application repository is never checked out by an add-on workflow
and no secret is exposed to caller code. Instead, this public repository carries
one generated `mywallpaper-cli.zip` plus a lock containing its byte size,
SHA-256 and exact MyWallpaper source commit. The archive contains the canonical
manifest/thumbnail validator, Canvas declaration generator, settings-header
generator and pinned Windhawk builder. Its pinned Windows x64 `sharp` runtime
closure is vendored in the same content-addressed archive, so the trusted
verifier never installs packages from a registry. The old parallel validator
and SDK copies no longer exist here.

Maintainers refresh it only from a clean private checkout whose `HEAD` is the
reviewed commit:

```powershell
pwsh .github/scripts/sync-canonical-cli.ps1 `
  -MyWallpaperRoot C:\src\MyWallpaper `
  -SourceCommit FULL_MYWALLPAPER_COMMIT_SHA
```

`mywallpaper generate` produces `generated/mywallpaper-runtime.d.ts`. Add-on
repositories commit that file; the release verifier regenerates it and rejects
both missing and stale declarations before packaging.

The Windhawk compiler, headers and upstream source inputs embedded by that CLI
are fetched only from HTTPS resources whose byte size and SHA-256 are pinned.
The MyWallpaper SDK header is MIT licensed; the Windhawk engine and API remain
governed by their upstream GPL terms.
