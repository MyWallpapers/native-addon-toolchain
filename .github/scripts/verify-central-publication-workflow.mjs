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

const validation = section(wrapper, '  validate:', '  release:')
const release = section(wrapper, '  release:')
requireText(validation, 'permissions: {}', 'credential-free dispatch validation')
requireText(validation, "-cne 'github-hosted'", 'the GitHub-hosted runner guard')
requireText(validation, "$env:GITHUB_REPOSITORY -cne 'MyWallpapers/native-addon-toolchain'", 'the exact toolchain repository guard')
requireText(validation, "$env:GITHUB_REF -cnotmatch '^refs/tags/central-publication-v", 'the immutable toolchain release ref guard')
requireText(validation, '$env:GITHUB_WORKFLOW_SHA -cne $env:GITHUB_SHA', 'the exact wrapper workflow SHA guard')
requireText(validation, "$env:GITHUB_RUN_ATTEMPT -cne '1'", 'one immutable GitHub run per attempt')
requireText(validation, '$env:SOURCE_REF -cne "refs/tags/v$env:SOURCE_VERSION"', 'frozen source tag/version binding')
requireText(release, 'needs: validate', 'identity validation before untrusted builds')
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
requireText(
  verifier,
  "$sourceTag = $env:CALLER_REF.Substring('refs/tags/'.Length)",
  'frozen source-tag extraction',
)
requireText(
  verifier,
  '$sourceTag -cne "v$env:EXPECTED_SOURCE_VERSION"',
  'source-tag and manifest-version binding',
)
requireText(verifier, "$env:GITHUB_REF_TYPE = 'tag'", 'canonical CLI tag context')
requireText(verifier, '$env:GITHUB_REF_NAME = $sourceTag', 'canonical CLI source-tag context')
if (verifier.indexOf('$env:GITHUB_REF_NAME = $sourceTag')
    >= verifier.indexOf('node "$env:RUNNER_TEMP/mywallpaper-cli/cli/dist/bin.js" check')) {
  fail('The canonical CLI must receive the frozen source tag before validation.')
}
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

requireText(publisher, '"publication-$env:PUBLICATION_ATTEMPT_ID"', 'attempt-namespaced transport tag')
requireText(publisher, '-PublicationRequestId $env:PUBLICATION_REQUEST_ID', 'request-bound immutable release')
requireText(publisher, '-PublicationAttemptId $env:PUBLICATION_ATTEMPT_ID', 'attempt-bound immutable release')
requireText(publisher, 'write-publication-result.ps1', 'the broker result producer')
requireText(publisher, 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a', 'the pinned result upload')
for (const workflow of [wrapper, reusable]) {
  for (const obsolete of ['/api/internal/', 'Invoke-MyWallpaperIdempotentJsonPost', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN']) {
    if (workflow.includes(obsolete)) fail(`Publication must use broker collection, found ${obsolete}`)
  }
}

for (const workflow of [wrapper, reusable]) {
  if (/\$env:[A-Za-z_][A-Za-z0-9_]*:/u.test(workflow)) {
    fail('PowerShell variables immediately followed by a colon must use an explicit subexpression.')
  }
}
requireText(publisher, 'actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6', 'pinned GitHub/Sigstore attestation')

for (const script of [preparer, finalizer]) {
  requireText(script, "$Repository -cne 'MyWallpapers/native-addon-toolchain'", 'toolchain-only central transport')
  requireText(script, '$TagName -cne "publication-$PublicationAttemptId"', 'attempt-namespaced transport tag')
  requireText(script, 'Get-TagCommit $SourceRepository $SourceTagName', 'exact source tag verification')
  requireText(script, 'Get-TagCommit $Repository $TagName', 'exact transport tag verification')
  requireText(script, '<!-- mywallpaper-central-admission-v1 -->', 'request/source/toolchain release metadata')
}
requireText(finalizer, "make_latest = 'false'", 'non-latest central transport')
requireText(finalizer, '[bool]$Release.immutable', 'immutable GitHub release enforcement')
requireText(preparer, 'function Ensure-CentralTransportTag', 'explicit central transport tag creation')
requireText(preparer, '"https://api.github.com/repos/$Repository/git/refs"', 'fixed GitHub transport ref endpoint')
requireText(preparer, 'Get-TagCommit $Repository $TagName', 'post-create transport tag verification')
requireText(nativeEvidence, "'workflow-ref'", 'explicit immutable workflow repository ref input')
requireText(nativeEvidence, 'CENTRAL_TOOLCHAIN_REF_PATTERN', 'central toolchain release ref validation')
requireText(nativeEvidence, 'repositoryRef: workflowRef', 'truthful workflow ref evidence')

process.stdout.write('central add-on publication workflow contract is intact\n')

for (const fragment of [
  "github.event_name == 'push'", 'MYWALLPAPER_PUBLICATION_MODE',
  'PUBLICATION_MODE', 'refs/heads/admission-v1',
  '/api/internal/addon-release-ingestion', 'mywallpaper-addon-release-development',
]) {
  if (reusable.includes(fragment)) fail(`Obsolete caller publication remains: ${fragment}`)
}
for (const input of ['channel', 'publication_request_id', 'publication_attempt_id',
  'source_repository_id', 'source_repository', 'source_commit_sha', 'source_ref', 'source_version']) {
  const block = reusable.split(`      ${input}:`)[1]?.split(/\n      [a-z_]+:/u)[0]
  if (!block?.includes('required: true') || block.includes('required: false')) {
    fail(`Central workflow input must be mandatory: ${input}`)
  }
}
