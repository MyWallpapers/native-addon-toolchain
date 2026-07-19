#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { lstat, mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { spawnSync } from 'node:child_process'
import {
  canonicalJsonDigest,
  createReviewedAdmissionEnvironment,
} from './admission-environment.mjs'
import {
  createRunnerObservationPredicate,
  runnerObservationDigest,
  validateReplicaRunnerObservation,
} from './runner-observation.mjs'

const SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/u
const COMMIT_PATTERN = /^[0-9a-f]{40}$/u
const REPOSITORY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/u
const LOCKFILE_NAMES = new Set([
  'bun.lock', 'bun.lockb', 'Cargo.lock', 'composer.lock', 'Gemfile.lock', 'go.sum',
  'package-lock.json', 'packages.lock.json', 'Pipfile.lock', 'pnpm-lock.yaml',
  'poetry.lock', 'uv.lock', 'yarn.lock',
])
const REQUIRED_OPTIONS = [
  'repository-root', 'primary-root', 'reproduction-root', 'replica-observations-root',
  'bundle-index', 'payload-inventory', 'archive', 'toolchain-root', 'repository-id',
  'repository-name', 'commit-sha', 'release-ref', 'workflow-ref', 'workflow-sha',
  'run-id', 'run-attempt', 'runner-observation-output', 'output-root', 'operational-max-files',
  'operational-max-expanded-bytes', 'operational-max-metadata-bytes',
]

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  if (argv.length !== REQUIRED_OPTIONS.length * 2) fail('Admission evidence options are incomplete.')
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index]?.replace(/^--/u, '')
    const value = argv[index + 1]
    if (!REQUIRED_OPTIONS.includes(name) || !value || values.has(name)) {
      fail(`Invalid admission evidence option: ${argv[index] ?? ''}`)
    }
    values.set(name, value)
  }
  for (const name of REQUIRED_OPTIONS) if (!values.has(name)) fail(`Missing --${name}.`)
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
    fail(`${label} fields do not match admission-v1.`)
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

function canonicalJsonBytes(value) {
  return Buffer.from(JSON.stringify(canonicalize(value)), 'utf8')
}

function digestBytes(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`
}

function digestJson(value) {
  return digestBytes(canonicalJsonBytes(value))
}

async function digestFile(path) {
  const hash = createHash('sha256')
  await new Promise((resolvePromise, rejectPromise) => {
    const stream = createReadStream(path)
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('error', rejectPromise)
    stream.on('end', resolvePromise)
  })
  return `sha256:${hash.digest('hex')}`
}

function requiredString(value, label, pattern, maximum = 1024) {
  if (typeof value !== 'string' || value.length === 0 || value.length > maximum
    || value.includes('\0') || (pattern && !pattern.test(value))) {
    fail(`${label} is invalid.`)
  }
  return value
}

function positiveSafeInteger(value, label) {
  if (typeof value !== 'string' || !/^[1-9][0-9]*$/u.test(value)) fail(`${label} is invalid.`)
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed <= 0) fail(`${label} is invalid.`)
  return parsed
}

function addChecked(current, increment, label) {
  if (!Number.isSafeInteger(current) || !Number.isSafeInteger(increment) || increment < 0
    || current > Number.MAX_SAFE_INTEGER - increment) fail(`${label} overflows a safe integer.`)
  return current + increment
}

function safePortablePath(value, label) {
  requiredString(value, label, null, 900)
  if (value.includes('\\') || value.includes(':') || value.startsWith('/')) {
    fail(`${label} must be a portable relative path.`)
  }
  for (const segment of value.split('/')) {
    if (!/^[A-Za-z0-9._-]{1,255}$/u.test(segment) || segment === '.' || segment === '..'
      || segment.endsWith('.') || segment.endsWith(' ')) fail(`${label} is not canonical.`)
  }
  return value
}

function inside(root, path, label) {
  const absoluteRoot = resolve(root)
  const absolute = resolve(path)
  const fromRoot = relative(absoluteRoot, absolute)
  if (fromRoot === '' || fromRoot === '..' || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) {
    fail(`${label} escapes its trusted root.`)
  }
  return absolute
}

function runGit(repositoryRoot, args, label, maximumBytes) {
  const result = spawnSync('git', ['-C', repositoryRoot, ...args], {
    encoding: null,
    maxBuffer: maximumBytes,
    windowsHide: true,
  })
  if (result.status !== 0 || result.error) fail(`${label} failed.`)
  return result.stdout
}

async function readJson(path, label, maximumBytes) {
  const metadata = await lstat(path)
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0
    || metadata.size > maximumBytes) {
    fail(`${label} must be a bounded regular file.`)
  }
  try {
    return JSON.parse(await readFile(path, 'utf8'))
  } catch {
    fail(`${label} is not valid JSON.`)
  }
}

async function writeCanonical(path, value, maximumBytes) {
  const bytes = canonicalJsonBytes(value)
  if (bytes.length > maximumBytes) fail(`${path} exhausted the runner operational metadata budget.`)
  await writeFile(path, bytes, { flag: 'wx' })
}

async function inventoryTree(root, label, operationalBudget) {
  root = resolve(root)
  const rootMetadata = await lstat(root)
  if (!rootMetadata.isDirectory() || rootMetadata.isSymbolicLink()) fail(`${label} root is invalid.`)
  const files = []
  let totalBytes = 0
  const pending = [root]
  while (pending.length > 0) {
    const directory = pending.pop()
    const entries = await readdir(directory, { withFileTypes: true })
    entries.sort((left, right) => left.name < right.name ? 1 : left.name > right.name ? -1 : 0)
    for (const entry of entries) {
      const absolute = join(directory, entry.name)
      const metadata = await lstat(absolute)
      if (metadata.isSymbolicLink()) fail(`${label} contains a link.`)
      if (metadata.isDirectory()) {
        pending.push(absolute)
        continue
      }
      if (!metadata.isFile()) fail(`${label} contains a non-regular file.`)
      if (files.length >= operationalBudget.files) {
        fail(`${label} exhausted the runner operational file budget.`)
      }
      totalBytes = addChecked(totalBytes, metadata.size, `${label} byte count`)
      if (totalBytes > operationalBudget.expandedBytes) {
        fail(`${label} exhausted the runner operational expanded-byte budget.`)
      }
      const path = safePortablePath(relative(root, absolute).split(sep).join('/'), `${label} path`)
      files.push({ path, sizeBytes: metadata.size, sha256: await digestFile(absolute) })
    }
  }
  files.sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0)
  const document = { schemaVersion: 1, files }
  return {
    document,
    summary: {
      fileCount: files.length,
      totalBytes,
      digest: digestJson(document),
    },
  }
}

async function findReplicaObservations(root, maximumMetadataBytes) {
  root = resolve(root)
  const found = []
  const pending = [root]
  while (pending.length > 0) {
    const directory = pending.pop()
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const absolute = join(directory, entry.name)
      const metadata = await lstat(absolute)
      if (metadata.isSymbolicLink()) fail('Replica observations contain a link.')
      if (metadata.isDirectory()) pending.push(absolute)
      else if (metadata.isFile() && entry.name === 'replica.json') found.push(absolute)
      else if (metadata.isFile()) fail('Replica observations contain an unexpected file.')
      else fail('Replica observations contain a non-regular entry.')
    }
  }
  if (found.length !== 2) fail('Exactly two replica observations are required.')
  const observations = []
  for (const path of found) {
    observations.push(validateReplicaRunnerObservation(
      await readJson(path, 'replica observation', maximumMetadataBytes),
    ))
  }
  observations.sort((left, right) => left.replica - right.replica)
  if (observations[0].replica !== 1 || observations[1].replica !== 2) fail('Replica identities are invalid.')
  return observations
}

async function trackedLockfiles(repositoryRoot, commitSha, operationalBudget) {
  const output = runGit(
    repositoryRoot,
    ['ls-tree', '-r', '-z', '--name-only', commitSha],
    'Lockfile inventory',
    operationalBudget.metadataBytes,
  )
  const paths = output.toString('utf8').split('\0').filter(Boolean)
    .filter((path) => LOCKFILE_NAMES.has(basename(path)))
    .sort((left, right) => left < right ? -1 : left > right ? 1 : 0)
  if (!paths.includes('pnpm-lock.yaml')) fail('The committed root pnpm-lock.yaml is required.')
  if (paths.length > operationalBudget.files) {
    fail('Lockfile inventory exhausted the runner operational file budget.')
  }
  const files = []
  let totalBytes = 0
  for (const path of paths) {
    safePortablePath(path, 'lockfile path')
    const absolute = inside(repositoryRoot, join(repositoryRoot, ...path.split('/')), 'lockfile')
    const metadata = await lstat(absolute)
    if (!metadata.isFile() || metadata.isSymbolicLink()) fail(`Lockfile is invalid: ${path}`)
    totalBytes = addChecked(totalBytes, metadata.size, 'Lockfile byte count')
    if (totalBytes > operationalBudget.expandedBytes) {
      fail('Lockfile inventory exhausted the runner operational expanded-byte budget.')
    }
    files.push({ path, sizeBytes: metadata.size, sha256: await digestFile(absolute) })
  }
  const document = { schemaVersion: 1, files }
  return { document, digest: digestJson(document) }
}

function payloadInventory(raw, operationalBudget) {
  if (!Array.isArray(raw) || raw.length === 0) fail('Bundle payload inventory is empty.')
  if (raw.length >= operationalBudget.files) {
    fail('Bundle payload inventory exhausted the runner operational file budget.')
  }
  const seen = new Set()
  let totalBytes = 0
  const files = raw.map((entry, index) => {
    plainRecord(entry, `payload[${index}]`)
    const path = safePortablePath(entry.path, `payload[${index}].path`)
    if (seen.has(path.toLowerCase())) fail('Bundle payload inventory contains a duplicate path.')
    seen.add(path.toLowerCase())
    if (!Number.isSafeInteger(entry.size) || entry.size <= 0) fail('Bundle payload size is invalid.')
    totalBytes = addChecked(totalBytes, entry.size, 'Bundle payload byte count')
    if (totalBytes > operationalBudget.expandedBytes) {
      fail('Bundle payload inventory exhausted the runner operational expanded-byte budget.')
    }
    requiredString(entry.sha256, 'Bundle payload digest', SHA256_PATTERN, 71)
    requiredString(entry.mediaType, 'Bundle payload media type', /^[\x20-\x7e]{1,128}$/u, 128)
    return { path, sizeBytes: entry.size, sha256: entry.sha256, mediaType: entry.mediaType }
  })
  files.sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0)
  return { schemaVersion: 1, files }
}

async function main() {
  const options = parseArguments(process.argv.slice(2))
  const repositoryRoot = resolve(options['repository-root'])
  const toolchainRoot = resolve(options['toolchain-root'])
  const outputRoot = resolve(options['output-root'])
  const repositoryId = requiredString(options['repository-id'], 'repository ID', /^[1-9][0-9]*$/u, 32)
  const repositoryName = requiredString(options['repository-name'], 'repository name', REPOSITORY_PATTERN, 140)
  const commitSha = requiredString(options['commit-sha'], 'commit SHA', COMMIT_PATTERN, 40)
  const workflowSha = requiredString(options['workflow-sha'], 'workflow SHA', COMMIT_PATTERN, 40)
  const runId = requiredString(options['run-id'], 'workflow run ID', /^[1-9][0-9]*$/u, 32)
  const runAttempt = requiredString(options['run-attempt'], 'workflow run attempt', /^[1-9][0-9]*$/u, 16)
  const runnerObservationOutput = resolve(options['runner-observation-output'])
  const runnerOutputFromEvidence = relative(outputRoot, runnerObservationOutput)
  if (runnerOutputFromEvidence === '' || (!isAbsolute(runnerOutputFromEvidence)
    && runnerOutputFromEvidence !== '..' && !runnerOutputFromEvidence.startsWith(`..${sep}`))) {
    fail('Volatile runner observations must remain outside immutable admission materials.')
  }
  const operationalBudget = {
    files: positiveSafeInteger(options['operational-max-files'], 'operational file budget'),
    expandedBytes: positiveSafeInteger(
      options['operational-max-expanded-bytes'],
      'operational expanded-byte budget',
    ),
    metadataBytes: positiveSafeInteger(
      options['operational-max-metadata-bytes'],
      'operational metadata-byte budget',
    ),
  }
  const releaseRef = requiredString(options['release-ref'], 'release ref', /^refs\/tags\/[\x21-\x7e]{1,240}$/u, 250)
  const workflowRef = requiredString(options['workflow-ref'], 'workflow ref', /^[\x21-\x7e]{1,300}$/u, 300)
  if ((runGit(
    repositoryRoot,
    ['rev-parse', 'HEAD'],
    'Caller commit',
    operationalBudget.metadataBytes,
  ).toString('utf8').trim().toLowerCase()) !== commitSha) {
    fail('Caller checkout differs from the release commit.')
  }
  if ((runGit(
    toolchainRoot,
    ['rev-parse', 'HEAD'],
    'Toolchain commit',
    operationalBudget.metadataBytes,
  ).toString('utf8').trim().toLowerCase()) !== workflowSha) {
    fail('Toolchain checkout differs from the resolved workflow SHA.')
  }

  const bundleIndex = plainRecord(
    await readJson(options['bundle-index'], 'bundle index', operationalBudget.metadataBytes),
    'bundle index',
  )
  const provenance = plainRecord(bundleIndex.provenance, 'bundle index provenance')
  if (bundleIndex.schemaVersion !== 1 || provenance.repositoryId !== repositoryId
    || `${provenance.owner}/${provenance.name}`.toLowerCase() !== repositoryName.toLowerCase()
    || provenance.commitSha !== commitSha || !SHA256_PATTERN.test(bundleIndex.sourceDigest)
    || !SHA256_PATTERN.test(bundleIndex.manifestDigest)) fail('Bundle index provenance is inconsistent.')
  const distributionDigest = digestJson(bundleIndex)
  const archiveMetadata = await stat(options.archive)
  if (!archiveMetadata.isFile() || archiveMetadata.size <= 0) fail('Release archive is invalid.')
  const archiveDigest = await digestFile(options.archive)

  const primary = await inventoryTree(options['primary-root'], 'primary replica', operationalBudget)
  const reproduction = await inventoryTree(
    options['reproduction-root'],
    'reproduced replica',
    operationalBudget,
  )
  if (JSON.stringify(primary.document) !== JSON.stringify(reproduction.document)) {
    fail('Replica inventories are not byte-identical.')
  }
  const observations = await findReplicaObservations(
    options['replica-observations-root'],
    operationalBudget.metadataBytes,
  )
  if (observations.some((observation) => observation.workflowSha !== workflowSha)) {
    fail('Replica observation workflow SHA differs from the resolved workflow.')
  }
  if (observations.some((observation) => observation.run.id !== runId
    || observation.run.attempt !== runAttempt)) {
    fail('Replica observation workflow attempt differs from the current run.')
  }
  const replicas = observations.map((observation) => ({
    replica: observation.replica,
    // Mutable hosted-image and tool versions belong to the per-attempt signed
    // predicate below, never to immutable release materials. Keep only the
    // reviewed platform contract in the stable subject and SLSA statement.
    runner: {
      environment: observation.runner.environment,
      label: observation.runner.label,
      operatingSystem: observation.runner.operatingSystem,
      architecture: observation.runner.architecture,
    },
    outputInventory: observation.replica === 1 ? primary.summary : reproduction.summary,
  }))

  const sourceTreeBytes = runGit(
    repositoryRoot,
    ['ls-tree', '-r', '--full-tree', commitSha],
    'Source tree inventory',
    operationalBudget.metadataBytes,
  )
  if (sourceTreeBytes.length === 0 || sourceTreeBytes.at(-1) !== 0x0a
    || digestBytes(sourceTreeBytes) !== bundleIndex.sourceDigest) fail('Source tree digest differs from the bundle index.')
  const lockfiles = await trackedLockfiles(repositoryRoot, commitSha, operationalBudget)
  const payload = payloadInventory(
    await readJson(
      options['payload-inventory'],
      'payload inventory',
      operationalBudget.metadataBytes,
    ),
    operationalBudget,
  )
  const authorInventoryDocument = {
    schemaVersion: 1,
    files: payload.files.map(({ path, sizeBytes, sha256 }) => ({ path, sizeBytes, sha256 })),
  }
  const authorInventory = {
    fileCount: authorInventoryDocument.files.length,
    totalBytes: authorInventoryDocument.files.reduce(
      (sum, file) => addChecked(sum, file.sizeBytes, 'Author inventory byte count'),
      0,
    ),
    digest: digestJson(authorInventoryDocument),
  }

  const cliLock = await readJson(
    join(toolchainRoot, '.github', 'canonical-cli', 'canonical-cli.lock.json'),
    'canonical CLI lock',
    operationalBudget.metadataBytes,
  )
  const nodeVersion = (await readFile(join(toolchainRoot, '.nvmrc'), 'utf8')).trim()
  requiredString(nodeVersion, 'pinned Node.js version', /^[0-9]+\.[0-9]+\.[0-9]+$/u, 32)
  let companionBuildConfig = null
  const companionConfigPath = join(repositoryRoot, 'mywallpaper.config.json')
  try {
    const metadata = await lstat(companionConfigPath)
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0
      || metadata.size > operationalBudget.metadataBytes) {
      fail('Committed native companion build configuration is not a bounded regular file.')
    }
    const tracked = runGit(
      repositoryRoot,
      ['ls-files', '--error-unmatch', '--', 'mywallpaper.config.json'],
      'Native companion build configuration',
      operationalBudget.metadataBytes,
    ).toString('utf8').trim()
    if (tracked !== 'mywallpaper.config.json') fail('Native companion build configuration is not tracked exactly.')
    const bytes = await readFile(companionConfigPath)
    let definition
    try { definition = plainRecord(JSON.parse(bytes.toString('utf8')), 'native companion build configuration') }
    catch { fail('Native companion build configuration is not valid JSON.') }
    companionBuildConfig = {
      path: 'mywallpaper.config.json',
      sha256: digestBytes(bytes),
      definition,
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
  const environment = createReviewedAdmissionEnvironment({
    nodeVersion,
    canonicalCli: cliLock,
    workflowSha,
  })
  const environmentDigest = canonicalJsonDigest(environment)
  const replicaDocument = { schemaVersion: 1, replicas }
  const payloadDigest = digestJson(payload)

  const sourceCommitTimeText = runGit(
    repositoryRoot,
    ['show', '-s', '--format=%cI', commitSha],
    'Source commit timestamp',
    operationalBudget.metadataBytes,
  ).toString('utf8').trim()
  const sourceCommitTime = new Date(sourceCommitTimeText)
  if (Number.isNaN(sourceCommitTime.valueOf())) fail('Source commit timestamp is invalid.')
  // Wall-clock build time would make immutable release materials differ on a
  // rerun. The source commit timestamp is canonical, meaningful and stable.
  const generatedAt = sourceCommitTime.toISOString()
  const sbom = {
    bomFormat: 'CycloneDX',
    specVersion: '1.6',
    version: 1,
    metadata: {
      timestamp: generatedAt,
      component: {
        type: 'application',
        name: repositoryName,
        version: bundleIndex.version,
        hashes: [{ alg: 'SHA-256', content: archiveDigest.slice(7) }],
        properties: [
          { name: 'mywallpaper:repository-id', value: repositoryId },
          { name: 'mywallpaper:commit-sha', value: commitSha },
          { name: 'mywallpaper:distribution-digest', value: distributionDigest },
        ],
      },
    },
    components: payload.files.map((file) => ({
      type: 'file',
      name: file.path,
      hashes: [{ alg: 'SHA-256', content: file.sha256.slice(7) }],
    })),
  }
  const sbomDigest = digestJson(sbom)
  const provenanceStatement = {
    _type: 'https://in-toto.io/Statement/v1',
    subject: [
      { name: 'mywallpaper-addon-bundle.zip', digest: { sha256: archiveDigest.slice(7) } },
      { name: 'bundle-index.json', digest: { sha256: distributionDigest.slice(7) } },
    ],
    predicateType: 'https://slsa.dev/provenance/v1',
    predicate: {
      buildDefinition: {
        buildType: 'https://mywallpaper.online/buildTypes/addon-admission/v1',
        externalParameters: { repository: repositoryName, repositoryId, commitSha, releaseRef },
        internalParameters: {
          workflowRef,
          workflowSha,
          environmentDigest,
          replicas,
        },
        resolvedDependencies: [
          { uri: `git+https://github.com/${repositoryName}@${commitSha}`, digest: { gitCommit: commitSha } },
          {
            uri: `git+https://github.com/MyWallpapers/native-addon-toolchain@${workflowSha}`,
            digest: { gitCommit: workflowSha },
          },
          { uri: 'mywallpaper:lockfiles', digest: { sha256: lockfiles.digest.slice(7) } },
          { uri: 'mywallpaper:canonical-cli', digest: { sha256: cliLock.sha256.slice(7) } },
          ...(companionBuildConfig ? [{
            uri: 'mywallpaper:native-companion-build-config',
            digest: { sha256: companionBuildConfig.sha256.slice(7) },
          }] : []),
        ],
      },
      runDetails: {
        builder: {
          id: `https://github.com/MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml@${workflowSha}`,
        },
        byproducts: [{ name: 'sbom.cdx.json', digest: { sha256: sbomDigest.slice(7) } }],
      },
    },
  }
  const provenanceDigest = digestJson(provenanceStatement)

  await mkdir(outputRoot, { recursive: false })
  await writeCanonical(join(outputRoot, 'bundle-index.json'), bundleIndex, operationalBudget.metadataBytes)
  await writeCanonical(join(outputRoot, 'payload-inventory.json'), payload, operationalBudget.metadataBytes)
  await writeCanonical(
    join(outputRoot, 'author-inventory.json'),
    authorInventoryDocument,
    operationalBudget.metadataBytes,
  )
  await writeCanonical(join(outputRoot, 'lockfiles.json'), lockfiles.document, operationalBudget.metadataBytes)
  await writeCanonical(join(outputRoot, 'environment.json'), environment, operationalBudget.metadataBytes)
  await writeCanonical(
    join(outputRoot, 'replica-inventories.json'),
    replicaDocument,
    operationalBudget.metadataBytes,
  )
  await writeCanonical(join(outputRoot, 'sbom.cdx.json'), sbom, operationalBudget.metadataBytes)
  await writeCanonical(
    join(outputRoot, 'provenance.intoto.json'),
    provenanceStatement,
    operationalBudget.metadataBytes,
  )
  await writeFile(join(outputRoot, 'source-git-tree.txt'), sourceTreeBytes, { flag: 'wx' })

  const subject = {
    schemaVersion: 1,
    contract: 'admission-v1',
    generatedAt,
    source: {
      repositoryId,
      repository: repositoryName,
      commitSha,
      ref: releaseRef,
      sourceDigest: bundleIndex.sourceDigest,
      lockfilesDigest: lockfiles.digest,
    },
    workflow: {
      repository: 'MyWallpapers/native-addon-toolchain',
      path: '.github/workflows/native-addon-build.yml',
      requestedRef: workflowRef,
      workflowSha,
    },
    release: {
      version: bundleIndex.version,
      distributionDigest,
      manifestDigest: bundleIndex.manifestDigest,
      capabilitySnapshot: bundleIndex.capabilitySnapshot,
    },
    artifact: {
      name: 'mywallpaper-addon-bundle.zip',
      sizeBytes: archiveMetadata.size,
      sha256: archiveDigest,
    },
    build: {
      environmentDigest,
      reproducible: true,
      replicas,
    },
    evidence: {
      authorInventory,
      bundleIndexDigest: distributionDigest,
      payloadInventoryDigest: payloadDigest,
      sbomDigest,
      provenanceDigest,
    },
  }
  const runnerObservationPredicate = createRunnerObservationPredicate({
    observations,
    repositoryId,
    repository: repositoryName,
    commitSha,
    releaseRef,
    workflowSha,
    runId,
    runAttempt,
    artifactDigest: archiveDigest,
    distributionDigest,
  })
  const subjectPath = join(outputRoot, 'admission-subject-v1.json')
  await writeCanonical(subjectPath, subject, operationalBudget.metadataBytes)
  await writeCanonical(
    runnerObservationOutput,
    runnerObservationPredicate,
    operationalBudget.metadataBytes,
  )
  process.stdout.write(`${JSON.stringify({
    subjectPath,
    subjectDigest: digestJson(subject),
    archiveDigest,
    distributionDigest,
    environmentDigest,
    lockfilesDigest: lockfiles.digest,
    sbomDigest,
    provenanceDigest,
    runnerObservationPath: runnerObservationOutput,
    runnerObservationDigest: runnerObservationDigest(runnerObservationPredicate),
    authorInventory,
  })}\n`)
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
})
