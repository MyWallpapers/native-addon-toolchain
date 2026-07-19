import { createHash } from 'node:crypto'

const COMMIT_PATTERN = /^[0-9a-f]{40}$/u
const NODE_VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+$/u

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

export function canonicalJsonBytes(value) {
  return Buffer.from(JSON.stringify(canonicalize(value)), 'utf8')
}

export function canonicalJsonDigest(value) {
  return `sha256:${createHash('sha256').update(canonicalJsonBytes(value)).digest('hex')}`
}

export function createReviewedAdmissionEnvironment({ nodeVersion, canonicalCli, workflowSha }) {
  if (typeof nodeVersion !== 'string' || !NODE_VERSION_PATTERN.test(nodeVersion)) {
    fail('Pinned Node.js version is invalid.')
  }
  if (typeof workflowSha !== 'string' || !COMMIT_PATTERN.test(workflowSha)) {
    fail('Workflow SHA is invalid.')
  }
  plainRecord(canonicalCli, 'Canonical CLI lock')

  return {
    schemaVersion: 1,
    contract: 'admission-v1',
    kind: 'reviewed-build-environment',
    runner: {
      environment: 'github-hosted',
      label: 'windows-2025',
      operatingSystem: 'Windows',
      architecture: 'X64',
    },
    nodeVersion,
    canonicalCli,
    workflow: {
      repository: 'MyWallpapers/native-addon-toolchain',
      path: '.github/workflows/native-addon-build.yml',
      workflowSha,
    },
  }
}
