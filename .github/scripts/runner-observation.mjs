import { createHash } from 'node:crypto'

const SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/u
const COMMIT_PATTERN = /^[0-9a-f]{40}$/u
const POSITIVE_DECIMAL_PATTERN = /^[1-9][0-9]*$/u
const REPOSITORY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/u
const WINDOWS_SDK_VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/u

function fail(message) {
  throw new Error(message)
}

function plainRecord(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || (Object.getPrototypeOf(value) !== Object.prototype
      && Object.getPrototypeOf(value) !== null)) {
    fail(`${label} must be a plain JSON object.`)
  }
  return value
}

function exactKeys(value, expected, label) {
  const actual = Object.keys(plainRecord(value, label)).sort()
  const wanted = [...expected].sort()
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail(`${label} fields do not match the versioned contract.`)
  }
  return value
}

function cleanLine(value, label, pattern = null) {
  if (typeof value !== 'string' || value.length === 0 || value !== value.trim()
    || /[\u0000-\u001f\u007f]/u.test(value) || (pattern && !pattern.test(value))) {
    fail(`${label} is invalid.`)
  }
  return value
}

function cleanText(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value !== value.trim()
    || value.includes('\r') || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)) {
    fail(`${label} is invalid.`)
  }
  return value
}

function executableObservation(value, label) {
  exactKeys(value, ['sha256', 'version'], label)
  cleanLine(value.sha256, `${label} digest`, SHA256_PATTERN)
  cleanText(value.version, `${label} version`)
  return value
}

function validateRunner(value, label) {
  exactKeys(value, [
    'environment', 'label', 'operatingSystem', 'architecture', 'imageOs', 'imageVersion',
  ], label)
  if (value.environment !== 'github-hosted' || value.label !== 'windows-2025'
    || value.operatingSystem !== 'Windows' || value.architecture !== 'X64') {
    fail(`${label} is outside the reviewed GitHub-hosted Windows contract.`)
  }
  cleanLine(value.imageOs, `${label} ImageOS`)
  cleanLine(value.imageVersion, `${label} ImageVersion`)
  return value
}

function validateTools(value, label) {
  exactKeys(value, ['node', 'powershell', 'rust', 'msvc', 'windowsSdk', 'windhawk'], label)

  exactKeys(value.node, ['version'], `${label} Node.js`)
  cleanLine(value.node.version, `${label} Node.js version`, /^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$/u)
  exactKeys(value.powershell, ['version'], `${label} PowerShell`)
  cleanLine(value.powershell.version, `${label} PowerShell version`, /^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[-+][A-Za-z0-9.-]+)?$/u)

  exactKeys(value.rust, ['rustc', 'cargo'], `${label} Rust`)
  executableObservation(value.rust.rustc, `${label} rustc`)
  executableObservation(value.rust.cargo, `${label} cargo`)
  if (!/^rustc [^\n]+(?:\n|$)/u.test(value.rust.rustc.version)
    || !/(?:^|\n)host: [^\n]+(?:\n|$)/u.test(value.rust.rustc.version)
    || !/(?:^|\n)release: [^\n]+(?:\n|$)/u.test(value.rust.rustc.version)
    || !/^cargo [^\n]+(?:\n|$)/u.test(value.rust.cargo.version)) {
    fail(`${label} Rust observations are incomplete.`)
  }

  exactKeys(value.msvc, ['toolsetVersion', 'linker'], `${label} MSVC`)
  cleanLine(value.msvc.toolsetVersion, `${label} MSVC toolset version`, /^[0-9]+(?:\.[0-9]+){1,3}$/u)
  exactKeys(value.msvc.linker, ['sha256', 'version', 'fileVersion'], `${label} MSVC linker`)
  cleanLine(value.msvc.linker.sha256, `${label} MSVC linker digest`, SHA256_PATTERN)
  cleanLine(value.msvc.linker.version, `${label} MSVC linker version`, /^[0-9]+(?:\.[0-9]+){1,3}$/u)
  cleanLine(value.msvc.linker.fileVersion, `${label} MSVC linker file version`)

  exactKeys(value.windowsSdk, ['availableVersions'], `${label} Windows SDK`)
  if (!Array.isArray(value.windowsSdk.availableVersions)
    || value.windowsSdk.availableVersions.length === 0) {
    fail(`${label} Windows SDK inventory is empty.`)
  }
  const sdkVersions = value.windowsSdk.availableVersions.map((version) => (
    cleanLine(version, `${label} Windows SDK version`, WINDOWS_SDK_VERSION_PATTERN)
  ))
  const sortedSdkVersions = [...sdkVersions].sort((left, right) => left < right ? -1 : left > right ? 1 : 0)
  if (new Set(sdkVersions).size !== sdkVersions.length
    || sdkVersions.some((version, index) => version !== sortedSdkVersions[index])) {
    fail(`${label} Windows SDK versions must be unique and ordinally sorted.`)
  }

  exactKeys(
    value.windhawk,
    ['used', 'windhawkCommit', 'archiveSha256', 'clang', 'linker'],
    `${label} Windhawk toolchain`,
  )
  if (typeof value.windhawk.used !== 'boolean') fail(`${label} Windhawk usage flag is invalid.`)
  cleanLine(value.windhawk.windhawkCommit, `${label} Windhawk commit`, COMMIT_PATTERN)
  cleanLine(value.windhawk.archiveSha256, `${label} Windhawk archive digest`, SHA256_PATTERN)
  if (value.windhawk.used) {
    executableObservation(value.windhawk.clang, `${label} Windhawk clang`)
    executableObservation(value.windhawk.linker, `${label} Windhawk linker`)
  } else if (value.windhawk.clang !== null || value.windhawk.linker !== null) {
    fail(`${label} records an unused Windhawk executable.`)
  }
  return value
}

export function validateReplicaRunnerObservation(value) {
  exactKeys(value, [
    'schemaVersion', 'contract', 'replica', 'run', 'workflowSha', 'runner', 'tools',
  ], 'replica runner observation')
  if (value.schemaVersion !== 1
    || value.contract !== 'github-hosted-windows-build-observation-v1'
    || ![1, 2].includes(value.replica)) {
    fail('Replica runner observation identity is invalid.')
  }
  exactKeys(value.run, ['id', 'attempt'], 'replica workflow attempt')
  cleanLine(value.run.id, 'replica workflow run ID', POSITIVE_DECIMAL_PATTERN)
  cleanLine(value.run.attempt, 'replica workflow run attempt', POSITIVE_DECIMAL_PATTERN)
  cleanLine(value.workflowSha, 'replica workflow SHA', COMMIT_PATTERN)
  validateRunner(value.runner, 'replica runner')
  validateTools(value.tools, 'replica tools')
  return value
}

function canonicalize(value, path = '$') {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail(`${path} contains a non-finite number.`)
    return value
  }
  if (Array.isArray(value)) return value.map((entry, index) => canonicalize(entry, `${path}[${index}]`))
  const output = {}
  for (const key of Object.keys(plainRecord(value, path)).sort()) {
    output[key] = canonicalize(value[key], `${path}.${key}`)
  }
  return output
}

export function canonicalRunnerObservationBytes(value) {
  return Buffer.from(JSON.stringify(canonicalize(value)), 'utf8')
}

export function runnerObservationDigest(value) {
  return `sha256:${createHash('sha256').update(canonicalRunnerObservationBytes(value)).digest('hex')}`
}

export function createRunnerObservationPredicate({
  observations,
  repositoryId,
  repository,
  commitSha,
  releaseRef,
  workflowSha,
  runId,
  runAttempt,
  artifactDigest,
  distributionDigest,
}) {
  if (!Array.isArray(observations) || observations.length !== 2) {
    fail('Exactly two build-runner observations are required.')
  }
  const replicas = observations.map(validateReplicaRunnerObservation)
    .sort((left, right) => left.replica - right.replica)
  if (replicas[0].replica !== 1 || replicas[1].replica !== 2) {
    fail('Build-runner replica identities are invalid.')
  }
  cleanLine(repositoryId, 'predicate repository ID', POSITIVE_DECIMAL_PATTERN)
  cleanLine(repository, 'predicate repository', REPOSITORY_PATTERN)
  cleanLine(commitSha, 'predicate commit SHA', COMMIT_PATTERN)
  cleanLine(releaseRef, 'predicate release ref', /^refs\/tags\/[^\u0000\r\n]+$/u)
  cleanLine(workflowSha, 'predicate workflow SHA', COMMIT_PATTERN)
  cleanLine(runId, 'predicate workflow run ID', POSITIVE_DECIMAL_PATTERN)
  cleanLine(runAttempt, 'predicate workflow run attempt', POSITIVE_DECIMAL_PATTERN)
  cleanLine(artifactDigest, 'predicate artifact digest', SHA256_PATTERN)
  cleanLine(distributionDigest, 'predicate distribution digest', SHA256_PATTERN)
  for (const observation of replicas) {
    if (observation.workflowSha !== workflowSha || observation.run.id !== runId
      || observation.run.attempt !== runAttempt) {
      fail('Build-runner observation disagrees with the verified workflow attempt.')
    }
  }
  return {
    schemaVersion: 1,
    contract: 'github-hosted-runner-observation-v1',
    source: { repositoryId, repository, commitSha, ref: releaseRef },
    workflow: {
      repository: 'MyWallpapers/native-addon-toolchain',
      path: '.github/workflows/native-addon-build.yml',
      workflowSha,
      runId,
      runAttempt,
    },
    artifact: { name: 'mywallpaper-addon-bundle.zip', sha256: artifactDigest, distributionDigest },
    replicas,
  }
}

export function validateRunnerObservationPredicate(value) {
  exactKeys(value, ['schemaVersion', 'contract', 'source', 'workflow', 'artifact', 'replicas'], 'runner observation predicate')
  if (value.schemaVersion !== 1 || value.contract !== 'github-hosted-runner-observation-v1') {
    fail('Runner observation predicate identity is invalid.')
  }
  exactKeys(value.source, ['repositoryId', 'repository', 'commitSha', 'ref'], 'runner observation source')
  exactKeys(
    value.workflow,
    ['repository', 'path', 'workflowSha', 'runId', 'runAttempt'],
    'runner observation workflow',
  )
  exactKeys(value.artifact, ['name', 'sha256', 'distributionDigest'], 'runner observation artifact')
  if (value.workflow.repository !== 'MyWallpapers/native-addon-toolchain'
    || value.workflow.path !== '.github/workflows/native-addon-build.yml'
    || value.artifact.name !== 'mywallpaper-addon-bundle.zip') {
    fail('Runner observation predicate is outside the admission-v1 identity.')
  }
  return createRunnerObservationPredicate({
    observations: value.replicas,
    repositoryId: value.source.repositoryId,
    repository: value.source.repository,
    commitSha: value.source.commitSha,
    releaseRef: value.source.ref,
    workflowSha: value.workflow.workflowSha,
    runId: value.workflow.runId,
    runAttempt: value.workflow.runAttempt,
    artifactDigest: value.artifact.sha256,
    distributionDigest: value.artifact.distributionDigest,
  })
}
