#!/usr/bin/env node

import {
  runnerObservationDigest,
  validateRunnerObservationPredicate,
} from './runner-observation.mjs'
import { readBoundedJson } from './safe-files.mjs'

const REQUIRED_OPTIONS = [
  'input', 'expected-digest', 'repository-id', 'repository', 'commit-sha', 'release-ref',
  'workflow-sha', 'run-id', 'run-attempt', 'artifact-digest', 'distribution-digest',
]

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  if (argv.length !== REQUIRED_OPTIONS.length * 2) fail('Runner observation verification options are incomplete.')
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index]?.replace(/^--/u, '')
    const value = argv[index + 1]
    if (!REQUIRED_OPTIONS.includes(name) || !value || values.has(name)) {
      fail(`Invalid runner observation verification option: ${argv[index] ?? ''}`)
    }
    values.set(name, value)
  }
  return Object.fromEntries(values)
}

const options = parseArguments(process.argv.slice(2))
const raw = await readBoundedJson(options.input, {
  label: 'Runner observation predicate',
  maximumBytes: 16 * 1024 * 1024,
})
const predicate = validateRunnerObservationPredicate(raw)
const actualDigest = runnerObservationDigest(predicate)
if (actualDigest !== options['expected-digest']
  || predicate.source.repositoryId !== options['repository-id']
  || predicate.source.repository !== options.repository
  || predicate.source.commitSha !== options['commit-sha']
  || predicate.source.ref !== options['release-ref']
  || predicate.workflow.workflowSha !== options['workflow-sha']
  || predicate.workflow.runId !== options['run-id']
  || predicate.workflow.runAttempt !== options['run-attempt']
  || predicate.artifact.sha256 !== options['artifact-digest']
  || predicate.artifact.distributionDigest !== options['distribution-digest']) {
  fail('Runner observation predicate differs from the current verified release attempt.')
}
process.stdout.write(`${JSON.stringify({ predicatePath: options.input, predicateDigest: actualDigest })}\n`)
