#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'

function fail(message) {
  throw new Error(message)
}

function argumentsFromCommandLine(argv) {
  if (argv.length % 2 !== 0) fail('Every bundle-index option requires a value.')
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index]
    const value = argv[index + 1]
    if (!name?.startsWith('--') || !value || values.has(name)) fail(`Invalid bundle-index option: ${name ?? ''}`)
    values.set(name, value)
  }
  const required = [
    '--manifest', '--inventory', '--repository-id', '--repository-owner',
    '--repository-name', '--commit-sha', '--source-digest', '--output',
  ]
  for (const name of required) if (!values.has(name)) fail(`Missing bundle-index option: ${name}`)
  if (values.size !== required.length) fail('Unknown bundle-index option.')
  return Object.fromEntries(required.map((name) => [name.slice(2), values.get(name)]))
}

function plainRecord(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)) {
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
  const record = plainRecord(value, path)
  const output = {}
  for (const key of Object.keys(record).sort()) output[key] = canonicalize(record[key], `${path}.${key}`)
  return output
}

function canonicalJson(value) {
  return Buffer.from(JSON.stringify(canonicalize(value)), 'utf8')
}

function digest(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`
}

function requiredString(value, label, pattern) {
  if (typeof value !== 'string' || !pattern.test(value)) fail(`${label} is invalid.`)
  return value
}

async function main() {
  const options = argumentsFromCommandLine(process.argv.slice(2))
  const manifest = plainRecord(JSON.parse(await readFile(options.manifest, 'utf8')), 'manifest')
  const inventory = JSON.parse(await readFile(options.inventory, 'utf8'))
  if (!Array.isArray(inventory) || inventory.length === 0) fail('Payload inventory must not be empty.')
  const seenPaths = new Set()
  const files = inventory.map((rawFile, index) => {
    const file = plainRecord(rawFile, `files[${index}]`)
    const path = requiredString(file.path, `files[${index}].path`, /^[A-Za-z0-9._/-]+$/u)
    const normalized = path.toLowerCase()
    if (seenPaths.has(normalized)) fail(`Duplicate payload path: ${path}`)
    seenPaths.add(normalized)
    if (!Number.isSafeInteger(file.size) || file.size <= 0) fail(`files[${index}].size is invalid.`)
    const sha256 = requiredString(file.sha256, `files[${index}].sha256`, /^sha256:[0-9a-f]{64}$/u)
    const mediaType = requiredString(file.mediaType, `files[${index}].mediaType`, /^[\x20-\x7e]{1,128}$/u)
    return { path, size: file.size, sha256, mediaType }
  }).sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0)

  const index = {
    schemaVersion: 1,
    version: requiredString(
      manifest.version,
      'manifest.version',
      /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:(?:0|[1-9]\d*)|(?:\d*[A-Za-z-][0-9A-Za-z-]*))(?:\.(?:(?:0|[1-9]\d*)|(?:\d*[A-Za-z-][0-9A-Za-z-]*)))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u,
    ),
    provenance: {
      repositoryId: requiredString(options['repository-id'], 'repository id', /^[1-9][0-9]*$/u),
      owner: requiredString(options['repository-owner'], 'repository owner', /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/u),
      name: requiredString(options['repository-name'], 'repository name', /^[A-Za-z0-9._-]{1,100}$/u),
      commitSha: requiredString(options['commit-sha'], 'commit SHA', /^[0-9a-f]{40}$/u),
    },
    sourceDigest: requiredString(options['source-digest'], 'source digest', /^sha256:[0-9a-f]{64}$/u),
    manifestDigest: digest(canonicalJson(manifest)),
    capabilitySnapshot: {
      runtime: manifest.runtime,
      settings: manifest.settings,
      native: manifest.native ?? null,
      ui: manifest.ui ?? null,
    },
    entry: requiredString(manifest.entry, 'manifest.entry', /^[A-Za-z0-9._/-]+$/u),
    files,
  }
  const bytes = canonicalJson(index)
  await writeFile(options.output, bytes)
  process.stdout.write(`${JSON.stringify({
    distributionDigest: digest(bytes),
    manifestDigest: index.manifestDigest,
  })}\n`)
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
})
