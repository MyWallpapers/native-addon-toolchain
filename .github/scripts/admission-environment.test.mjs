import assert from 'node:assert/strict'
import test from 'node:test'
import {
  canonicalJsonDigest,
  createReviewedAdmissionEnvironment,
} from './admission-environment.mjs'

const canonicalCli = {
  schemaVersion: 1,
  sourceRepository: 'MyWallpapers/MyWallpaper',
  sourceCommit: 'a'.repeat(40),
  archive: 'mywallpaper-cli.zip',
  size: 42,
  sha256: `sha256:${'b'.repeat(64)}`,
}

test('reviewed environment contains only toolchain-controlled inputs', () => {
  const environment = createReviewedAdmissionEnvironment({
    nodeVersion: '22.22.3',
    canonicalCli,
    workflowSha: 'c'.repeat(40),
  })

  assert.deepEqual(Object.keys(environment).sort(), [
    'canonicalCli',
    'contract',
    'kind',
    'nodeVersion',
    'runner',
    'schemaVersion',
    'workflow',
  ])
  assert.equal(environment.kind, 'reviewed-build-environment')
  assert.equal(JSON.stringify(environment).includes('authorBuildRecipe'), false)
  assert.match(canonicalJsonDigest(environment), /^sha256:[0-9a-f]{64}$/u)
})

test('environment digest changes only when reviewed toolchain inputs change', () => {
  const first = createReviewedAdmissionEnvironment({
    nodeVersion: '22.22.3',
    canonicalCli,
    workflowSha: 'c'.repeat(40),
  })
  const same = createReviewedAdmissionEnvironment({
    nodeVersion: '22.22.3',
    canonicalCli: { ...canonicalCli },
    workflowSha: 'c'.repeat(40),
  })
  const next = createReviewedAdmissionEnvironment({
    nodeVersion: '22.22.3',
    canonicalCli,
    workflowSha: 'd'.repeat(40),
  })

  assert.equal(canonicalJsonDigest(first), canonicalJsonDigest(same))
  assert.notEqual(canonicalJsonDigest(first), canonicalJsonDigest(next))
})
