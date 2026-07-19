import assert from 'node:assert/strict'
import { AsyncLocalStorage, createHook } from 'node:async_hooks'
import { appendFileSync, truncateSync } from 'node:fs'
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import {
  digestBoundedRegularFile,
  readBoundedJson,
  readBoundedRegularFile,
} from './safe-files.mjs'

async function fixture(run) {
  const root = await mkdtemp(join(tmpdir(), 'mywallpaper-safe-file-'))
  try {
    await run(root)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}

async function rejectMutationOnFirstDescriptorRead(operation, mutate, message) {
  const scope = new AsyncLocalStorage()
  const marker = Symbol('safe-file-read')
  let fileRequestCount = 0
  let mutationRan = false
  const hook = createHook({
    init(_asyncId, type) {
      if (mutationRan || type !== 'FSREQPROMISE' || scope.getStore() !== marker) return
      fileRequestCount += 1
      // open(), FileHandle.stat() and lstat() are the three validated requests.
      // The next request is the first descriptor-bound content read.
      if (fileRequestCount === 4) {
        mutate()
        mutationRan = true
      }
    },
  })
  hook.enable()
  try {
    await assert.rejects(scope.run(marker, operation), message)
    assert.equal(mutationRan, true, 'the deterministic concurrent mutation did not run')
  } finally {
    hook.disable()
  }
}

test('reads the bytes from the validated regular-file descriptor', async () => fixture(async (root) => {
  const path = join(root, 'value.json')
  await writeFile(path, '{"schemaVersion":1}')
  const value = await readBoundedJson(path, { label: 'fixture', maximumBytes: 1024 })
  assert.deepEqual(value, { schemaVersion: 1 })
  assert.deepEqual(
    await digestBoundedRegularFile(path, { label: 'fixture', maximumBytes: 1024 }),
    {
      sha256: 'sha256:0e9561cfb83d50990a103b3896fe249a11fe27fa28985448187f93ec12116d72',
      sizeBytes: 19,
    },
  )
}))

test('rejects empty and oversized files', async () => fixture(async (root) => {
  const empty = join(root, 'empty')
  const oversized = join(root, 'oversized')
  await writeFile(empty, '')
  await writeFile(oversized, '12345')
  await assert.rejects(
    readBoundedRegularFile(empty, { label: 'empty fixture', maximumBytes: 8 }),
    /bounded regular file/u,
  )
  await assert.rejects(
    readBoundedRegularFile(oversized, { label: 'large fixture', maximumBytes: 4 }),
    /bounded regular file/u,
  )
}))

test('never follows a symbolic-link input', async (context) => fixture(async (root) => {
  const target = join(root, 'target')
  const link = join(root, 'link')
  await writeFile(target, 'secret')
  try {
    await symlink(target, link, 'file')
  } catch (error) {
    if (error?.code === 'EPERM') {
      context.skip('The current Windows account cannot create symbolic links.')
      return
    }
    throw error
  }
  await assert.rejects(
    readBoundedRegularFile(link, { label: 'linked fixture', maximumBytes: 1024 }),
    /bounded regular file/u,
  )
}))

test('rejects truncation during a descriptor-bound read', async () => fixture(async (root) => {
  const path = join(root, 'changing-read.bin')
  await writeFile(path, Buffer.alloc(4 * 1024 * 1024, 0x41))
  await rejectMutationOnFirstDescriptorRead(
    () => readBoundedRegularFile(path, { label: 'changing read', maximumBytes: 8 * 1024 * 1024 }),
    () => truncateSync(path, 1),
    /changed while it was read|ended before its validated size/u,
  )
}))

test('rejects growth during a descriptor-bound digest', async () => fixture(async (root) => {
  const path = join(root, 'changing-digest.bin')
  await writeFile(path, Buffer.alloc(4 * 1024 * 1024, 0x42))
  await rejectMutationOnFirstDescriptorRead(
    () => digestBoundedRegularFile(path, { label: 'changing digest', maximumBytes: 8 * 1024 * 1024 }),
    () => appendFileSync(path, Buffer.from([0x43])),
    /changed while it was read/u,
  )
}))

test('rejects a Windows junction as a file input without symlink privilege', {
  skip: process.platform !== 'win32',
}, async () => fixture(async (root) => {
  const target = join(root, 'junction-target')
  const junction = join(root, 'junction')
  await mkdir(target)
  await symlink(target, junction, 'junction')
  await assert.rejects(
    readBoundedRegularFile(junction, { label: 'junction fixture', maximumBytes: 1024 }),
    /bounded regular file/u,
  )
}))
