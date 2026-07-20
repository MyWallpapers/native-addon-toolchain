#!/usr/bin/env node

import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'

function fail(message) {
  throw new Error(message)
}

function requireText(text, fragment, label) {
  if (!text.includes(fragment)) fail(`Reusable workflow is missing ${label}.`)
}

function section(text, start, end) {
  const from = text.indexOf(start)
  if (from < 0) fail(`Reusable workflow is missing ${start}.`)
  const to = end ? text.indexOf(end, from + start.length) : text.length
  if (end && to < 0) fail(`Reusable workflow is missing ${end}.`)
  return text.slice(from, to)
}

const path = process.argv[2] ?? '.github/workflows/native-addon-build.yml'
const workflow = await readFile(path, 'utf8')
const assetPublisher = await readFile(
  resolve(dirname(path), '../scripts/publish-release-assets.ps1'),
  'utf8',
)
const releasePreparer = await readFile(
  resolve(dirname(path), '../scripts/prepare-immutable-release.ps1'),
  'utf8',
)
const releaseFinalizer = await readFile(
  resolve(dirname(path), '../scripts/finalize-immutable-release.ps1'),
  'utf8',
)
const evidenceGenerator = await readFile(
  resolve(dirname(path), '../scripts/create-admission-evidence.mjs'),
  'utf8',
)
const environmentGenerator = await readFile(
  resolve(dirname(path), '../scripts/admission-environment.mjs'),
  'utf8',
)
const nativeEvidenceGenerator = await readFile(
  resolve(dirname(path), '../scripts/create-native-build-evidence.mjs'),
  'utf8',
)
const runnerObservationGenerator = await readFile(
  resolve(dirname(path), '../scripts/runner-observation.mjs'),
  'utf8',
)
const runnerObservationCollector = await readFile(
  resolve(dirname(path), '../scripts/record-replica-observation.ps1'),
  'utf8',
)
const artifactSplitter = await readFile(
  resolve(dirname(path), '../scripts/split-release-artifact.ps1'),
  'utf8',
)
const artifactVerifier = await readFile(
  resolve(dirname(path), '../scripts/verify-release-artifact-parts.ps1'),
  'utf8',
)
const releaseOnMainVerifier = await readFile(
  resolve(dirname(path), '../scripts/assert-release-on-default-branch.mjs'),
  'utf8',
)
const immutableCheckout = await readFile(
  resolve(dirname(path), '../scripts/materialize-immutable-repository.ps1'),
  'utf8',
)
const safeFiles = await readFile(
  resolve(dirname(path), '../scripts/safe-files.mjs'),
  'utf8',
)
const pushTagGuard = "github.event_name == 'push' && github.event.created == true && github.event.deleted == false && github.event.repository.private == false && github.ref_type == 'tag' && startsWith(github.ref, 'refs/tags/v')"
requireText(workflow, 'name: MyWallpaper add-on admission-v1', 'the versioned contract name')
requireText(workflow, 'workflow_call:', 'the reusable workflow trigger')
requireText(workflow, pushTagGuard, 'the newly-created v-prefixed tag guard')
requireText(workflow, 'replica: [1, 2]', 'exactly two build replicas')
requireText(workflow, 'runs-on: windows-2025', 'the reviewed Windows build image')
requireText(workflow, 'runs-on: ubuntu-24.04', 'the data-only Ubuntu publisher image')
if (workflow.includes('uses: actions/checkout@')) {
  fail('Reusable admission jobs must materialize exact commits without the checkout action data-flow ambiguity.')
}
if ((workflow.match(/https:\/\/github\.com\/MyWallpapers\/native-addon-toolchain\.git/gu) ?? []).length !== 3) {
  fail('Every job must fetch only the static trusted toolchain repository.')
}
for (const [fragment, label] of [
  ['GIT_CONFIG_NOSYSTEM', 'system Git configuration isolation'],
  ['GIT_CONFIG_GLOBAL', 'global Git configuration isolation'],
  ['credential.helper=', 'credential-free Git transport'],
  ['http.followRedirects=false', 'Git redirect refusal'],
  ['remote remove origin', 'post-checkout remote removal'],
]) {
  if (workflow.split(fragment).length - 1 !== 3) {
    fail(`Every trusted toolchain materialization needs ${label}.`)
  }
}
for (const [fragment, label] of [
  ['GIT_CONFIG_NOSYSTEM', 'system Git configuration isolation'],
  ['GIT_CONFIG_GLOBAL', 'global Git configuration isolation'],
  ['credential.helper=', 'credential-free Git transport'],
  ['http.followRedirects=false', 'Git redirect refusal'],
  ["'fetch', '--quiet', '--no-tags', '--depth=1'", 'single-commit immutable Git fetch'],
  ["'remote', 'set-url', 'origin'", 'canonical public provenance origin'],
]) requireText(immutableCheckout, fragment, label)
if (immutableCheckout.includes('GITHUB_TOKEN') || immutableCheckout.includes('github.token')) {
  fail('Immutable public-source materialization must not receive a GitHub credential.')
}
if (immutableCheckout.includes("'remote', 'remove', 'origin'")) {
  fail('Immutable caller materialization must retain its credential-free canonical public origin for provenance validation.')
}
for (const [fragment, label] of [
  ['handle.readFile()', 'descriptor-bound reads'],
  ['await handle.read(buffer, 0, length, position)', 'descriptor-bound streaming digests'],
  ['constants.O_NOFOLLOW', 'no-follow file opening'],
  ['sameContentVersion(opened, afterRead)', 'concurrent file-change detection'],
  ['sameIdentity(opened, pathAfterRead)', 'post-read path identity verification'],
]) requireText(safeFiles, fragment, label)

const lines = workflow.replaceAll('\r\n', '\n').split('\n')
const runBodies = []
for (let index = 0; index < lines.length; index += 1) {
  const match = /^(\s*)run:\s*\|\s*$/u.exec(lines[index])
  if (!match) continue
  const indentation = match[1].length
  const body = []
  for (index += 1; index < lines.length; index += 1) {
    const line = lines[index]
    if (line.trim() !== '' && line.match(/^\s*/u)[0].length <= indentation) {
      index -= 1
      break
    }
    body.push(line)
  }
  runBodies.push(body.join('\n'))
}
if (runBodies.some((body) => body.includes('${{'))) {
  fail('Shell bodies must consume GitHub and step values only through environment variables.')
}
if ((workflow.match(/\$env:WORKFLOW_REF -cne "\$prefix\$env:WORKFLOW_SHA"/gu) ?? []).length !== 3) {
  fail('Every job must require the exact full reusable-workflow SHA reference.')
}
if (workflow.includes('${prefix}refs/heads/admission-v1')) {
  fail('The contents:write workflow must never execute from a movable branch reference.')
}
if ((workflow.match(/OPERATIONAL_MAX_ARCHIVE_BYTES: '4294967296'/gu) ?? []).length !== 2) {
  fail('Both logical archives must use the reviewed 4 GiB runner budget.')
}
requireText(assetPublisher, '$GitHubAssetExclusiveByteLimit = 2147483648L', 'GitHub asset transport limit')
requireText(assetPublisher, '$id -cnotmatch', 'decimal-string GitHub asset IDs')
requireText(assetPublisher, '$remoteDigest -ceq $Digest', 'remote GitHub asset digest verification')
requireText(assetPublisher, 'StatusCode -eq 422', 'immutable-name upload race handling')
requireText(assetPublisher, "'application/octet-stream'", 'opaque part media type')
requireText(assetPublisher, 'Start-Sleep', 'bounded asynchronous GitHub digest polling')
requireText(artifactSplitter, '[Math]::Floor(($source.Length - 1L) / $PartSizeBytes)', 'deterministic fixed-size splitting')
requireText(artifactVerifier, '$rootHash.AppendData', 'logical root digest reconstruction')
requireText(workflow, "RELEASE_PART_SIZE_BYTES: '1073741824'", 'the reviewed 1 GiB release part size')
requireText(workflow, "OPERATIONAL_MAX_RELEASE_ASSETS: '1000'", 'GitHub maximum release asset count')
for (const [text, label] of [
  [releasePreparer, 'release preparer'],
  [assetPublisher, 'asset publisher'],
  [releaseFinalizer, 'release finalizer'],
]) {
  requireText(text, '2026-03-10', `${label} GitHub API version`)
  requireText(text, 'github-api-contract.ps1', `${label} JSON-array normalization contract`)
  requireText(text, 'ConvertTo-GitHubApiItemList', `${label} paginated JSON-array normalization`)
  if (/@\(\s*Invoke-GitHubGet/iu.test(text)) {
    fail(`${label} must not directly wrap Invoke-RestMethod JSON arrays in @(...).`)
  }
}
if (/-Method\s+(?:Delete|Patch)\b/iu.test(assetPublisher)) {
  fail('GitHub Release asset publication must never delete or overwrite an asset.')
}
if (/-Method\s+(?:Delete|Patch)\b/iu.test(releasePreparer)) {
  fail('GitHub draft preparation must never delete or publish an existing release.')
}
if (/-Method\s+Delete\b/iu.test(releaseFinalizer)) {
  fail('GitHub immutable release finalization must never delete release state.')
}
requireText(releasePreparer, 'draft = $true', 'controlled draft-only release creation')
requireText(releasePreparer, 'Get-TagCommit', 'draft tag-to-commit verification')
requireText(releasePreparer, 'An already-published mutable GitHub release is never reusable', 'mutable release refusal')
requireText(releaseFinalizer, '-Method Patch', 'controlled draft publication')
requireText(releaseFinalizer, '[bool]$Release.immutable', 'GitHub immutable release assertion')
requireText(releaseFinalizer, 'Wait-ImmutableRelease', 'bounded immutable-state polling')
requireText(releaseFinalizer, "'release-immutable=true'", 'immutable release output')
if (evidenceGenerator.includes('new Date().toISOString()')
  || evidenceGenerator.includes("'workflow-run-id'")
  || evidenceGenerator.includes("'workflow-run-attempt'")) {
  fail('Immutable admission materials must not depend on wall-clock time or workflow attempts.')
}
requireText(evidenceGenerator, "['show', '-s', '--format=%cI', commitSha]", 'stable source commit timestamp')
requireText(environmentGenerator, "kind: 'reviewed-build-environment'", 'global reviewed-environment classification')
if (environmentGenerator.includes('authorBuildRecipe') || environmentGenerator.includes('companionBuildConfig')) {
  fail('The global environment digest must not include add-on-controlled build inputs.')
}
requireText(
  evidenceGenerator,
  "uri: 'mywallpaper:native-companion-build-config'",
  'committed companion command/config provenance',
)
requireText(
  evidenceGenerator,
  'Volatile runner observations must remain outside immutable admission materials.',
  'volatile runner-observation separation',
)
requireText(
  runnerObservationGenerator,
  "contract: 'github-hosted-runner-observation-v1'",
  'the versioned runner-observation predicate',
)
for (const [fragment, label] of [
  ["'ImageOS'", 'build-runner ImageOS observation'],
  ["'ImageVersion'", 'build-runner ImageVersion observation'],
  ["@('-vV')", 'rustc verbose-version observation'],
  ["@('-Vv')", 'cargo verbose-version observation'],
  ["'MSVC linker version could not be parsed'", 'MSVC linker observation'],
  ["'No complete Windows SDK was observed'", 'Windows SDK observation'],
  ["'bin/ld.lld.exe'", 'pinned Windhawk linker observation'],
]) requireText(runnerObservationCollector, fragment, label)

const build = section(workflow, '  build-untrusted:', '  verify-package:')
const verifier = section(workflow, '  verify-package:', '  attest-publish:')
const publisher = section(workflow, '  attest-publish:')
requireText(
  build,
  'Materialize isolated immutable caller copies without credentials',
  'separate untrusted build copies',
)
requireText(
  verifier,
  'Materialize the immutable caller source without credentials',
  'immutable verifier source materialization',
)
if (publisher.includes('materialize-immutable-repository.ps1')) {
  fail('The privileged publisher must never materialize caller-controlled source.')
}
const splitTransportStep = section(
  verifier,
  '      - name: Split logical archives into deterministic release parts',
  '      - name: Stage the public admission subject',
)
const reproduceTransportStep = section(
  publisher,
  '      - name: Reproduce both logical archives from deterministic parts',
  '      - name: Verify the admission subject as an opaque file',
)
for (const [step, script, label] of [
  [splitTransportStep, 'split-release-artifact.ps1', 'release transport splitting'],
  [reproduceTransportStep, 'verify-release-artifact-parts.ps1', 'release transport verification'],
]) {
  if (step.split(script).length - 1 !== 2) {
    fail(`Both logical archives must use the reviewed ${label} script.`)
  }
  if (step.includes('$LASTEXITCODE')) {
    fail(`PowerShell ${label} must rely on terminating errors, not residual $LASTEXITCODE state.`)
  }
}
for (const [name, value] of [['build', build], ['verifier', verifier], ['publisher', publisher]]) {
  requireText(value, "RUNNER_ENVIRONMENT: ${{ runner.environment }}", `${name} GitHub-hosted runner observation`)
  requireText(value, "-cne 'github-hosted'", `${name} fail-closed runner guard`)
}
const mainGuardCommand = 'node toolchain/.github/scripts/assert-release-on-default-branch.mjs'
if ((workflow.split(mainGuardCommand).length - 1) !== 2) {
  fail('Admission must check reviewed default-branch ancestry in each replica and again before publication.')
}
const buildMainGuardIndex = build.indexOf(mainGuardCommand)
const firstCallerExecutionIndex = build.indexOf('Build hooks from a pristine checkout without registry code')
if (buildMainGuardIndex < 0 || firstCallerExecutionIndex <= buildMainGuardIndex) {
  fail('Reviewed default-branch ancestry must be proven before any caller code is built.')
}
const publisherMainGuardIndex = publisher.indexOf(mainGuardCommand)
const draftReleaseIndex = publisher.indexOf('Create or reuse the exact controlled GitHub draft release')
if (publisherMainGuardIndex < 0 || draftReleaseIndex <= publisherMainGuardIndex) {
  fail('Reviewed default-branch ancestry must be reconfirmed immediately before release publication.')
}
if ((workflow.match(/MYWALLPAPER_GITHUB_TOKEN: \$\{\{ github\.token \}\}/gu) ?? []).length !== 2) {
  fail('Reviewed default-branch checks must use only the job-scoped GitHub token.')
}
const buildMainGuardStep = section(
  build,
  '      - name: Require the tagged release commit on the reviewed default branch',
  '      - name: Verify and expand canonical MyWallpaper CLI',
)
const publisherMainGuardStep = section(
  publisher,
  '      - name: Reconfirm the tagged release commit on the reviewed default branch',
  '      - name: Create or reuse the exact controlled GitHub draft release',
)
for (const [value, label] of [
  [buildMainGuardStep, 'replica reviewed default-branch check'],
  [publisherMainGuardStep, 'publisher reviewed default-branch check'],
]) {
  requireText(value, '--repository-id "$env:GITHUB_REPOSITORY_ID"', `${label} numeric identity binding`)
}
for (const [fragment, label] of [
  ["const defaultBranch = metadata.default_branch", 'public default-branch binding'],
  ["encodeURIComponent(defaultBranch)", 'default-branch URL encoding'],
  ["defaultReference?.ref !== `refs/heads/${defaultBranch}`", 'exact default-branch ref binding'],
  ["String(metadata.id) !== repositoryId", 'numeric repository identity binding'],
  ["redirect: 'error'", 'redirect refusal'],
  ["comparison.merge_base_commit?.sha !== commitSha", 'merge-base ancestry proof'],
  ["comparison.behind_by !== 0", 'behind/diverged comparison refusal'],
]) requireText(releaseOnMainVerifier, fragment, label)
if (build.match(/runs-on:/gu)?.length !== 1
  || !/matrix:\r?\n        replica: \[1, 2\]/u.test(build)) {
  fail('Build boundary must remain one two-replica matrix job.')
}
for (const component of ['web', 'companion', 'hooks']) {
  requireText(verifier, `mywallpaper-${component}-1-`, `primary ${component} output`)
  requireText(verifier, `mywallpaper-${component}-2-`, `reproduced ${component} output`)
}
if (verifier.includes('build-native-hooks.ps1') || verifier.includes('pnpm install')) {
  fail('The verifier must not rebuild or execute caller build commands.')
}
if (verifier.includes('id-token: write') || verifier.includes('attestations: write')) {
  fail('The verifier must not receive OIDC or attestation write permission.')
}
requireText(publisher, 'id-token: write', 'publisher OIDC permission')
requireText(publisher, 'attestations: write', 'publisher attestation permission')
requireText(publisher, 'artifact-metadata: write', 'publisher artifact-metadata permission')
requireText(publisher, 'contents: write', 'publisher GitHub Release asset permission')
requireText(
  publisher,
  'uses: actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6 # v4.2.0',
  'the reviewed actions/attest v4.2.0 revision',
)
requireText(publisher, 'subject-name: mywallpaper-addon-bundle.zip', 'the bundle attestation subject')
requireText(
  publisher,
  'subject-digest: ${{ needs.verify-package.outputs.archive-sha256 }}',
  'the exact bundle attestation digest',
)
const attestations = publisher.match(/uses: actions\/attest@/gu) ?? []
if (attestations.length !== 2) {
  fail('The release ZIP must have exactly one build-provenance and one runner-observation attestation.')
}
requireText(
  publisher,
  'predicate-type: https://mywallpaper.online/predicates/github-hosted-runner-observation/v1',
  'the custom runner-observation predicate type',
)
requireText(
  publisher,
  'predicate-path: ${{ steps.runner-observation.outputs.predicate }}',
  'the verified runner-observation predicate path',
)
if ((publisher.match(/subject-name: mywallpaper-addon-bundle\.zip/gu) ?? []).length !== 2
  || (publisher.match(/subject-digest: \$\{\{ needs\.verify-package\.outputs\.archive-sha256 \}\}/gu) ?? []).length !== 2) {
  fail('Both attestations must bind the exact same logical bundle digest.')
}
if (publisher.includes('subject-attestation') || publisher.includes('materials-attestation')) {
  fail('Admission subject and materials must be submitted to the finalizer, not separately attested.')
}
requireText(publisher, 'create-native-build-evidence.mjs', 'NativeBuildEvidenceV1 transformation')
if (nativeEvidenceGenerator.includes("'workflow-run-id'")
  || nativeEvidenceGenerator.includes("'workflow-run-attempt'")) {
  fail('Stable NativeBuildEvidenceV1 must not contain workflow attempt identity.')
}
requireText(publisher, 'runId = [string]$env:GITHUB_RUN_ID', 'volatile workflow run binding')
requireText(publisher, 'runAttempt = [string]$env:GITHUB_RUN_ATTEMPT', 'volatile workflow attempt binding')
requireText(publisher, 'imageOs = [string]$env:ImageOS', 'publisher image OS observation')
requireText(publisher, 'imageVersion = [string]$env:ImageVersion', 'publisher image version observation')
requireText(publisher, 'nodeVersion = $nodeVersion', 'publisher Node.js observation')
requireText(publisher, 'pwshVersion = $pwshVersion', 'publisher PowerShell observation')
requireText(publisher, 'mywallpaper-native-admission-development', 'the development finalizer audience')
requireText(publisher, 'mywallpaper-native-admission-production', 'the production finalizer audience')
requireText(
  publisher,
  '/api/internal/native-admission/releases',
  'the hardcoded native admission finalizer endpoint',
)
requireText(
  publisher,
  '/api/internal/addon-release-ingestion',
  'the dedicated non-OpenAPI ingestion endpoint',
)
requireText(publisher, 'publish-release-assets.ps1', 'content-addressed GitHub Release asset publication')
requireText(publisher, 'prepare-immutable-release.ps1', 'controlled GitHub draft preparation')
requireText(publisher, 'finalize-immutable-release.ps1', 'GitHub immutable release publication')
requireText(publisher, "IMMUTABLE_RELEASE -cne 'true'", 'immutable-release gate before admission OIDC')
requireText(publisher, 'artifact = $artifact', 'the multipart bundle artifact descriptor')
requireText(publisher, ',"attempt":', 'the volatile attempt descriptor envelope')
requireText(publisher, ',"materialsArtifact":', 'the multipart materials artifact descriptor envelope')
if (publisher.includes('MultipartFormDataContent') || publisher.includes("-ContentType 'application/zip'")) {
  fail('Large bundle or materials bytes must never traverse the MyWallpaper HTTP endpoints.')
}
const draftIndex = publisher.indexOf('Create or reuse the exact controlled GitHub draft release')
const attestIndex = publisher.indexOf('uses: actions/attest@')
const proofIndex = publisher.indexOf('Verify both GitHub/Sigstore proofs before admission OIDC')
const assetIndex = publisher.indexOf('Publish immutable content-addressed GitHub Release assets')
const immutableIndex = publisher.indexOf('Publish and cryptographically lock the GitHub Release')
const ingestionIndex = publisher.indexOf('Publish the immutable release through GitHub OIDC')
const evidenceIndex = publisher.indexOf('Create NativeBuildEvidenceV1 for the accepted candidate')
const finalizerIndex = publisher.indexOf('Finalize native admission with a second GitHub OIDC token')
if (draftIndex < 0 || attestIndex <= draftIndex || proofIndex <= attestIndex || assetIndex <= proofIndex
  || immutableIndex <= assetIndex || ingestionIndex <= immutableIndex
  || evidenceIndex <= ingestionIndex || finalizerIndex <= evidenceIndex) {
  fail('Draft, attestation, immutable publication, ingestion and finalization are out of order.')
}
if ((publisher.match(/ACTIONS_ID_TOKEN_REQUEST_TOKEN/gu) ?? []).length !== 2) {
  fail('The publisher must request separate ingestion and finalizer OIDC tokens.')
}
for (const forbiddenHeader of [
  'X-MyWallpaper-Admission-Contract',
  'X-MyWallpaper-Admission-Materials-Digest',
  'X-MyWallpaper-Admission-Subject-Digest',
  'X-MyWallpaper-Attestation-Bundle-Digest',
  'X-MyWallpaper-Bundle-Attestation-ID',
  'X-MyWallpaper-Distribution-Digest',
]) {
  if (publisher.includes(forbiddenHeader)) fail(`Publisher retains redundant proof header: ${forbiddenHeader}`)
}
if (publisher.includes('ref: ${{ github.sha }}')) {
  fail('The OIDC-capable publisher must never check out caller source.')
}
if (publisher.includes('/api/addon-releases')) {
  fail('The legacy OpenAPI add-on release endpoint must not expose admission ingestion.')
}
if (workflow.includes('github.event.release') || workflow.includes("github.event_name == 'release'")) {
  fail('admission-v1 must derive publication only from a newly-created tag push.')
}
const releaseGuards = workflow.split(pushTagGuard).length - 1
if (releaseGuards !== 3) fail('Every admission-v1 job must have the exact new-tag push guard.')
if ((workflow.match(/^\s{4}runs-on:/gmu) ?? []).length !== 3) {
  fail('admission-v1 must remain two matrix replicas plus one verifier and one publisher job.')
}
for (const match of workflow.matchAll(/^\s*uses:\s*([^\s#]+).*$/gmu)) {
  const target = match[1]
  if (target.startsWith('./')) continue
  const revision = target.split('@')[1]
  if (!/^[0-9a-f]{40}$/u.test(revision ?? '')) fail(`Action is not pinned by full SHA: ${target}`)
}
process.stdout.write('admission-v1 reusable workflow contract is intact\n')
