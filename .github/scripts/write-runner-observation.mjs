#!/usr/bin/env node

import { writeFile } from 'node:fs/promises'
import {
  canonicalRunnerObservationBytes,
  runnerObservationDigest,
  validateReplicaRunnerObservation,
} from './runner-observation.mjs'
import { readBoundedJson } from './safe-files.mjs'

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
const value = await readBoundedJson(options.input, {
  label: 'Raw runner observation',
  maximumBytes: 16 * 1024 * 1024,
})
const observation = validateReplicaRunnerObservation(value)
const bytes = canonicalRunnerObservationBytes(observation)
await writeFile(options.output, bytes, { flag: 'wx' })
process.stdout.write(`${JSON.stringify({
  output: options.output,
  digest: runnerObservationDigest(observation),
})}\n`)
