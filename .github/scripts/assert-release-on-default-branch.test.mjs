import assert from 'node:assert/strict'
import test from 'node:test'

import { assertReleaseOnDefaultBranch } from './assert-release-on-default-branch.mjs'

const repository = 'MyWallpapers/example-addon'
const repositoryId = '123456789'
const commitSha = '1'.repeat(40)
const defaultBranchHead = '2'.repeat(40)

function json(value, init = {}) {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: { 'content-type': 'application/json' },
    ...init,
  })
}

function api(overrides = {}) {
  const calls = []
  const fetchImpl = async (url, init) => {
    calls.push({ url: url.toString(), init })
    if (url.pathname.endsWith('/repos/MyWallpapers/example-addon')) {
      return json({
        full_name: repository,
        id: Number(repositoryId),
        private: false,
        archived: false,
        disabled: false,
        default_branch: 'main',
        ...overrides.repository,
      })
    }
    const defaultBranch = overrides.repository?.default_branch ?? 'main'
    if (url.pathname.endsWith(`/git/ref/heads/${defaultBranch}`)) {
      return json({
        ref: `refs/heads/${defaultBranch}`,
        object: { type: 'commit', sha: defaultBranchHead },
        ...overrides.reference,
      })
    }
    if (url.pathname.includes('/compare/')) {
      return json({
        status: 'ahead',
        ahead_by: 3,
        behind_by: 0,
        base_commit: { sha: commitSha },
        merge_base_commit: { sha: commitSha },
        ...overrides.comparison,
      })
    }
    throw new Error(`Unexpected request: ${url}`)
  }
  return { calls, fetchImpl }
}

async function verify(overrides = {}) {
  const mock = api(overrides)
  const result = await assertReleaseOnDefaultBranch({
    repository,
    repositoryId,
    commitSha,
    token: 'test-token',
    apiUrl: 'https://api.github.test',
    fetchImpl: mock.fetchImpl,
  })
  return { ...mock, result }
}

test('accepts a tagged commit that is an ancestor of the reviewed default branch', async () => {
  const { calls, result } = await verify()
  assert.deepEqual(result, { commitSha, defaultBranch: 'main', defaultBranchHead })
  assert.equal(calls.length, 3)
  assert.match(calls[2].url, new RegExp(`/compare/${commitSha}\\.\\.\\.${defaultBranchHead}`))
  for (const call of calls) {
    assert.equal(call.init.redirect, 'error')
    assert.equal(call.init.headers.authorization, 'Bearer test-token')
    assert.doesNotMatch(call.url, /test-token/u)
  }
})

test('accepts a tag at the current default branch head', async () => {
  const mock = api({
    reference: { object: { type: 'commit', sha: commitSha } },
    comparison: {
      status: 'identical',
      ahead_by: 0,
    },
  })
  const result = await assertReleaseOnDefaultBranch({
    repository,
    repositoryId,
    commitSha,
    token: 'test-token',
    apiUrl: 'https://api.github.test',
    fetchImpl: mock.fetchImpl,
  })
  assert.deepEqual(result, {
    commitSha,
    defaultBranch: 'main',
    defaultBranchHead: commitSha,
  })
})

test('accepts any valid public default branch name reported by GitHub', async () => {
  const {calls, result} = await verify({repository: {default_branch: 'trunk'}})
  assert.equal(result.defaultBranch, 'trunk')
  assert.match(calls[1].url, /\/git\/ref\/heads\/trunk$/u)
})

test('rejects a repository whose numeric identity differs from the event', async () => {
  await assert.rejects(
    verify({ repository: { id: 987654321 } }),
    /identity or visibility differs/u,
  )
})

test('rejects a diverged tag even if GitHub returns both commits', async () => {
  await assert.rejects(
    verify({
      comparison: {
        status: 'diverged',
        merge_base_commit: { sha: '3'.repeat(40) },
      },
    }),
    /not reachable from the reviewed default branch/u,
  )
})

test('rejects an inconsistent ahead count fail closed', async () => {
  await assert.rejects(
    verify({ comparison: { ahead_by: 0 } }),
    /not reachable from the reviewed default branch/u,
  )
})
