import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

test('bundle indices keep one strict shape for Canvas, native-only and service-only add-ons', async () => {
  const root = await mkdtemp(join(tmpdir(), 'mywallpaper-bundle-index-'))
  try {
    const script = fileURLToPath(new URL('./create-addon-bundle-index.mjs', import.meta.url))
    const manifestPath = join(root, 'manifest.json')
    const inventoryPath = join(root, 'inventory.json')
    const outputPath = join(root, 'bundle-index.json')
    const license = Buffer.from('MIT\n')
    await writeFile(inventoryPath, JSON.stringify([{
      path: 'LICENSE', size: license.length,
      sha256: `sha256:${createHash('sha256').update(license).digest('hex')}`,
      mediaType: 'text/plain',
    }]))
    for (const [manifest, entry] of [
      [{ runtime: 'canvas-v1', version: '1.0.0', entry: 'dist/addon.js' }, 'dist/addon.js'],
      [{ runtime: 'native-v1', version: '1.0.0' }, null],
      [{ runtime: 'canvas-v1', version: '1.0.0', services: { entry: 'dist/service.js' } }, 'dist/service.js'],
    ]) {
      await writeFile(manifestPath, JSON.stringify(manifest))
      const result = spawnSync(process.execPath, [
        script, '--manifest', manifestPath, '--inventory', inventoryPath,
        '--repository-id', '42', '--repository-owner', 'MyWallpapers',
        '--repository-name', 'fixture', '--commit-sha', 'a'.repeat(40),
        '--source-digest', `sha256:${'b'.repeat(64)}`, '--output', outputPath,
      ], { encoding: 'utf8' })
      assert.equal(result.status, 0, result.stderr)
      const index = JSON.parse(await readFile(outputPath, 'utf8'))
      assert.deepEqual(Object.keys(index).sort(), [
        'schemaVersion', 'version', 'provenance', 'sourceDigest',
        'manifestDigest', 'entry', 'files',
      ].sort())
      assert.equal(index.entry, entry)
    }
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
