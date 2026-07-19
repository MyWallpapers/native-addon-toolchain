#!/usr/bin/env node

import { readFile } from 'node:fs/promises'

function fail(message) {
  throw new Error(message)
}

function requireText(text, fragment, label) {
  if (!text.includes(fragment)) fail(`Control-plane workflows are missing ${label}.`)
}

function section(text, start, end) {
  const from = text.indexOf(start)
  if (from < 0) fail(`Control-plane workflows are missing ${start}.`)
  const to = end ? text.indexOf(end, from + start.length) : text.length
  if (end && to < 0) fail(`Control-plane workflows are missing ${end}.`)
  return text.slice(from, to)
}

const qualityPath = process.argv[2] ?? '.github/workflows/quality.yml'
const codeqlPath = process.argv[3] ?? '.github/workflows/codeql.yml'
// GitHub's Windows runners check repositories out with CRLF line endings. Keep
// the workflow contract platform-independent instead of making its assertions
// depend on the runner's checkout configuration.
const quality = (await readFile(qualityPath, 'utf8')).replaceAll('\r\n', '\n')
const codeql = (await readFile(codeqlPath, 'utf8')).replaceAll('\r\n', '\n')

requireText(quality, '  pull_request:\n', 'pull-request quality execution')
requireText(quality, '  push:\n    branches: [main]', 'main-push quality execution')
const promotion = section(quality, '  promotion-eligible:')
requireText(promotion, "name: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'promotion-eligible' || 'promotion-not-applicable' }}", 'a context name absent from pull-request commits')
requireText(promotion, 'needs: smoke', 'the successful smoke dependency')
requireText(promotion, "if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.smoke.result == 'success'", 'the exact reviewed-main success guard')
requireText(promotion, 'runs-on: ubuntu-24.04', 'the reviewed promotion runner')
requireText(promotion, 'timeout-minutes: 1', 'the bounded promotion job')
requireText(promotion, 'permissions: {}', 'the credential-free promotion job')
requireText(promotion, 'test "$EVENT_NAME" = \'push\'', 'the runtime event assertion')
requireText(promotion, 'test "$EVENT_REF" = \'refs/heads/main\'', 'the runtime ref assertion')
requireText(promotion, '[[ "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]', 'the runtime SHA assertion')
if (/^\s*uses:/mu.test(promotion) || promotion.includes('actions/checkout')) {
  fail('Promotion eligibility must not checkout code or invoke another action.')
}
if ((quality.match(/^  promotion-eligible:/gmu) ?? []).length !== 1) {
  fail('Quality must expose exactly one promotion-eligible job.')
}

requireText(codeql, 'name: CodeQL', 'the CodeQL workflow')
requireText(codeql, '  pull_request:\n    branches: [main]', 'CodeQL pull-request coverage')
requireText(codeql, '  push:\n    branches: [main]', 'CodeQL main-push coverage')
requireText(codeql, "cron: '17 4 * * 3'", 'weekly CodeQL query refresh')
requireText(codeql, 'security-events: write', 'CodeQL result upload permission')
requireText(codeql, 'languages: actions,javascript-typescript', 'Actions and JavaScript analysis')
requireText(codeql, 'queries: security-extended', 'extended security queries')
if ((codeql.match(/github\/codeql-action\/(?:init|analyze)@7188fc363630916deb702c7fdcf4e481b751f97a/gu) ?? []).length !== 2) {
  fail('CodeQL init and analyze must use the reviewed v4.37.1 commit.')
}
for (const match of codeql.matchAll(/^\s*uses:\s*([^\s#]+).*$/gmu)) {
  const target = match[1]
  const revision = target.split('@')[1]
  if (!/^[0-9a-f]{40}$/u.test(revision ?? '')) {
    fail(`CodeQL action is not pinned by full SHA: ${target}`)
  }
}
if (codeql.includes('autobuild') || codeql.includes('setup-node')) {
  fail('CodeQL must analyze the interpreted control-plane sources without a redundant build.')
}

process.stdout.write('toolchain promotion and CodeQL workflow contracts are intact\n')
