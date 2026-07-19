#!/usr/bin/env node

import { execFileSync } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  canonicalJsonDigest,
  createReviewedAdmissionEnvironment,
} from './admission-environment.mjs'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const toolchainRoot = resolve(scriptDirectory, '..', '..')

function fail(message) {
  throw new Error(message)
}

async function main() {
  const args = process.argv.slice(2)
  if (args.length !== 2 || args[0] !== '--workflow-sha') {
    fail('Usage: compute-admission-environment-digest.mjs --workflow-sha <40 lowercase hex characters>')
  }
  const workflowSha = args[1]
  const checkoutSha = execFileSync('git', ['-C', toolchainRoot, 'rev-parse', 'HEAD'], {
    encoding: 'utf8',
    windowsHide: true,
  }).trim().toLowerCase()
  if (checkoutSha !== workflowSha) {
    fail('The checked-out toolchain does not match --workflow-sha.')
  }

  const canonicalCli = JSON.parse(await readFile(
    join(toolchainRoot, '.github', 'canonical-cli', 'canonical-cli.lock.json'),
    'utf8',
  ))
  const nodeVersion = (await readFile(join(toolchainRoot, '.nvmrc'), 'utf8')).trim()
  const environment = createReviewedAdmissionEnvironment({
    nodeVersion,
    canonicalCli,
    workflowSha,
  })
  process.stdout.write(`${canonicalJsonDigest(environment)}\n`)
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
})
