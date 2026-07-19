#!/usr/bin/env node

import { lstat, readFile, writeFile } from 'node:fs/promises'
import {
  canonicalRunnerObservationBytes,
  runnerObservationDigest,
  validateReplicaRunnerObservation,
} from './runner-observation.mjs'

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  if (argv.length !== 4 || argv[0] !== '--input' || argv[2] !== '--output'
    || !argv[1] || !argv[3]) {
    fail('Usage: write-runner-observation.mjs --input <raw.json> --output <replica.json>')
  }
  return { input: argv[1], output: argv[3] }
}

const options = parseArguments(process.argv.slice(2))
const metadata = await lstat(options.input)
if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0 || metadata.size > 16 * 1024 * 1024) {
  fail('Raw runner observation must be a bounded regular file.')
}
let value
try {
  value = JSON.parse(await readFile(options.input, 'utf8'))
} catch {
  fail('Raw runner observation is not valid JSON.')
}
const observation = validateReplicaRunnerObservation(value)
const bytes = canonicalRunnerObservationBytes(observation)
await writeFile(options.output, bytes, { flag: 'wx' })
process.stdout.write(`${JSON.stringify({
  output: options.output,
  digest: runnerObservationDigest(observation),
})}\n`)
