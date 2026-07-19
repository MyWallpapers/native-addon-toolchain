import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

function canonicalize(value) {
  if (value === null || typeof value !== 'object') return value
  if (Array.isArray(value)) return value.map(canonicalize)
  const output = {}
  for (const key of Object.keys(value).sort()) output[key] = canonicalize(value[key])
  return output
}

function canonicalBytes(value) {
  return Buffer.from(JSON.stringify(canonicalize(value)), 'utf8')
}

function digest(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`
}

function git(root, args, encoding = 'utf8') {
  const result = spawnSync('git', ['-C', root, ...args], { encoding, windowsHide: true })
  assert.equal(result.status, 0, result.stderr?.toString())
  return result.stdout
}

test('admission-v1 evidence binds two identical replicas and rejects drift', async () => {
  const toolchainRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
  const script = join(toolchainRoot, '.github', 'scripts', 'create-admission-evidence.mjs')
  const nativeEvidenceScript = join(toolchainRoot, '.github', 'scripts', 'create-native-build-evidence.mjs')
  const temporary = await mkdtemp(join(tmpdir(), 'mywallpaper-admission-v1-'))
  try {
    const source = join(temporary, 'source')
    await mkdir(source)
    await writeFile(join(source, 'pnpm-lock.yaml'), "lockfileVersion: '9.0'\n")
    await writeFile(join(source, 'manifest.json'), '{"version":"1.2.3"}\n')
    await writeFile(
      join(source, 'mywallpaper.config.json'),
      '{"native":{"builds":[{"id":"fixture","command":"cmake","args":["--build","build"],"cwd":".","env":{},"outputs":["native/out/windows-x86_64/fixture.exe"]}]}}\n',
    )
    git(source, ['init', '--initial-branch=admission'])
    git(source, ['add', '--all'])
    git(source, [
      '-c', 'user.name=Admission fixture',
      '-c', 'user.email=admission@mywallpaper.invalid',
      'commit', '-m', 'fixture',
    ])
    const commitSha = git(source, ['rev-parse', 'HEAD']).trim().toLowerCase()
    const workflowSha = git(toolchainRoot, ['rev-parse', 'HEAD']).trim().toLowerCase()
    const sourceTree = git(source, ['ls-tree', '-r', '--full-tree', commitSha], null)

    const primary = join(temporary, 'primary')
    const reproduction = join(temporary, 'reproduction')
    await mkdir(join(primary, 'web', 'dist'), { recursive: true })
    await mkdir(join(primary, 'companion'), { recursive: true })
    await mkdir(join(primary, 'hooks', 'native', 'out'), { recursive: true })
    await writeFile(join(primary, 'web', 'dist', 'index.html'), '<!doctype html>')
    await writeFile(join(primary, 'companion', '.empty'), '')
    await writeFile(join(primary, 'hooks', 'native', 'out', 'hook.dll'), 'fixture-hook')
    await cp(primary, reproduction, { recursive: true })

    const observations = join(temporary, 'observations')
    for (const replica of [1, 2]) {
      const directory = join(observations, `replica-${replica}`)
      await mkdir(directory, { recursive: true })
      await writeFile(join(directory, 'replica.json'), canonicalBytes({
        schemaVersion: 1,
        replica,
        runner: {
          environment: 'github-hosted',
          label: 'windows-2025',
          operatingSystem: 'Windows',
          architecture: 'X64',
        },
        workflowSha,
      }))
    }

    const payloadBytes = Buffer.from('<!doctype html>', 'utf8')
    const rawPayload = [{
      path: 'dist/index.html',
      size: payloadBytes.length,
      sha256: digest(payloadBytes),
      mediaType: 'text/html; charset=utf-8',
    }]
    const bundleIndex = {
      schemaVersion: 1,
      version: '1.2.3',
      provenance: {
        repositoryId: '123456',
        owner: 'MyWallpapers',
        name: 'admission-fixture',
        commitSha,
      },
      sourceDigest: digest(sourceTree),
      manifestDigest: digest(Buffer.from('{"version":"1.2.3"}', 'utf8')),
      capabilitySnapshot: { runtime: 'canvas-v1', settings: [], native: null, ui: null },
      entry: 'dist/index.html',
      files: rawPayload,
    }
    const bundleIndexPath = join(temporary, 'bundle-index.json')
    const payloadPath = join(temporary, 'payload.json')
    const archivePath = join(temporary, 'bundle.zip')
    await writeFile(bundleIndexPath, canonicalBytes(bundleIndex))
    await writeFile(payloadPath, JSON.stringify(rawPayload))
    await writeFile(archivePath, 'opaque deterministic archive fixture')

    const argumentsFor = (outputRoot, reproductionRoot = reproduction) => [
      script,
      '--repository-root', source,
      '--primary-root', primary,
      '--reproduction-root', reproductionRoot,
      '--replica-observations-root', observations,
      '--bundle-index', bundleIndexPath,
      '--payload-inventory', payloadPath,
      '--archive', archivePath,
      '--toolchain-root', toolchainRoot,
      '--repository-id', '123456',
      '--repository-name', 'MyWallpapers/admission-fixture',
      '--commit-sha', commitSha,
      '--release-ref', 'refs/tags/v1.2.3',
      '--workflow-ref', `MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml@${workflowSha}`,
      '--workflow-sha', workflowSha,
      '--operational-max-files', '512',
      '--operational-max-expanded-bytes', String(32 * 1024 * 1024),
      '--operational-max-metadata-bytes', String(16 * 1024 * 1024),
      '--output-root', outputRoot,
    ]
    const outputRoot = join(temporary, 'evidence')
    const result = spawnSync(process.execPath, argumentsFor(outputRoot), { encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    const summary = JSON.parse(result.stdout)
    const subjectBytes = await readFile(summary.subjectPath)
    const subject = JSON.parse(subjectBytes)
    assert.equal(summary.subjectDigest, digest(subjectBytes))
    assert.equal(subject.contract, 'admission-v1')
    assert.equal(subject.workflow.workflowSha, workflowSha)
    assert.equal(subject.source.commitSha, commitSha)
    assert.equal(subject.build.reproducible, true)
    assert.equal(subject.build.replicas.length, 2)
    assert.equal(subject.build.replicas[0].outputInventory.digest, subject.build.replicas[1].outputInventory.digest)
    assert.deepEqual(Object.keys(subject.workflow).sort(), [
      'path', 'repository', 'requestedRef', 'workflowSha',
    ])
    for (const name of [
      'author-inventory.json', 'environment.json', 'lockfiles.json',
      'provenance.intoto.json', 'replica-inventories.json', 'sbom.cdx.json',
    ]) assert.ok((await readFile(join(outputRoot, name))).length > 0)
    const reviewedEnvironment = JSON.parse(await readFile(join(outputRoot, 'environment.json'), 'utf8'))
    assert.equal(reviewedEnvironment.kind, 'reviewed-build-environment')
    assert.equal(Object.hasOwn(reviewedEnvironment, 'authorBuildRecipe'), false)
    const provenance = JSON.parse(await readFile(join(outputRoot, 'provenance.intoto.json'), 'utf8'))
    assert.ok(provenance.predicate.buildDefinition.resolvedDependencies.some(
      (dependency) => dependency.uri === 'mywallpaper:native-companion-build-config',
    ))

    const rerunRoot = join(temporary, 'evidence-rerun')
    const rerunResult = spawnSync(process.execPath, argumentsFor(rerunRoot), { encoding: 'utf8' })
    assert.equal(rerunResult.status, 0, rerunResult.stderr)
    const evidenceFiles = [
      'admission-subject-v1.json', 'author-inventory.json', 'bundle-index.json',
      'environment.json', 'lockfiles.json', 'payload-inventory.json',
      'provenance.intoto.json', 'replica-inventories.json', 'sbom.cdx.json',
      'source-git-tree.txt',
    ]
    for (const name of evidenceFiles) {
      assert.deepEqual(
        await readFile(join(rerunRoot, name)),
        await readFile(join(outputRoot, name)),
        `${name} changed across an exact rerun`,
      )
    }

    const materialsPath = join(temporary, 'materials.zip')
    const nativeEvidencePath = join(temporary, 'native-build-evidence.json')
    await writeFile(materialsPath, 'opaque admission materials')
    const nativeEvidenceResult = spawnSync(process.execPath, [
      nativeEvidenceScript,
      '--subject', summary.subjectPath,
      '--addon-release-id', '019f0000-0000-7000-8000-000000000001',
      '--license-spdx', 'MIT',
      '--native-manifest-digest', digest(Buffer.from('native-manifest', 'utf8')),
      '--materials-digest', digest(await readFile(materialsPath)),
      '--materials-size', String((await readFile(materialsPath)).length),
      '--workflow-sha', workflowSha,
      '--output', nativeEvidencePath,
    ], { encoding: 'utf8' })
    assert.equal(nativeEvidenceResult.status, 0, nativeEvidenceResult.stderr)
    const nativeEvidenceSummary = JSON.parse(nativeEvidenceResult.stdout)
    const nativeEvidenceBytes = await readFile(nativeEvidencePath)
    const nativeEvidence = JSON.parse(nativeEvidenceBytes)
    assert.equal(nativeEvidenceSummary.evidenceDigest, digest(nativeEvidenceBytes))
    assert.equal(nativeEvidence.release.addonReleaseId, '019f0000-0000-7000-8000-000000000001')
    assert.equal(nativeEvidence.repository.licenseSpdx, 'MIT')
    assert.equal(nativeEvidence.workflow.repository, 'MyWallpapers/native-addon-toolchain')
    assert.equal(nativeEvidence.workflow.repositoryRef, 'refs/heads/admission-v1')
    assert.equal(nativeEvidence.workflow.workflowSha, workflowSha)
    assert.deepEqual(Object.keys(nativeEvidence.workflow).sort(), [
      'repository', 'repositoryRef', 'workflowSha',
    ])
    assert.equal(nativeEvidence.artifacts.materialsDigest, digest(await readFile(materialsPath)))

    const drifted = join(temporary, 'drifted')
    await cp(reproduction, drifted, { recursive: true })
    await writeFile(join(drifted, 'hooks', 'native', 'out', 'hook.dll'), 'different-hook')
    const rejected = spawnSync(
      process.execPath,
      argumentsFor(join(temporary, 'rejected-evidence'), drifted),
      { encoding: 'utf8' },
    )
    assert.notEqual(rejected.status, 0)
    assert.match(rejected.stderr, /Replica inventories are not byte-identical/u)
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})
