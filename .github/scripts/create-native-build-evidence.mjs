#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { writeFile } from 'node:fs/promises'
import { readBoundedJson } from './safe-files.mjs'

const SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/u
const COMMIT_PATTERN = /^[0-9a-f]{40}$/u
const RELEASE_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const REPOSITORY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/u
const REQUIRED_OPTIONS = [
  'subject', 'addon-release-id', 'license-spdx', 'native-manifest-digest',
  'materials-digest', 'materials-size', 'workflow-sha', 'output',
]

function fail(message) {
  throw new Error(message)
}

function argumentsFromCommandLine(argv) {
  if (argv.length !== REQUIRED_OPTIONS.length * 2) fail('Native build evidence options are incomplete.')
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index]?.replace(/^--/u, '')
    const value = argv[index + 1]
    if (!REQUIRED_OPTIONS.includes(name) || !value || values.has(name)) {
      fail(`Invalid native build evidence option: ${argv[index] ?? ''}`)
    }
    values.set(name, value)
  }
  return Object.fromEntries(values)
}

function plainRecord(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)) {
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

function canonicalBytes(value) {
  return Buffer.from(JSON.stringify(canonicalize(value)), 'utf8')
}

function digest(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`
}

function requiredString(value, label, pattern, maximum = 1024) {
  if (typeof value !== 'string' || value.length === 0 || value.length > maximum
    || value.includes('\0') || (pattern && !pattern.test(value))) fail(`${label} is invalid.`)
  return value
}

async function readJson(path, label) {
  return readBoundedJson(path, { label, maximumBytes: 1024 * 1024 })
}

async function main() {
  const options = argumentsFromCommandLine(process.argv.slice(2))
  const releaseId = requiredString(options['addon-release-id'], 'add-on release ID', RELEASE_ID_PATTERN, 36)
  const licenseSpdx = requiredString(options['license-spdx'], 'SPDX license', /^[A-Za-z0-9.+-]{1,64}$/u, 64)
  const nativeManifestDigest = requiredString(
    options['native-manifest-digest'],
    'native manifest digest',
    SHA256_PATTERN,
    71,
  )
  const materialsDigest = requiredString(
    options['materials-digest'],
    'admission materials digest',
    SHA256_PATTERN,
    71,
  )
  const materialsSize = Number(options['materials-size'])
  if (!Number.isSafeInteger(materialsSize) || materialsSize <= 0) {
    fail('Admission materials size is invalid.')
  }
  const workflowSha = requiredString(options['workflow-sha'], 'workflow SHA', COMMIT_PATTERN, 40)
  const subject = await readJson(options.subject, 'admission-v1 subject')
  exactKeys(subject, [
    'schemaVersion', 'contract', 'generatedAt', 'source', 'workflow', 'release',
    'artifact', 'build', 'evidence',
  ], 'admission-v1 subject')
  exactKeys(subject.source, [
    'repositoryId', 'repository', 'commitSha', 'ref', 'sourceDigest', 'lockfilesDigest',
  ], 'admission-v1 source')
  exactKeys(subject.workflow, [
    'repository', 'path', 'requestedRef', 'workflowSha',
  ], 'admission-v1 workflow')
  exactKeys(subject.release, [
    'version', 'distributionDigest', 'manifestDigest', 'capabilitySnapshot',
  ], 'admission-v1 release')
  exactKeys(subject.artifact, ['name', 'sizeBytes', 'sha256'], 'admission-v1 artifact')
  exactKeys(subject.build, ['environmentDigest', 'reproducible', 'replicas'], 'admission-v1 build')
  exactKeys(subject.evidence, [
    'authorInventory', 'bundleIndexDigest', 'payloadInventoryDigest',
    'sbomDigest', 'provenanceDigest',
  ], 'admission-v1 evidence')
  exactKeys(subject.evidence.authorInventory, ['fileCount', 'totalBytes', 'digest'], 'author inventory')
  const workflowPrefix = 'MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml@'
  const acceptedWorkflowRef = `${workflowPrefix}${workflowSha}`
  if (subject.schemaVersion !== 1 || subject.contract !== 'admission-v1'
    || subject.workflow.repository !== 'MyWallpapers/native-addon-toolchain'
    || subject.workflow.path !== '.github/workflows/native-addon-build.yml'
    || subject.workflow.requestedRef !== acceptedWorkflowRef
    || subject.workflow.workflowSha !== workflowSha
    || subject.build.reproducible !== true || !Array.isArray(subject.build.replicas)
    || subject.build.replicas.length !== 2) fail('Admission subject identity is inconsistent.')
  for (const [index, replica] of subject.build.replicas.entries()) {
    exactKeys(replica, ['replica', 'runner', 'outputInventory'], `build replica ${index + 1}`)
    exactKeys(
      replica.runner,
      ['environment', 'label', 'operatingSystem', 'architecture'],
      `build replica ${index + 1} runner`,
    )
    exactKeys(
      replica.outputInventory,
      ['fileCount', 'totalBytes', 'digest'],
      `build replica ${index + 1} output inventory`,
    )
    if (replica.replica !== index + 1 || replica.runner.environment !== 'github-hosted'
      || replica.runner.label !== 'windows-2025'
      || replica.runner.operatingSystem !== 'Windows' || replica.runner.architecture !== 'X64'
      || !Number.isSafeInteger(replica.outputInventory.fileCount)
      || replica.outputInventory.fileCount <= 0
      || !Number.isSafeInteger(replica.outputInventory.totalBytes)
      || replica.outputInventory.totalBytes < 0) {
      fail('Admission subject build replica is inconsistent.')
    }
    requiredString(replica.outputInventory.digest, 'replica output digest', SHA256_PATTERN, 71)
  }
  if (subject.build.replicas[0].outputInventory.digest
    !== subject.build.replicas[1].outputInventory.digest
    || subject.build.replicas[0].outputInventory.fileCount
      !== subject.build.replicas[1].outputInventory.fileCount
    || subject.build.replicas[0].outputInventory.totalBytes
      !== subject.build.replicas[1].outputInventory.totalBytes) {
    fail('Admission subject replicas do not describe byte-identical outputs.')
  }
  requiredString(subject.source.repositoryId, 'repository ID', /^[1-9][0-9]*$/u, 32)
  requiredString(subject.source.repository, 'repository', REPOSITORY_PATTERN, 140)
  requiredString(subject.source.commitSha, 'commit SHA', COMMIT_PATTERN, 40)
  requiredString(subject.source.ref, 'source tag ref', /^refs\/tags\/[^\0\r\n]{1,240}$/u, 250)
  for (const value of [
    subject.source.sourceDigest,
    subject.source.lockfilesDigest,
    subject.release.distributionDigest,
    subject.release.manifestDigest,
    subject.build.environmentDigest,
    subject.evidence.authorInventory.digest,
    subject.evidence.sbomDigest,
    subject.evidence.provenanceDigest,
  ]) requiredString(value, 'subject digest', SHA256_PATTERN, 71)
  if (!Number.isSafeInteger(subject.evidence.authorInventory.fileCount)
    || subject.evidence.authorInventory.fileCount <= 0
    || !Number.isSafeInteger(subject.evidence.authorInventory.totalBytes)
    || subject.evidence.authorInventory.totalBytes <= 0) fail('Author inventory summary is invalid.')
  const generatedAt = new Date(subject.generatedAt)
  if (Number.isNaN(generatedAt.valueOf()) || generatedAt.toISOString() !== subject.generatedAt) {
    fail('Admission subject timestamp is not canonical UTC RFC 3339.')
  }

  const evidence = {
    schemaVersion: 1,
    checklistVersion: 'native-build-integrity-v1',
    release: {
      addonReleaseId: releaseId,
      distributionDigest: subject.release.distributionDigest,
      commitSha: subject.source.commitSha,
    },
    repository: {
      id: subject.source.repositoryId,
      fullName: subject.source.repository,
      licenseSpdx,
    },
    workflow: {
      repository: 'MyWallpapers/native-addon-toolchain',
      repositoryRef: 'refs/heads/admission-v1',
      workflowSha,
    },
    build: {
      sourceDigest: subject.source.sourceDigest,
      environmentDigest: subject.build.environmentDigest,
      lockfilesDigest: subject.source.lockfilesDigest,
      reproducible: true,
    },
    artifacts: {
      distributionDigest: subject.release.distributionDigest,
      nativeManifestDigest,
      sbomDigest: subject.evidence.sbomDigest,
      provenanceDigest: subject.evidence.provenanceDigest,
      materialsDigest,
      materialsSizeBytes: materialsSize,
      authorInventory: subject.evidence.authorInventory,
    },
    generatedAt: subject.generatedAt,
  }
  const bytes = canonicalBytes(evidence)
  await writeFile(options.output, bytes, { flag: 'wx' })
  process.stdout.write(`${JSON.stringify({
    evidencePath: options.output,
    evidenceDigest: digest(bytes),
    materialsDigest,
    materialsSizeBytes: materialsSize,
  })}\n`)
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
})
