import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { lstat, open } from 'node:fs/promises'

function fail(message) {
  throw new Error(message)
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino
}

function sameContentVersion(left, right) {
  return sameIdentity(left, right)
    && left.size === right.size
    && left.mtimeNs === right.mtimeNs
    && left.ctimeNs === right.ctimeNs
}

function validateRegularFile(metadata, label, minimumBytes, maximumBytes) {
  if (!metadata.isFile() || metadata.isSymbolicLink()
    || metadata.size < BigInt(minimumBytes) || metadata.size > BigInt(maximumBytes)) {
    fail(`${label} must be a bounded regular file.`)
  }
}

async function withBoundedRegularFile(
  path,
  { label, maximumBytes, minimumBytes = 1 },
  consume,
) {
  if (typeof path !== 'string' || path.length === 0 || typeof label !== 'string'
    || label.length === 0 || !Number.isSafeInteger(minimumBytes) || minimumBytes < 0
    || !Number.isSafeInteger(maximumBytes) || maximumBytes < minimumBytes) {
    fail('Safe file read options are invalid.')
  }

  const noFollow = Number.isInteger(constants.O_NOFOLLOW) ? constants.O_NOFOLLOW : 0
  let handle
  try {
    handle = await open(path, constants.O_RDONLY | noFollow)
  } catch (error) {
    if (error?.code === 'ELOOP') fail(`${label} must be a bounded regular file.`)
    throw error
  }
  try {
    const opened = await handle.stat({ bigint: true })
    const pathAfterOpen = await lstat(path, { bigint: true })
    validateRegularFile(opened, label, minimumBytes, maximumBytes)
    validateRegularFile(pathAfterOpen, label, minimumBytes, maximumBytes)
    if (!sameIdentity(opened, pathAfterOpen)) {
      fail(`${label} changed while it was opened.`)
    }

    const value = await consume(handle, Number(opened.size))
    const afterRead = await handle.stat({ bigint: true })
    const pathAfterRead = await lstat(path, { bigint: true })
    validateRegularFile(afterRead, label, minimumBytes, maximumBytes)
    validateRegularFile(pathAfterRead, label, minimumBytes, maximumBytes)
    if (!sameContentVersion(opened, afterRead) || !sameIdentity(opened, pathAfterRead)) {
      fail(`${label} changed while it was read.`)
    }
    return { value, sizeBytes: Number(afterRead.size) }
  } finally {
    await handle.close()
  }
}

/**
 * Read a bounded file through the descriptor that was validated.
 *
 * O_NOFOLLOW closes the link-swap window on platforms that expose it. Windows
 * does not currently expose that flag through Node, so the path and descriptor
 * identities are also compared before and after the read. Once opened, all
 * bytes come from the descriptor; the pathname is never reopened for content.
 */
export async function readBoundedRegularFile(path, options) {
  const { value: bytes, sizeBytes } = await withBoundedRegularFile(
    path,
    options,
    (handle) => handle.readFile(),
  )
  if (bytes.length !== sizeBytes) fail(`${options.label} changed while it was read.`)
  return bytes
}

export async function digestBoundedRegularFile(path, options) {
  const { value, sizeBytes } = await withBoundedRegularFile(
    path,
    options,
    async (handle, expectedSize) => {
      const hash = createHash('sha256')
      const buffer = Buffer.allocUnsafe(Math.min(Math.max(expectedSize, 1), 1024 * 1024))
      let position = 0
      while (position < expectedSize) {
        const length = Math.min(buffer.length, expectedSize - position)
        const { bytesRead } = await handle.read(buffer, 0, length, position)
        if (bytesRead <= 0) fail(`${options.label} ended before its validated size.`)
        hash.update(buffer.subarray(0, bytesRead))
        position += bytesRead
      }
      return { sha256: `sha256:${hash.digest('hex')}`, bytesRead: position }
    },
  )
  if (value.bytesRead !== sizeBytes) fail(`${options.label} changed while it was read.`)
  return { sha256: value.sha256, sizeBytes }
}

export async function readBoundedJson(path, options) {
  const bytes = await readBoundedRegularFile(path, options)
  try {
    return JSON.parse(bytes.toString('utf8'))
  } catch {
    fail(`${options.label} is not valid JSON.`)
  }
}
