import assert from 'node:assert/strict'
import { mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
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
