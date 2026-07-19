#!/usr/bin/env node

import { pathToFileURL } from 'node:url'

const GITHUB_API = 'https://api.github.com'
const GITHUB_API_VERSION = '2026-03-10'
const MAX_RESPONSE_BYTES = 16 * 1024 * 1024
const REQUEST_TIMEOUT_MS = 15_000
const REPOSITORY_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/u
const REPOSITORY_ID_PATTERN = /^[1-9][0-9]{0,15}$/u
const SHA_PATTERN = /^[0-9a-f]{40}$/u

function fail(message) {
  throw new Error(message)
}

function parseOptions(argv) {
  const options = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!key?.startsWith('--') || value === undefined || value.startsWith('--')) {
      fail('Expected --repository, --repository-id and --commit-sha arguments.')
    }
    if (options.has(key)) fail(`Duplicate option: ${key}`)
    options.set(key, value)
  }
  for (const key of options.keys()) {
    if (key !== '--repository' && key !== '--repository-id' && key !== '--commit-sha') {
      fail(`Unknown option: ${key}`)
    }
  }
  return options
}

async function readBoundedJson(response, label) {
  if (response.redirected || (response.status >= 300 && response.status < 400)) {
    fail(`${label} unexpectedly redirected.`)
  }
  if (!response.ok) fail(`${label} returned HTTP ${response.status}.`)

  const contentLength = response.headers.get('content-length')
  if (contentLength !== null) {
    const parsedLength = Number(contentLength)
    if (!Number.isSafeInteger(parsedLength) || parsedLength < 0 || parsedLength > MAX_RESPONSE_BYTES) {
      fail(`${label} response is too large.`)
    }
  }

  const chunks = []
  let size = 0
  if (response.body === null) fail(`${label} returned an empty response.`)
  for await (const chunk of response.body) {
    size += chunk.byteLength
    if (size > MAX_RESPONSE_BYTES) fail(`${label} response is too large.`)
    chunks.push(Buffer.from(chunk))
  }

  let decoded
  try {
    decoded = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size))
  } catch {
    fail(`${label} response is not valid UTF-8.`)
  }
  try {
    return JSON.parse(decoded)
  } catch {
    fail(`${label} response is not valid JSON.`)
  }
}

async function githubGet(path, { token, apiUrl, fetchImpl }, label) {
  const response = await fetchImpl(new URL(path, `${apiUrl}/`), {
    method: 'GET',
    redirect: 'error',
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${token}`,
      'user-agent': 'MyWallpaper-native-addon-admission-v1',
      'x-github-api-version': GITHUB_API_VERSION,
    },
  })
  return readBoundedJson(response, label)
}

export async function assertReleaseOnDefaultBranch({
  repository,
  repositoryId,
  commitSha,
  token,
  apiUrl = GITHUB_API,
  fetchImpl = globalThis.fetch,
}) {
  if (!REPOSITORY_PATTERN.test(repository ?? '')) fail('Repository identity is invalid.')
  if (!REPOSITORY_ID_PATTERN.test(repositoryId ?? '')) fail('Numeric repository identity is invalid.')
  if (!SHA_PATTERN.test(commitSha ?? '')) fail('Release commit SHA is invalid.')
  if (typeof token !== 'string' || token.length === 0) fail('GitHub token is required.')
  if (apiUrl !== GITHUB_API && fetchImpl === globalThis.fetch) {
    fail('The live admission check must use the canonical GitHub API origin.')
  }
  if (typeof fetchImpl !== 'function') fail('Fetch implementation is unavailable.')

  const [owner, name] = repository.split('/')
  const prefix = `repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}`
  const request = { token, apiUrl, fetchImpl }

  const metadata = await githubGet(prefix, request, 'GitHub repository lookup')
  if (
    metadata.full_name !== repository
    || !Number.isSafeInteger(metadata.id)
    || String(metadata.id) !== repositoryId
    || metadata.private !== false
    || metadata.archived !== false
    || metadata.disabled !== false
  ) {
    fail('GitHub repository identity or visibility differs from the release event.')
  }
  const defaultBranch = metadata.default_branch
  if (
    typeof defaultBranch !== 'string'
    || defaultBranch.length === 0
    || defaultBranch.length > 255
    || defaultBranch !== defaultBranch.trim()
    || /[\u0000-\u0020~^:?*[\\]/u.test(defaultBranch)
    || defaultBranch.includes('..')
    || defaultBranch.startsWith('-')
    || defaultBranch.endsWith('.')
    || defaultBranch.endsWith('/')
    || defaultBranch.includes('//')
  ) {
    fail('GitHub returned an invalid default branch identity.')
  }

  const defaultReference = await githubGet(
    `${prefix}/git/ref/heads/${encodeURIComponent(defaultBranch)}`,
    request,
    'GitHub default branch ref lookup',
  )
  const defaultBranchHead = defaultReference?.object?.sha
  if (
    defaultReference?.ref !== `refs/heads/${defaultBranch}`
    || defaultReference?.object?.type !== 'commit'
    || !SHA_PATTERN.test(defaultBranchHead ?? '')
  ) {
    fail('GitHub default branch ref is not a canonical commit reference.')
  }

  const comparison = await githubGet(
    `${prefix}/compare/${commitSha}...${defaultBranchHead}?page=1&per_page=1`,
    request,
    'GitHub default branch ancestry comparison',
  )
  if (
    !['ahead', 'identical'].includes(comparison.status)
    || comparison.base_commit?.sha !== commitSha
    || comparison.merge_base_commit?.sha !== commitSha
    || comparison.behind_by !== 0
    || !Number.isSafeInteger(comparison.ahead_by)
    || comparison.ahead_by < 0
    || (comparison.status === 'identical'
      && (comparison.ahead_by !== 0 || defaultBranchHead !== commitSha))
    || (comparison.status === 'ahead'
      && (comparison.ahead_by === 0 || defaultBranchHead === commitSha))
  ) {
    fail('The tagged release commit is not reachable from the reviewed default branch.')
  }

  return { commitSha, defaultBranch, defaultBranchHead }
}

async function main() {
  const options = parseOptions(process.argv.slice(2))
  const repository = options.get('--repository')
  const repositoryId = options.get('--repository-id')
  const commitSha = options.get('--commit-sha')
  if (
    options.size !== 3
    || repository === undefined
    || repositoryId === undefined
    || commitSha === undefined
  ) {
    fail('Expected --repository, --repository-id and --commit-sha exactly once.')
  }
  const result = await assertReleaseOnDefaultBranch({
    repository,
    repositoryId,
    commitSha,
    token: process.env.MYWALLPAPER_GITHUB_TOKEN,
  })
  process.stdout.write(
    `Release commit ${result.commitSha} is reachable from reviewed default branch ${result.defaultBranch} at ${result.defaultBranchHead}.\n`,
  )
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : null
if (invokedPath === import.meta.url) {
  main().catch((error) => {
    process.stderr.write(`release-on-default-branch verification failed: ${error.message}\n`)
    process.exitCode = 1
  })
}
