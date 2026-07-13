# MyWallpaper native add-on toolchain

This public repository is the immutable trust boundary used to build native
MyWallpaper add-ons from public source repositories. It contains no product
backend, credential or end-user runtime.

Add-ons call `.github/workflows/native-addon-build.yml` by a full commit SHA.
An isolated `verify-web` job checks out the caller and that exact toolchain
revision, installs the locked pnpm graph, typechecks and rebuilds the web
bundle, and requires the caller's complete Git working tree to remain clean.
Only its success result reaches `build`: the native job starts on a fresh
runner, repeats both immutable checkouts, restores the pinned Node runtime,
then builds Windows companions and product-owned Windhawk hooks without
credentials. It creates one deterministic archive and transfers only that
archive to an isolated OIDC publisher job.

The Windhawk compiler, headers and upstream source inputs are downloaded only
from HTTPS locations whose byte size and SHA-256 are pinned in
`.github/scripts/windhawk-v1.lock.json`. End users never run this toolchain.

## Caller

```yaml
jobs:
  native:
    permissions:
      actions: read
      contents: read
      id-token: write
    uses: MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml@FULL_COMMIT_SHA
```

The MyWallpaper API independently verifies the caller repository, commit,
workflow identity and OIDC audience before accepting an archive. Explorer
hooks additionally require the caller's numeric GitHub repository ID to be on
the reviewed allowlist.

The MyWallpaper SDK header is MIT licensed. The pinned Windhawk engine and API
remain governed by their upstream GPL terms; this build repository does not
ship the engine itself.

Companion executables use the `process-v2` runtime and implement MyWallpaper's
strict, surface-aware
[companion protocol v2](https://github.com/MyWallpapers/MyWallpaper/blob/main/docs/native-addons.md#companion-protocol-v2).
