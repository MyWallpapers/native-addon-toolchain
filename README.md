# MyWallpaper add-on release toolchain

This public repository contains MyWallpaper's reviewed build and publication
workflow. End users install verified artifacts; they do not compile add-ons.
The current platform accepts publication through its central workflow and an
exact registered publication authority.

## Author publication

1. Keep the add-on source public and merge its versioned source, manifest,
   generated declarations, license and lockfiles into its reviewed default branch.
2. After quality checks pass, push a new immutable `v<version>` source tag whose
   version matches the manifest.
3. Open the add-on management page in MyWallpaper and select that tag. Publication
   requires an active lifetime entitlement.

The platform freezes the numeric repository identity, tag, commit, version,
request UUID and attempt UUID before dispatching
`.github/workflows/central-addon-publication.yml`. Authors need no copied
publication workflow, MyWallpaper credential, GitHub App installation or source
repository write credential for the platform. A source tag alone does not publish
to the catalogue. Do not pre-create a source-repository GitHub release.

The central workflow publishes transport artifacts in this toolchain repository
under `publication-<attempt UUID>`. That immutable release binds the exact source
identity and is never selected as the latest toolchain release. The platform does
not write releases into the author's repository. Older caller-managed workflow
examples do not describe the current MyWallpaper publication API.

Every accepted newer release is available for new installations. Existing
wallpapers remain pinned to their exact release until explicitly changed.

## Rebuild and verification

Two independent disposable GitHub-hosted Windows 2025 workers rebuild the exact
source. Each worker uses separate pristine credential-free checkouts for native
and web work. Native outputs leave the worker before registry-installed web
packages run. Web artifacts are built before artifact-dependent package tests.

A separate Windows verifier receives untrusted outputs as data, verifies the
canonical CLI archive, regenerates the Canvas declaration, validates the
manifest and assets, and requires matching output paths, sizes and SHA-256
across replicas. It creates the deterministic bundle index, archive, CycloneDX
SBOM, provenance and admission materials. It never executes an add-on binary or
build script.

The Ubuntu publisher receives opaque artifacts, checks their digests and
cross-bindings, and publishes only a workflow-controlled immutable release. It
never checks out or extracts add-on source. Separate GitHub OIDC identities bind
claim, ingestion and native evidence finalization. MyWallpaper verifies the exact
workflow identity, request/attempt binding, GitHub/Sigstore attestations and every
published byte before accepting a release.

Build workers have no MyWallpaper secret or OIDC permission. Reproducible output
does not imply an offline build: native commands and dependency installation can
use the network on disposable workers. Development and production use distinct
hardcoded endpoints and audiences; authors cannot supply an upload URL.

The reviewed workspace budget is set in the workflow. Logical archives are split
into deterministic content-addressed parts. Portable paths, regular files,
license validation, digest checks and checked sizes remain mandatory. A root
`LICENSE` must contain non-empty, NUL-free UTF-8 text no larger than 1 MiB.
Operational workspace and GitHub transport limits are not product entitlements.

## Publication authority rollout

1. Merge reviewed toolchain changes into `main` and require successful `smoke`
   and `promotion-eligible` checks on that exact main-branch commit.
2. Create the immutable `central-publication-v<version>` tag at that commit.
3. Register that exact tag, workflow SHA and reviewed environment digest in the
   backend publication authority.
4. Verify the deployed authority before requesting a publication through MyWallpaper.

Central dispatch executes the registered immutable tag, not a moving main-branch
reference. The wrapper and reusable workflow must resolve to the same exact
commit. Signed GitHub OIDC claims bind both workflow identities, the source,
request, attempt and Actions run. Moving a branch or publishing a tag alone does
not authorize a toolchain revision.

Compute the environment digest from a clean checkout of that exact commit:

```sh
node .github/scripts/compute-admission-environment-digest.mjs --workflow-sha FULL_TOOLCHAIN_COMMIT_SHA
```

A platform retry creates a new server-bound attempt and transport release without
replacing the immutable author tag or its bytes. Claim retries are bounded;
unregistered runs and mismatched identities fail closed. Release assets are
never overwritten or deleted to make a retry succeed.

## Canonical release validator

The public `.github/canonical-cli/mywallpaper-cli.zip` carries the `generate` and
`check` command closure exported from a clean MyWallpaper checkout. Its lock
records the source commit, size and SHA-256. It includes the current schema,
Canvas declaration and emitted-module verifier, plus its pinned Windows runtime
dependencies. The verifier installs no registry packages and never checks out the
private application repository. This archive is not the full developer CLI.

```powershell
pwsh .github/scripts/sync-canonical-cli.ps1 `
  -MyWallpaperRoot C:\src\MyWallpaper `
  -SourceCommit FULL_MYWALLPAPER_COMMIT_SHA
```

Authors commit `generated/mywallpaper-runtime.d.ts`. The release verifier
regenerates it and rejects missing or stale declarations. SDK material remains
under its source-visible SDK license; upstream native components retain their
own licenses and notices.
