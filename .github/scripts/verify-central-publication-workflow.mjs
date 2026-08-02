#!/usr/bin/env node

import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'

function fail(message) {
  throw new Error(message)
}

function requireText(text, fragment, label) {
  if (!text.includes(fragment)) fail(`Central publication is missing ${label}.`)
}

function requireCount(text, fragment, expected, label) {
  const actual = text.split(fragment).length - 1
  if (actual !== expected) {
    fail(`Central publication requires ${expected} ${label}; found ${actual}.`)
  }
}

function section(text, start, end) {
  const from = text.indexOf(start)
  if (from < 0) fail(`Central publication is missing ${start}.`)
  const to = end ? text.indexOf(end, from + start.length) : text.length
  if (end && to < 0) fail(`Central publication is missing ${end}.`)
  return text.slice(from, to)
}

function assertNoExpressionsInShellBodies(workflow, label) {
  const lines = workflow.replaceAll('\r\n', '\n').split('\n')
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^(\s*)run:\s*\|\s*$/u.exec(lines[index])
    if (!match) continue
    const indentation = match[1].length
    const body = []
    for (index += 1; index < lines.length; index += 1) {
      const line = lines[index]
      if (line.trim() !== '' && /^\s*/u.exec(line)[0].length <= indentation) {
        index -= 1
        break
      }
      body.push(line)
    }
    if (body.join('\n').includes('${{')) {
      fail(`${label} shell bodies must receive GitHub values only through env.`)
    }
  }
}

const wrapperPath = process.argv[2] ?? '.github/workflows/central-addon-publication.yml'
const reusablePath = process.argv[3] ?? '.github/workflows/native-addon-build.yml'
// Git may materialize workflows with CRLF on Windows runners. Contract checks
// must validate YAML semantics, not the checkout platform's line endings.
const wrapper = (await readFile(wrapperPath, 'utf8')).replaceAll('\r\n', '\n')
const reusable = (await readFile(reusablePath, 'utf8')).replaceAll('\r\n', '\n')
const scriptRoot = resolve(dirname(reusablePath), '../scripts')
const preparer = await readFile(resolve(scriptRoot, 'prepare-immutable-release.ps1'), 'utf8')
const finalizer = await readFile(resolve(scriptRoot, 'finalize-immutable-release.ps1'), 'utf8')
const nativeEvidence = await readFile(resolve(scriptRoot, 'create-native-build-evidence.mjs'), 'utf8')

requireText(wrapper, 'name: MyWallpaper central add-on publication', 'the named central entrypoint')
requireText(wrapper, '  workflow_dispatch:\n', 'the explicit server-dispatched trigger')
requireText(wrapper, 'permissions: {}', 'a credential-free workflow default')
requireText(wrapper, 'group: central-addon-publication-${{ inputs.publication_request_id }}', 'request-scoped concurrency')
requireText(wrapper, 'cancel-in-progress: false', 'non-cancelling request serialization')
const wrapperInputs = [
  'publication_request_id',
  'publication_attempt_id',
  'source_repository_id',
  'source_repository',
  'source_commit_sha',
  'source_ref',
  'source_version',
  'channel',
]
for (const [index, input] of wrapperInputs.entries()) {
  const next = wrapperInputs[index + 1]
  const inputSection = section(
    wrapper,
    `      ${input}:`,
    next === undefined ? '\n\npermissions:' : `      ${next}:`,
  )
  requireText(inputSection, 'required: true', `required ${input} input`)
}
if (wrapper.includes('secrets:') || wrapper.includes('${{ secrets.')) {
  fail('Central publication must not receive repository secrets.')
}
if (wrapper.includes('actions/checkout@')) {
  fail('Central authorization must not checkout mutable repository content.')
}
assertNoExpressionsInShellBodies(wrapper, 'Central wrapper')

const authorize = section(wrapper, '  authorize:', '  release:')
const release = section(wrapper, '  release:', '  complete:')
const complete = section(wrapper, '  complete:')
for (const value of [authorize, complete]) {
  requireText(value, 'runs-on: ubuntu-24.04', 'GitHub-hosted Ubuntu control-plane execution')
  requireText(value, 'permissions:\n      id-token: write', 'OIDC-only job permission')
  if (/\bcontents:\s*write\b/u.test(value) || /\bactions:\s*write\b/u.test(value)) {
    fail('OIDC control-plane jobs must not receive repository write permissions.')
  }
}
requireText(authorize, "-cne 'github-hosted'", 'the GitHub-hosted runner guard')
requireText(authorize, "$env:GITHUB_REPOSITORY -cne 'MyWallpapers/native-addon-toolchain'", 'the exact toolchain repository guard')
requireText(authorize, "$env:GITHUB_REF -cnotmatch '^refs/tags/central-publication-v", 'the immutable toolchain release ref guard')
requireText(authorize, '$env:GITHUB_WORKFLOW_SHA -cne $env:GITHUB_SHA', 'the exact wrapper workflow SHA guard')
requireText(authorize, "$env:GITHUB_RUN_ATTEMPT -cne '1'", 'one immutable GitHub run per attempt')
requireText(authorize, 'sourceRepositoryId = $env:SOURCE_REPOSITORY_ID', 'numeric source identity in the claim')
requireText(authorize, 'publicationAttemptId = $env:PUBLICATION_ATTEMPT_ID', 'immutable attempt identity in the claim')
requireText(authorize, 'sourceRepository = $env:SOURCE_REPOSITORY', 'source repository in the claim')
requireText(authorize, 'sourceRef = $env:SOURCE_REF', 'source tag in the claim')
requireText(authorize, 'sourceCommitSha = $env:SOURCE_COMMIT_SHA', 'source commit in the claim')
requireText(authorize, 'sourceVersion = $env:SOURCE_VERSION', 'source version in the claim')
requireText(authorize, 'channel = $env:PUBLICATION_CHANNEL', 'publication channel in the claim')
requireText(authorize, '/api/internal/addon-publication-requests/$env:PUBLICATION_REQUEST_ID/claim', 'the fixed claim endpoint')
requireText(authorize, "'Idempotency-Key' = \"addon-publication:$env:PUBLICATION_REQUEST_ID:$env:PUBLICATION_ATTEMPT_ID:claim\"", 'attempt-bound claim idempotency')
requireText(authorize, "$response.state -cne 'building'", 'the strict building response transition')
requireText(authorize, '$response.PSObject.Properties.Name', 'the exact claim response shape check')
requireText(authorize, '-TimeoutSec 20', 'a bounded claim request timeout')
requireText(authorize, '$status -eq 425 -or', 'bounded pre-registration race handling')
requireText(authorize, '$status -eq 429 -or', 'bounded service-throttling recovery')
requireText(authorize, '($status -ge 500 -and $status -le 599) -or', 'bounded server-failure recovery')
requireText(authorize, '$exception -is [System.Threading.Tasks.TaskCanceledException]', 'bounded network-timeout recovery')
requireText(authorize, '$retryable -and $claimAttempt -lt 5', 'bounded transient claim retries')
requireText(authorize, '$httpResponse.Headers.RetryAfter', 'server-directed retry delay support')
requireText(authorize, '[Math]::Min(', 'bounded Retry-After delay')
requireText(authorize, 'Start-Sleep -Seconds $delaySeconds', 'bounded claim backoff')

requireText(release, 'needs: authorize', 'authorization before untrusted builds')
requireText(release, 'uses: ./.github/workflows/native-addon-build.yml', 'the local reviewed reusable workflow')
for (const input of [
  'publication_request_id',
  'publication_attempt_id',
  'source_repository_id',
  'source_repository',
  'source_commit_sha',
  'source_ref',
  'source_version',
  'channel',
]) requireText(release, `${input}: \${{ inputs.${input} }}`, `forwarded ${input}`)
requireCount(wrapper, 'uses: ./.github/workflows/native-addon-build.yml', 1, 'local reusable-workflow invocation')

requireText(
  complete,
  "if: always() && needs.release.result != 'success'",
  'a failure callback even when the initial claim could not complete',
)
requireText(complete, 'AUTHORIZE_RESULT: ${{ needs.authorize.result }}', 'the claim result in the failure callback')
requireText(complete, "outcome = 'failed'", 'the terminal failure outcome')
requireText(complete, "failureClass = 'retryable'", 'the conservative retryable failure class')
requireText(complete, "-cne 'github-hosted'", 'the failure callback GitHub-hosted guard')
requireText(complete, '$env:GITHUB_WORKFLOW_SHA -cne $env:GITHUB_SHA', 'the failure callback workflow SHA guard')
requireText(complete, "$env:GITHUB_RUN_ATTEMPT -cne '1'", 'failure callback immutable run guard')
requireText(complete, "'publication-claim-failed'", 'the distinct failed-claim error code')
requireText(complete, 'errorCode = $errorCode', 'the bounded failure code')
requireText(complete, '/api/internal/addon-publication-requests/$env:PUBLICATION_REQUEST_ID/complete', 'the fixed completion endpoint')
requireText(
  complete,
  "'Idempotency-Key' = \"addon-publication:$env:PUBLICATION_REQUEST_ID:$env:PUBLICATION_ATTEMPT_ID:complete:failed\"",
  'failure-outcome-specific completion idempotency',
)
requireText(complete, '$retryable -and $completionAttempt -lt 5', 'bounded failure callback retries')
requireText(complete, '$httpResponse.Headers.RetryAfter', 'failure callback Retry-After support')
requireText(complete, '-TimeoutSec 20', 'a bounded failure callback timeout')
requireText(complete, "$response.state -cne 'failed'", 'the strict failed response transition')
requireText(complete, '$response.PSObject.Properties.Name', 'the exact failure response shape check')

for (const audience of [
  'mywallpaper-addon-publication-development',
  'mywallpaper-addon-publication-production',
]) requireText(wrapper, audience, `${audience} OIDC audience`)
requireCount(wrapper, '-MaximumRedirection 0', 4, 'redirect refusals in OIDC and MyWallpaper requests')

for (const input of [
  'publication_request_id',
  'publication_attempt_id',
  'source_repository_id',
  'source_repository',
  'source_commit_sha',
  'source_ref',
  'source_version',
]) requireText(reusable, `      ${input}:`, `reusable ${input} input`)
if (reusable.includes('secrets:') || reusable.includes('${{ secrets.')) {
  fail('The reusable admission path must not receive repository secrets.')
}
assertNoExpressionsInShellBodies(reusable, 'Reusable admission')
const build = section(reusable, '  build-untrusted:', '  verify-package:')
const verifier = section(reusable, '  verify-package:', '  attest-publish:')
const publisher = section(reusable, '  attest-publish:')
requireText(build, 'contents: read', 'build step-scoped public GitHub API token')
requireText(verifier, 'actions: read', 'verifier artifact-download permission')
if (verifier.includes('contents: read')) {
  fail('The fresh verifier does not need repository contents authority.')
}
for (const [value, label] of [[build, 'build'], [verifier, 'verifier']]) {
  if (value.includes('id-token: write') || value.includes('contents: write')) {
    fail(`The ${label} boundary must not receive OIDC or write permissions.`)
  }
}
requireText(build, 'replica: [1, 2]', 'two independent builds')
requireText(verifier, 'function Assert-ByteIdentical', 'fresh byte-identity verification')
requireCount(reusable, "github.event_name == 'workflow_dispatch' && github.repository == 'MyWallpapers/native-addon-toolchain' && inputs.publication_request_id != ''", 3, 'central dispatch job guards')
requireCount(reusable, "$env:DISPATCH_REF -cnotmatch '^refs/tags/central-publication-v", 3, 'immutable toolchain release runtime guards')
requireCount(reusable, '$env:DISPATCH_SHA -cne $env:WORKFLOW_SHA', 3, 'exact toolchain SHA guards')
requireCount(reusable, 'DISPATCH_REPOSITORY: ${{ github.repository }}', 3, 'dispatch repository env mappings')
requireCount(reusable, 'DISPATCH_REF: ${{ github.ref }}', 3, 'dispatch ref env mappings')
requireCount(reusable, 'DISPATCH_SHA: ${{ github.sha }}', 3, 'dispatch SHA env mappings')
requireCount(reusable, 'DISPATCH_WORKFLOW_REF: ${{ github.workflow_ref }}', 3, 'caller workflow-ref env mappings')
requireCount(reusable, 'DISPATCH_WORKFLOW_SHA: ${{ github.workflow_sha }}', 3, 'caller workflow-SHA env mappings')
requireCount(
  reusable,
  '$env:DISPATCH_WORKFLOW_REF -cne "$env:DISPATCH_REPOSITORY/.github/workflows/central-addon-publication.yml@$env:DISPATCH_REF"',
  3,
  'exact central caller-workflow guards',
)
requireCount(reusable, '$env:DISPATCH_WORKFLOW_SHA -cne $env:DISPATCH_SHA', 3, 'exact central caller-workflow SHA guards')
requireCount(reusable, 'https://github.com/MyWallpapers/native-addon-toolchain.git', 3, 'credential-free trusted toolchain fetches')

requireCount(
  reusable,
  'node toolchain/.github/scripts/assert-release-on-default-branch.mjs',
  2,
  'source tag/default-branch checks',
)
for (const fragment of [
  '--repository $env:SOURCE_REPOSITORY',
  '--repository-id $env:SOURCE_REPOSITORY_ID',
  '--commit-sha $env:SOURCE_COMMIT_SHA',
  '--release-ref $env:SOURCE_REF',
]) requireText(reusable, fragment, `source identity argument ${fragment}`)
requireText(reusable, '$bundleIndex.version -cne $env:EXPECTED_SOURCE_VERSION', 'verified manifest version binding')
requireText(reusable, "$expectedContract = 'central-admission-v1'", 'central evidence verification')
requireText(reusable, '$subject.publication.requestId -cne $env:PUBLICATION_REQUEST_ID', 'request-bound admission evidence')
requireText(reusable, '$subject.publication.attemptId -cne $env:PUBLICATION_ATTEMPT_ID', 'attempt-bound admission evidence')

for (const endpoint of [
  '/api/internal/addon-publication-requests/$env:PUBLICATION_REQUEST_ID/complete',
  '/api/internal/addon-publication-requests/$env:PUBLICATION_REQUEST_ID/ingestion',
  '/api/internal/native-admission/publication-requests/$env:PUBLICATION_REQUEST_ID/releases',
]) requireCount(reusable, endpoint, 2, `development and production ${endpoint}`)
requireText(publisher, "if: inputs.publication_request_id != ''", 'central-only successful verification callback')
requireText(publisher, "outcome = 'succeeded'", 'successful double-rebuild completion')
requireText(publisher, 'failureClass = $null', 'null success failure class')
requireText(
  publisher,
  "'Idempotency-Key' = \"addon-publication:$env:PUBLICATION_REQUEST_ID:$env:PUBLICATION_ATTEMPT_ID:complete:verified\"",
  'verified-outcome-specific completion idempotency',
)
requireText(publisher, "$response.state -cne 'verifying'", 'strict verifying response transition')
requireText(publisher, '$response.PSObject.Properties.Name', 'exact verifying response shape check')
requireText(publisher, '"publication-$env:PUBLICATION_ATTEMPT_ID"', 'attempt-namespaced transport tag')
requireText(publisher, '-PublicationRequestId $env:PUBLICATION_REQUEST_ID', 'request-bound immutable release')
requireText(publisher, '-PublicationAttemptId $env:PUBLICATION_ATTEMPT_ID', 'attempt-bound immutable release')
requireText(publisher, 'addon-publication:$env:PUBLICATION_REQUEST_ID:$env:PUBLICATION_ATTEMPT_ID:ingestion', 'attempt-bound ingestion idempotency')
requireText(publisher, 'addon-publication:$env:PUBLICATION_REQUEST_ID:$env:PUBLICATION_ATTEMPT_ID:evidence:$env:ADDON_RELEASE_ID', 'attempt-bound evidence idempotency')
requireText(publisher, 'publicationAttemptId = $env:PUBLICATION_ATTEMPT_ID', 'attempt-bound central payloads')
requireText(publisher, 'create-native-build-evidence.mjs', 'fresh NativeBuildEvidence transformation')
requireText(publisher, 'actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6', 'pinned GitHub/Sigstore attestation')
requireCount(publisher, '-MaximumRedirection 0', 7, 'redirect refusals in OIDC and MyWallpaper publisher requests')

for (const script of [preparer, finalizer]) {
  requireText(script, "$Repository -cne 'MyWallpapers/native-addon-toolchain'", 'toolchain-only central transport')
  requireText(script, '$TagName -cne "publication-$PublicationAttemptId"', 'attempt-namespaced transport tag')
  requireText(script, '$Repository -cne $SourceRepository', 'unchanged legacy source transport')
  requireText(script, 'Get-TagCommit $SourceRepository $SourceTagName', 'exact source tag verification')
  requireText(script, 'Get-TagCommit $Repository $TagName', 'exact transport tag verification')
  requireText(script, '<!-- mywallpaper-central-admission-v1 -->', 'request/source/toolchain release metadata')
}
requireText(finalizer, "make_latest = if ($CentralPublication) { 'false' } else { 'legacy' }", 'non-latest central transport')
requireText(finalizer, '[bool]$Release.immutable', 'immutable GitHub release enforcement')
requireText(preparer, 'function Ensure-CentralTransportTag', 'explicit central transport tag creation')
requireText(preparer, '"https://api.github.com/repos/$Repository/git/refs"', 'fixed GitHub transport ref endpoint')
requireText(preparer, 'Get-TagCommit $Repository $TagName', 'post-create transport tag verification')
requireText(nativeEvidence, "'workflow-ref'", 'explicit immutable workflow repository ref input')
requireText(nativeEvidence, 'CENTRAL_TOOLCHAIN_REF_PATTERN', 'central toolchain release ref validation')
requireText(nativeEvidence, 'repositoryRef: workflowRef', 'truthful workflow ref evidence')

process.stdout.write('central add-on publication workflow contract is intact\n')
