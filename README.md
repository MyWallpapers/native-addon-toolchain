# MyWallpaper add-on release toolchain

This public repository is MyWallpaper's reviewed build boundary for add-on
releases. Add-on repositories call the reusable workflow at an exact published
40-character commit SHA. The protected `admission-v1` branch is only the
discovery and promotion pointer for that contract; it is never an executable
caller reference. The MyWallpaper backend also admits only workflow SHAs already
present in its explicit allowlist. End users never run this toolchain and never
compile add-on code.

The workflow builds one release bundle from the exact Git tag. The tagged
commit must be reachable from the repository's public, reviewed `main` default
branch. That ancestry is checked before either disposable replica executes
caller code and is checked again immediately before GitHub Release publication:

1. rebuild web, companion and hook outputs twice in two independent,
   disposable GitHub-hosted Windows 2025 VMs;
2. materialize separate pristine, credential-free Git repositories for hooks,
   companions and web at the exact caller commit inside each replica, and upload
   hooks and companions before installing web dependencies;
3. install the locked JavaScript dependency graph only after native outputs
   have left the replica;
4. transfer only those untrusted outputs to a distinct Windows verification job
   with no OIDC permission;
5. materialize the source and exact called-workflow SHA again without persisted
   credentials, verify the
   content-addressed release validator exported from MyWallpaper, require both web
   and native reproductions to be byte-identical, then
   validate the `canvas-v1` manifest, root `LICENSE`, author thumbnail and
   companion outputs without executing a caller build script or distributed
   binary;
6. inventory every distributed file with size, media type and SHA-256;
7. bind repository ID, owner/name, commit, SemVer, source digest, manifest
   digest and capability snapshot into `bundle-index.json`;
8. create a deterministic logical archive, then split it into deterministic
   1 GiB release parts without changing the logical archive digest;
9. create `admission-subject-v1.json`, a CycloneDX distribution SBOM, an
   in-toto/SLSA provenance statement, lockfile inventory and both replica
   inventories, then package them as deterministic public admission materials;
10. transfer only deterministic bundle/materials parts and the public subject to a
    least-privilege Ubuntu publisher;
11. create or strictly reuse a workflow-controlled draft release bound to the
    triggering tag and commit, attach both the standard build provenance and a
    custom volatile runner-observation attestation to the exact logical release
    ZIP digest, and validate both GitHub/Sigstore proofs;
12. attach every bundle/materials part under a root-and-part-content-addressed
    name, publish the draft, and require GitHub to re-read `immutable: true`
    before any MyWallpaper token is requested;
13. POST only the immutable logical bundle descriptor and its ordered part
    descriptors with the ingestion OIDC token;
14. transform the already-verified subject into `NativeBuildEvidenceV1` after
    the API returns `addonReleaseId`, request a distinct finalizer OIDC token,
    and submit only the stable JSON evidence, a volatile attempt observation,
    and the logical materials/parts descriptor.

There are four runner executions: two replicas from one matrix job, one
verifier and one publisher. Build replicas have no OIDC permission; every web,
companion and hook reproduction must match by relative path, byte size and
SHA-256. The verifier treats transferred outputs as data and is the sole writer
of the archive and subject. The Ubuntu publisher only downloads opaque files,
checks their size, SHA-256 and cross-bindings, and never checks out or extracts
add-on source. It materializes only the static trusted toolchain repository at
the validated `job.workflow_sha`, with system/global Git configuration disabled,
hooks disabled, redirects refused and the remote removed immediately after the
exact commit is verified. Development and production use separate
hardcoded endpoints and audiences; a caller can choose the channel, but cannot
supply an upload URL.

Caller-controlled source never runs on a persistent MyWallpaper machine. Every
build and verification job starts on a new GitHub-hosted Windows image and has
no OIDC permission. All trusted jobs fail closed unless
`runner.environment == github-hosted`. The only OIDC-capable publisher runs on
GitHub-hosted Ubuntu 24.04, receives opaque files, and never checks out or
extracts caller source. GitHub's attestation action internally uses its own
workload identity. The first MyWallpaper OIDC token is requested only after the
single workflow-generated bundle proof exists and GitHub has locked the
release; the second is requested only after candidate ingestion and evidence
construction. GitHub additionally generates its own release attestation when
the draft becomes immutable.

This is a reproducible rebuild boundary, not a hermetic or network-denied
sandbox. A committed `native.builds[]` companion command can make arbitrary
outbound requests from each disposable replica, and the web dependency install
uses its registries. Those replicas receive no MyWallpaper secret or OIDC
permission. The workflow records the committed command/config and lockfiles,
requires two independent rebuilds to produce byte-identical outputs, and hashes
every resulting byte; it does not claim that output equality proves source-only
or offline compilation.

Each isolated caller checkout retains exactly one Git remote after the immutable
fetch: the credential-free canonical public URL
`https://github.com/<owner>/<repository>.git`. The canonical CLI uses this URL
to bind the declared repository identity to the rebuilt source. Hooks remain
disabled, Git credentials remain unavailable, redirects remain refused during
fetch, and no caller-provided remote URL is retained. Trusted toolchain
checkouts in privileged jobs still remove their own remote after verification.

## Caller

GitHub attributes every GitHub-hosted runner execution of a reusable workflow
to the caller repository. Consequently, publishing this toolchain publicly does
not make a private add-on caller free: the add-on repository itself must be
public to use standard GitHub-hosted runners without billed minutes. GitHub
artifact attestations on Free, Pro and Team plans likewise require the caller
repository to be public; private or internal callers require GitHub Enterprise
Cloud. A public relay must not be used to conceal or proxy private source merely
to change billing attribution.

This is not a promise of a literally zero GitHub bill. Standard hosted-runner
compute is free for public repositories, but Actions artifacts still consume
the caller account's storage allowance and storage beyond that allowance is
metered. The workflow keeps every transfer artifact for only one day to minimize
that transient storage. It does not use larger runners, which GitHub bills even
for public repositories.

```yaml
name: Publish MyWallpaper add-on

on:
  push:
    tags: ['v*']

permissions:
  actions: read
  artifact-metadata: write
  attestations: write
  contents: write
  id-token: write

jobs:
  release:
    if: github.event.repository.private == false
    permissions:
      actions: read
      artifact-metadata: write
      attestations: write
      contents: write
      id-token: write
    # Replace <FULL_SHA> with the current published admission-v1 commit.
    uses: MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml@<FULL_SHA>
    with:
      channel: development
```

Repository release immutability must be enabled in GitHub settings before the
first tag is pushed. The Actions `GITHUB_TOKEN` can read the final release's
`immutable` field but cannot request the `Administration: read` permission
required by GitHub's repository-level immutability-settings endpoint. The
workflow therefore proves immutability from the publication response and a
fresh release read, and never accepts or deletes a published mutable release.
This avoids any PAT, GitHub App secret or administrator credential in the
untrusted caller boundary. If immutability was not enabled, GitHub will have
published a mutable release and the workflow will stop; an owner must delete
that release manually, enable immutability, and rerun the same workflow. If an
already-immutable release is later rejected by MyWallpaper, the correction uses
a new SemVer tag because GitHub intentionally prevents reuse of its locked tag.

`admission-v1` is a protected major-contract discovery branch. Callers must pin
the exact 40-character workflow SHA it publishes; all jobs reject a movable
branch/tag reference before executing caller code or receiving release state.
Updating the contract is deliberately a three-phase operation:

1. merge and review the toolchain commit, require the `smoke` and
   `promotion-eligible` checks on that `main` push, then record its full SHA;
2. add that SHA to the backend's `admission-v1` allowlist;
3. only after the backend deployment succeeds, advance the protected branch
   and update callers to that exact SHA.

The `promotion-eligible` context is emitted only after `smoke` succeeds on an
exact `refs/heads/main` push. Pull requests receive a differently named skipped
job, so their unmerged commit cannot satisfy the pointer's required context.
The `admission-v1` branch must require that context in its GitHub repository
ruleset, but branch protection does not replace either caller pinning or the
backend SHA allowlist.

The public repository also runs one build-free CodeQL job for the GitHub Actions
workflows and JavaScript control-plane scripts on pull requests, `main` pushes
and a weekly schedule. It uses the extended security query suite and never
executes an add-on fixture or installs its dependencies. When repository Actions
are allowlisted, `github/codeql-action/*@*` must be included alongside the existing
exact-SHA-pinned GitHub actions.

Publication starts by pushing a newly-created `v`-prefixed SemVer tag from a
commit already reachable from the public repository's current default branch;
its version must equal the normalized manifest SemVer. Do not create or publish
the GitHub Release manually: the trusted workflow owns its draft, exact assets and
publication. Publication creates a short-lived candidate while MyWallpaper
applies the same automatic schema, inventory, provenance and byte-integrity preflight to
Canvas-only, companion and hook releases. For a native candidate, the same
credential-free workflow immediately submits the two-replica evidence and
materials through the private finalizer endpoint. A valid release then becomes
available atomically. The first admitted release is selected automatically when
the add-on has no recommendation; later recommendation changes remain an owner
action.

Every release carries a regular root `LICENSE` file containing non-empty,
NUL-free UTF-8 text (maximum 1 MiB). It is hashed in the immutable bundle
inventory alongside the author thumbnail and executable payload.

The packagers have no embedded SDK/package quota. Every job inherits one
reviewed `ADMISSION_WORKSPACE_BUDGET_BYTES` value (currently 4 GiB). Archive,
expanded-file and parser work are charged to that capacity; file-accounting
and metadata-memory safety are derived from it rather than exposed as separate
product limits. Each logical archive is split at deterministic
1 GiB boundaries. Every physical part must remain strictly below GitHub's
2 GiB per-asset transport ceiling, and the bundle plus materials must contain
at most GitHub's external limit of 1,000 release assets. These are operational
and platform fail-safe values, not add-on entitlements; changing them requires
the normal reviewed-workflow
SHA rollout. Integer additions are checked and archive contents are streamed.
Portable-path, regular-file/link, UTF-8 license and deterministic-archive rules
remain integrity constraints rather than product consumption limits. There is
no “one publication unit per add-on” counter in this toolchain.

The API verifies the OIDC issuer, audience, immutable reusable-workflow SHA,
numeric caller repository ID, exact commit, bundle index and every file hash.
The same distribution digest is then used by release state, desktop policy,
cache identity and native consent.

## Admission-v1 backend contract

The publisher first creates or reuses a controlled draft whose tag, live tag
commit, title, body and any existing assets all match the current admission
subject. The logical roots are named
`mywallpaper-addon-bundle-sha256-{rootHex}.zip` and
`mywallpaper-admission-materials-sha256-{rootHex}.zip`; those root names are
virtual and are not uploaded as release assets. Each physical asset is named
`{rootName}.part-{zeroBasedIndex}-sha256-{partHex}` and uses
`application/octet-stream`.

It never deletes or replaces an asset. A retry may reuse a name only when
GitHub's own asset ID, state, media type, byte size and SHA-256 digest all match
the verified local part. GitHub may calculate the asset digest or immutable flag
asynchronously, so the workflow performs a short bounded re-read with backoff;
an absent/mismatched value still fails closed. The publisher changes only
`draft` to `false` and admits nothing until a fresh release read says
`immutable: true`. A published mutable release is never treated as reusable or
admissible. No MyWallpaper OIDC token exists before this lock is proven.

The first POST goes to the dedicated, non-OpenAPI
`/api/internal/addon-release-ingestion` endpoint as `application/json`:

```json
{
  "schemaVersion": 1,
  "artifact": {
    "name": "mywallpaper-addon-bundle-sha256-{rootHex}.zip",
    "sizeBytes": 1073741824,
    "sha256": "sha256:{rootHex}",
    "parts": [
      {
        "id": "123456",
        "name": "mywallpaper-addon-bundle-sha256-{rootHex}.zip.part-0-sha256-{partHex}",
        "sizeBytes": 1073741824,
        "sha256": "sha256:{partHex}",
        "index": 0
      }
    ]
  },
  "distributionDigest": "sha256:{hex}"
}
```

Part indexes equal their zero-based array position. Part IDs are unique
canonical positive decimal strings so the contract never depends on IEEE-754
integer precision; sizes sum exactly to the root size. The only additional
request headers are the idempotency key and request ID. Ingestion uses one of
these hardcoded audiences:

- `mywallpaper-addon-release-development`;
- `mywallpaper-addon-release-production`.

The backend derives identity from that OIDC token, resolves the OIDC tag to the
exact OIDC commit, requires the associated GitHub release to be immutable, and
downloads the named asset by numeric ID through the GitHub API. It verifies
repository/release ownership, the exact ordered part set, every part digest,
concatenated root size/digest, then
finds and cryptographically verifies the workflow-generated GitHub/Sigstore
build attestation by bundle digest. GitHub's separate automatic release
attestation covers the locked tag and release assets. The endpoint returns
`addonReleaseId`, `state` and `nativeManifestDigest`; it never fetches an
Actions artifact and receives no caller-selected URL.

When `state == candidate`, the same Ubuntu job creates the exact
`NativeBuildEvidenceV1` document and makes a second POST to
`/api/internal/native-admission/releases/{addonReleaseId}/evidence`. That
`application/json` envelope contains `schemaVersion: 1`, stable evidence, a
volatile `attempt` object and a multipart `materialsArtifact` descriptor. The
attempt binds the OIDC run ID/attempt and observes the publisher's actual
`ImageOS`, `ImageVersion`, Node.js and PowerShell versions; those changing
observations are stored outside immutable release materials. A separate custom
predicate, `github-hosted-runner-observation-v1`, binds that same run and
bundle digest to both Windows replicas' actual `ImageOS`/`ImageVersion`,
Node.js and PowerShell versions, default runner `rustc -vV`/`cargo -Vv`
observations, available MSVC linker and complete Windows SDK versions, plus the
exact pinned Windhawk clang/LLD executable digests and versions when hooks were
built. The backend
downloads every materials part and reconstructs the exact logical archive
through GitHub. It uses the separate
`mywallpaper-native-admission-development` or
`mywallpaper-native-admission-production` audience. Success must return the
same release/evidence digests and `state == available`. No bundle or materials
bytes traverse the MyWallpaper/Cloudflare request path.

Both endpoints accept only
`iss=https://token.actions.githubusercontent.com`, `event_name=push`, a
`refs/tags/v*` caller ref, the numeric caller `repository_id`, exact caller `sha`,
`runner_environment=github-hosted` and a `job_workflow_sha` in the explicit
`admission-v1` allowlist. `job_workflow_ref` must be the workflow path followed
by `@` and that same exact 40-character `job_workflow_sha`; branch, tag and
shorthand references are rejected. The candidate attestation identity, both
OIDC tokens and volatile `attempt` must agree on the same GitHub run ID and run
attempt.

The final evidence always records:

- workflow repository `MyWallpapers/native-addon-toolchain`;
- repository ref `refs/heads/admission-v1`;
- the resolved allowlisted workflow SHA, without volatile run ID/attempt;
- exact source, lockfile, environment, distribution, native-manifest, SBOM,
  provenance, materials and author-inventory digests;
- `reproducible: true` backed by the two byte-identical Windows replicas;
- the source license SPDX identifier read from GitHub at the exact caller
  commit.

The source repository ID/commit, add-on tag, workflow SHA, artifact digest and
distribution digest in `admission-subject-v1.json` must all equal the OIDC
claims and the ingested candidate. The included in-toto statement uses
`https://mywallpaper.online/buildTypes/addon-admission/v1` and records the
source commit, toolchain commit, lockfile digest, reviewed environment digest
and the two identical output-inventory digests. Here “environment” contains
only globally reviewed toolchain inputs: runner contract, pinned Node version,
canonical CLI lock and exact workflow commit. The add-on manifest and committed
companion commands remain signed source and provenance inputs, but never alter
the server-allowlisted global environment digest. The floating runner image is
recorded separately on each attempt. It is never added to `environmentDigest`,
so a GitHub image rollout neither masquerades as an immutable image pin nor
changes deterministic materials already locked under a release tag.

The Rust, MSVC and Windows SDK values inventory tools observable on the hosted
runner; they do not claim that every add-on invoked each one. Rust is observed
from the trusted toolchain checkout so a caller-controlled rustup override
cannot rewrite this runner fact. The committed companion command and lockfiles
remain the source of truth for caller-selected build tools, and both output
trees must still be byte-identical. Conversely, for a Windhawk hook, the
recorded clang and LLD are the exact verified, archive-locked executables used
by the canonical hook build. A no-hook release records `used: false` instead
of inventing compiler versions.

After merging a reviewed toolchain revision, calculate the exact value to
allowlist in MyWallpaper from that checkout:

```bash
node .github/scripts/compute-admission-environment-digest.mjs \
  --workflow-sha "$(git rev-parse HEAD)"
```

The internal subject handoff contains only `admission-subject-v1.json`. The
logical, immutable materials archive contains:

- `admission-subject-v1.json`;
- `bundle-index.json`, canonical payload and author inventories;
- the exact Git tree and tracked lockfile inventory;
- the reviewed build-recipe descriptor, committed companion command/config and
  both stable replica label/OS/architecture contracts;
- `sbom.cdx.json` and `provenance.intoto.json`;

Actions artifacts are only internal job handoffs. The backend receives logical
root/part descriptors and downloads persistent immutable release parts through
GitHub's API.

The volatile predicate is a separate one-run Actions handoff and custom
GitHub/Sigstore attestation associated with `mywallpaper-addon-bundle.zip` by
SHA-256. It is intentionally neither a release asset nor a member of the
deterministic materials ZIP. A rerun can therefore produce a new observation
attestation while strictly reusing the same immutable bundle and materials.

The subject intentionally has no internal `addonReleaseId` because that UUID
does not exist before ingestion. The trusted finalizer adds the returned UUID,
native-manifest digest, exact materials digest/size and GitHub license result
without rebuilding or executing any add-on code.

Operators can independently verify the immutable release and each downloaded
physical part with GitHub CLI. After concatenating the parts in numeric index
order, they can verify the reconstructed logical bundle attestation while
pinning both caller source and signer workflow digests:

```powershell
gh release verify vVERSION --repo OWNER/ADDON
gh release verify-asset vVERSION `
  .\mywallpaper-addon-bundle-sha256-ROOT.zip.part-0-sha256-PART `
  --repo OWNER/ADDON
gh attestation verify .\mywallpaper-addon-bundle.zip `
  --repo OWNER/ADDON `
  --signer-workflow MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml `
  --signer-digest ALLOWLISTED_TOOLCHAIN_SHA `
  --source-digest ADDON_COMMIT_SHA `
  --source-ref refs/tags/VERSION `
  --deny-self-hosted-runners
```

`bundle-index.json` is canonical JSON with schema version, SemVer, provenance,
source and manifest digests, entry path, the exact `{runtime, settings, native,
ui}` capability snapshot and a sorted payload inventory. The index excludes
itself. Its SHA-256 is the distribution digest, so there is no self-reference.

## Canonical release validator artifact

The private application repository is never checked out by an add-on workflow
and no secret is exposed to caller code. Instead, this public repository carries
one generated `mywallpaper-cli.zip` plus a lock containing its byte size,
SHA-256 and exact MyWallpaper source commit. Despite the historical filename,
the archive is not the public developer CLI: it contains only the `generate`
and `check` command closure, the Canvas declaration, the settings-header
generator and the pinned Windhawk builder. In particular, it excludes
`init`, `dev` and `doctor`, so the workflow SHA generated by `init` can advance
without changing the validator embedded by that workflow. Its pinned Windows
x64 `sharp` runtime closure is vendored in the same content-addressed archive,
so the trusted verifier never installs packages from a registry. The old
parallel validator and SDK copies no longer exist here.

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

The Windhawk compiler, headers and upstream source inputs embedded by that validator
are fetched only from HTTPS resources whose byte size and SHA-256 are pinned.
The MyWallpaper SDK header remains under its source-visible proprietary SDK
license; the Windhawk engine and API remain governed by their upstream GPL
terms.
