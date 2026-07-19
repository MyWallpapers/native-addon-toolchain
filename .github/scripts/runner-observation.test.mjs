import assert from 'node:assert/strict'
import test from 'node:test'
import {
  createRunnerObservationPredicate,
  runnerObservationDigest,
  validateReplicaRunnerObservation,
  validateRunnerObservationPredicate,
} from './runner-observation.mjs'

const workflowSha = 'a'.repeat(40)

function observation(replica, overrides = {}) {
  const value = {
    schemaVersion: 1,
    contract: 'github-hosted-windows-build-observation-v1',
    replica,
    run: { id: '123456', attempt: '2' },
    workflowSha,
    runner: {
      environment: 'github-hosted',
      label: 'windows-2025',
      operatingSystem: 'Windows',
      architecture: 'X64',
      imageOs: 'win25',
      imageVersion: '20260719.1',
    },
    tools: {
      node: { version: 'v22.22.3' },
      powershell: { version: '7.5.2' },
      rust: {
        rustc: {
          sha256: `sha256:${'1'.repeat(64)}`,
          version: 'rustc 1.90.0 (fixture)\nhost: x86_64-pc-windows-msvc\nrelease: 1.90.0',
        },
        cargo: {
          sha256: `sha256:${'2'.repeat(64)}`,
          version: 'cargo 1.90.0 (fixture)\nrelease: 1.90.0',
        },
      },
      msvc: {
        toolsetVersion: '14.44.35207',
        linker: {
          sha256: `sha256:${'3'.repeat(64)}`,
          version: '14.44.35207',
          fileVersion: '14.44.35207.1',
        },
      },
      windowsSdk: { availableVersions: ['10.0.22621.0', '10.0.26100.0'] },
      windhawk: {
        used: true,
        windhawkCommit: '4'.repeat(40),
        archiveSha256: `sha256:${'5'.repeat(64)}`,
        clang: { sha256: `sha256:${'6'.repeat(64)}`, version: 'clang version 20.1.8' },
        linker: { sha256: `sha256:${'7'.repeat(64)}`, version: 'LLD 20.1.8' },
      },
    },
  }
  return { ...value, ...overrides }
}

function predicate(observations = [observation(1), observation(2)]) {
  return createRunnerObservationPredicate({
    observations,
    repositoryId: '987654',
    repository: 'MyWallpapers/addon-fixture',
    commitSha: 'b'.repeat(40),
    releaseRef: 'refs/tags/v1.2.3',
    workflowSha,
    runId: '123456',
    runAttempt: '2',
    artifactDigest: `sha256:${'8'.repeat(64)}`,
    distributionDigest: `sha256:${'9'.repeat(64)}`,
  })
}

test('runner observations retain mutable image and useful tool identities', () => {
  const value = validateReplicaRunnerObservation(observation(1))
  assert.equal(value.runner.imageOs, 'win25')
  assert.equal(value.runner.imageVersion, '20260719.1')
  assert.match(value.tools.rust.rustc.version, /host: x86_64-pc-windows-msvc/u)
  assert.equal(value.tools.msvc.linker.version, '14.44.35207')
  assert.deepEqual(value.tools.windowsSdk.availableVersions, ['10.0.22621.0', '10.0.26100.0'])
  assert.equal(value.tools.windhawk.used, true)
})

test('predicate binds both replicas to one exact run and bundle', () => {
  const value = predicate()
  assert.deepEqual(validateRunnerObservationPredicate(value), value)
  assert.match(runnerObservationDigest(value), /^sha256:[0-9a-f]{64}$/u)

  assert.throws(
    () => predicate([observation(1), observation(2, { run: { id: '123456', attempt: '3' } })]),
    /disagrees with the verified workflow attempt/u,
  )
})

test('contract fails closed on incomplete or contradictory observations', () => {
  const missingImage = observation(1)
  delete missingImage.runner.imageVersion
  assert.throws(() => validateReplicaRunnerObservation(missingImage), /fields do not match/u)

  const unsortedSdk = observation(1)
  unsortedSdk.tools.windowsSdk.availableVersions.reverse()
  assert.throws(() => validateReplicaRunnerObservation(unsortedSdk), /ordinally sorted/u)

  const unusedWithCompiler = observation(1)
  unusedWithCompiler.tools.windhawk.used = false
  assert.throws(() => validateReplicaRunnerObservation(unusedWithCompiler), /unused Windhawk executable/u)
})

test('an unused pinned Windhawk toolchain is represented without fake executable observations', () => {
  const value = observation(1)
  value.tools.windhawk = {
    used: false,
    windhawkCommit: '4'.repeat(40),
    archiveSha256: `sha256:${'5'.repeat(64)}`,
    clang: null,
    linker: null,
  }
  assert.equal(validateReplicaRunnerObservation(value).tools.windhawk.used, false)
})
