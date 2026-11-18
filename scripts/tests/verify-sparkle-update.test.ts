import { afterEach, describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

import {
  type ExecResult,
  HarnessError,
  type RestoreContext,
  restoreSparkleState,
  runWithProtection,
} from '../verify-sparkle-update.ts'

const SCRIPTS = resolve(import.meta.dir, '..')
const tempDirs: string[] = []

function makeTemp(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  tempDirs.push(dir)
  return dir
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()
    if (dir) rmSync(dir, { recursive: true, force: true })
  }
})

function okDefaults(): ExecResult {
  return { status: 0, stdout: 'plist-data', stderr: '' }
}

describe('restoreSparkleState', () => {
  test('restores existing preferences and caches while verifying every step', () => {
    const root = makeTemp('tovri-restore-ok-')
    const backupDir = join(root, 'backup')
    const liveDir = join(root, 'live')
    mkdirSync(join(backupDir, 'app-cache'), { recursive: true })
    mkdirSync(join(backupDir, 'auto-cache'), { recursive: true })
    mkdirSync(join(liveDir, 'app-cache'), { recursive: true })
    mkdirSync(join(liveDir, 'auto-cache'), { recursive: true })

    const prefsBackup = join(backupDir, 'prefs.plist')
    writeFileSync(prefsBackup, '<plist>original</plist>', 'utf8')
    writeFileSync(join(backupDir, 'app-cache', 'state.txt'), 'orig-app', 'utf8')
    writeFileSync(join(backupDir, 'auto-cache', 'state.txt'), 'orig-auto', 'utf8')
    writeFileSync(join(liveDir, 'app-cache', 'dirty.txt'), 'mutated', 'utf8')

    const commands: string[][] = []
    const ctx: RestoreContext = {
      prefsDomain: 'app.tovri.Tovri',
      prefsPlist: join(liveDir, 'app.tovri.Tovri.plist'),
      prefsBackup,
      hadPrefs: true,
      appCacheDir: join(liveDir, 'app-cache'),
      appCacheBackup: join(backupDir, 'app-cache'),
      hadAppCache: true,
      autoupdateCacheDir: join(liveDir, 'auto-cache'),
      autoupdateCacheBackup: join(backupDir, 'auto-cache'),
      hadAutoupdateCache: true,
    }

    const res = restoreSparkleState(ctx, {
      runDefaults: (args) => {
        commands.push(args)
        return okDefaults()
      },
    })

    expect(res.ok).toBe(true)
    expect(res.errors).toEqual([])
    expect(commands).toEqual([
      ['import', 'app.tovri.Tovri', prefsBackup],
      ['export', 'app.tovri.Tovri', '-'],
    ])
    expect(readFileSync(join(liveDir, 'app-cache', 'state.txt'), 'utf8')).toBe('orig-app')
    expect(existsSync(join(liveDir, 'app-cache', 'dirty.txt'))).toBe(false)
    expect(readFileSync(join(liveDir, 'auto-cache', 'state.txt'), 'utf8')).toBe('orig-auto')
    // Backups were copied (not moved), so backupDir stays complete until caller deletes it.
    expect(existsSync(join(backupDir, 'app-cache', 'state.txt'))).toBe(true)
  })

  test('removes temporary prefs and caches when host had none beforehand', () => {
    const root = makeTemp('tovri-restore-absent-')
    const liveDir = join(root, 'live')
    mkdirSync(join(liveDir, 'app-cache'), { recursive: true })
    mkdirSync(join(liveDir, 'auto-cache'), { recursive: true })
    const plist = join(liveDir, 'app.tovri.Tovri.plist')
    writeFileSync(plist, 'temp', 'utf8')
    let deleted = false

    const res = restoreSparkleState(
      {
        prefsDomain: 'app.tovri.Tovri',
        prefsPlist: plist,
        prefsBackup: join(root, 'missing.plist'),
        hadPrefs: false,
        appCacheDir: join(liveDir, 'app-cache'),
        appCacheBackup: join(root, 'no-app'),
        hadAppCache: false,
        autoupdateCacheDir: join(liveDir, 'auto-cache'),
        autoupdateCacheBackup: join(root, 'no-auto'),
        hadAutoupdateCache: false,
      },
      {
        runDefaults: (args) => {
          if (args[0] === 'read') return deleted ? { status: 1, stdout: '', stderr: 'not found' } : okDefaults()
          if (args[0] === 'delete') {
            deleted = true
            return { status: 0, stdout: '', stderr: '' }
          }
          return { status: 1, stdout: '', stderr: '' }
        },
      },
    )

    expect(res.ok).toBe(true)
    expect(res.errors).toEqual([])
    expect(existsSync(plist)).toBe(false)
    expect(existsSync(join(liveDir, 'app-cache'))).toBe(false)
    expect(existsSync(join(liveDir, 'auto-cache'))).toBe(false)
  })

  test('reports errors and preserves backups when defaults import or cache restore fails', () => {
    const root = makeTemp('tovri-restore-fail-')
    const backupDir = join(root, 'backup')
    const liveDir = join(root, 'live')
    mkdirSync(join(backupDir, 'app-cache'), { recursive: true })
    mkdirSync(join(backupDir, 'auto-cache'), { recursive: true })
    const prefsBackup = join(backupDir, 'prefs.plist')
    writeFileSync(prefsBackup, '<plist>keep</plist>', 'utf8')
    writeFileSync(join(backupDir, 'app-cache', 'state.txt'), 'keep-app', 'utf8')

    const res = restoreSparkleState(
      {
        prefsDomain: 'app.tovri.Tovri',
        prefsPlist: join(liveDir, 'app.tovri.Tovri.plist'),
        prefsBackup,
        hadPrefs: true,
        appCacheDir: join(liveDir, 'app-cache'),
        appCacheBackup: join(backupDir, 'app-cache'),
        hadAppCache: true,
        autoupdateCacheDir: join(liveDir, 'auto-cache'),
        autoupdateCacheBackup: join(backupDir, 'auto-cache'),
        hadAutoupdateCache: true,
      },
      {
        runDefaults: () => ({ status: 1, stdout: '', stderr: 'cfprefsd permission denied' }),
        copyDir: () => {
          throw new Error('disk full')
        },
      },
    )

    expect(res.ok).toBe(false)
    expect(res.errors.length).toBeGreaterThanOrEqual(2)
    expect(res.errors.some((e) => e.includes('defaults import'))).toBe(true)
    expect(res.errors.some((e) => e.includes('disk full'))).toBe(true)
    expect(existsSync(prefsBackup)).toBe(true)
    expect(existsSync(join(backupDir, 'app-cache', 'state.txt'))).toBe(true)
  })
})

describe('runWithProtection lifecycle & interruption handling', () => {
  test('unwinds thrown failure into restoration and removes backups when restore succeeds', async () => {
    const root = makeTemp('tovri-protect-ok-')
    const workDir = join(root, 'work')
    const backupDir = join(root, 'backup')
    mkdirSync(workDir, { recursive: true })
    mkdirSync(backupDir, { recursive: true })
    writeFileSync(join(backupDir, 'prefs.plist'), 'saved', 'utf8')
    let restored = 0

    let caught: unknown = null
    try {
      await runWithProtection(
        {
          workDir,
          backupDir,
          restore: () => {
            restored += 1
            return { ok: true, errors: [] }
          },
        },
        async (lifecycle) => {
          lifecycle.markStateModified()
          throw new HarnessError('simulated step failure')
        },
      )
    } catch (err) {
      caught = err
    }

    expect(caught).toBeInstanceOf(HarnessError)
    expect((caught as Error).message).toBe('simulated step failure')
    expect(restored).toBe(1)
    expect(existsSync(workDir)).toBe(false)
    expect(existsSync(backupDir)).toBe(false)
  })

  test('retains backupDir when restoration fails after either a thrown failure or clean body', async () => {
    const root = makeTemp('tovri-protect-retain-')
    const workDir1 = join(root, 'work1')
    const backupDir1 = join(root, 'backup1')
    mkdirSync(workDir1, { recursive: true })
    mkdirSync(backupDir1, { recursive: true })
    writeFileSync(join(backupDir1, 'prefs.plist'), 'must-stay-1', 'utf8')

    let thrown1: unknown = null
    try {
      await runWithProtection(
        {
          workDir: workDir1,
          backupDir: backupDir1,
          restore: () => ({ ok: false, errors: ['restore failed 1'] }),
        },
        async (lifecycle) => {
          lifecycle.markStateModified()
          throw new HarnessError('primary failure')
        },
      )
    } catch (err) {
      thrown1 = err
    }
    expect(thrown1).toBeInstanceOf(HarnessError)
    expect(existsSync(workDir1)).toBe(false)
    expect(existsSync(join(backupDir1, 'prefs.plist'))).toBe(true)

    const workDir2 = join(root, 'work2')
    const backupDir2 = join(root, 'backup2')
    mkdirSync(workDir2, { recursive: true })
    mkdirSync(backupDir2, { recursive: true })
    writeFileSync(join(backupDir2, 'prefs.plist'), 'must-stay-2', 'utf8')

    let thrown2: unknown = null
    try {
      await runWithProtection(
        {
          workDir: workDir2,
          backupDir: backupDir2,
          restore: () => ({ ok: false, errors: ['restore failed 2'] }),
        },
        async (lifecycle) => {
          lifecycle.markStateModified()
        },
      )
    } catch (err) {
      thrown2 = err
    }
    expect(thrown2).toBeInstanceOf(HarnessError)
    expect((thrown2 as Error).message).toContain('backups retained at')
    expect(existsSync(workDir2)).toBe(false)
    expect(existsSync(join(backupDir2, 'prefs.plist'))).toBe(true)
  })

  test('skips restoration if aborted before live state was modified', async () => {
    const root = makeTemp('tovri-protect-unmodified-')
    const workDir = join(root, 'work')
    const backupDir = join(root, 'backup')
    mkdirSync(workDir, { recursive: true })
    mkdirSync(backupDir, { recursive: true })
    let restoreCalls = 0

    await expect(
      runWithProtection(
        {
          workDir,
          backupDir,
          restore: () => {
            restoreCalls += 1
            return { ok: true, errors: [] }
          },
        },
        async () => {
          throw new HarnessError('failed before touching live state')
        },
      ),
    ).rejects.toThrow('failed before touching live state')

    expect(restoreCalls).toBe(0)
    expect(existsSync(workDir)).toBe(false)
    expect(existsSync(backupDir)).toBe(false)
  })

  test('handles SIGINT by terminating child, running restoration, and retaining backups on restore failure', async () => {
    const root = makeTemp('tovri-sigint-')
    const helperScript = join(root, 'sigint-child.ts')
    writeFileSync(
      helperScript,
      `import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { runWithProtection } from '${join(SCRIPTS, 'verify-sparkle-update.ts')}'

const workDir = process.env.TOVRI_TEST_WORK!
const backupDir = process.env.TOVRI_TEST_BACKUP!
const marker = process.env.TOVRI_TEST_RESTORED!
const failRestore = process.env.TOVRI_TEST_FAIL === '1'
mkdirSync(workDir, { recursive: true })
mkdirSync(backupDir, { recursive: true })
writeFileSync(join(backupDir, 'prefs.plist'), 'saved', 'utf8')

await runWithProtection(
  {
    workDir,
    backupDir,
    restore: () => {
      writeFileSync(marker, 'restored', 'utf8')
      return failRestore ? { ok: false, errors: ['simulated restore failure'] } : { ok: true, errors: [] }
    },
  },
  async (lifecycle) => {
    lifecycle.markStateModified()
    const child = Bun.spawn(['/bin/sleep', '30'], { stdout: 'ignore', stderr: 'ignore' })
    lifecycle.trackChild(child)
    writeFileSync(process.env.TOVRI_TEST_CHILDPID!, String(child.pid), 'utf8')
    console.log('READY')
    await Bun.sleep(30_000)
  },
)
`,
      'utf8',
    )

    const runCase = async (failRestore: boolean) => {
      const caseDir = join(root, failRestore ? 'case-fail' : 'case-ok')
      const workDir = join(caseDir, 'work')
      const backupDir = join(caseDir, 'backup')
      const marker = join(caseDir, 'restored.flag')
      const childPidFile = join(caseDir, 'child.pid')
      mkdirSync(caseDir, { recursive: true })

      const proc = Bun.spawn(['bun', helperScript], {
        env: {
          ...process.env,
          TOVRI_TEST_WORK: workDir,
          TOVRI_TEST_BACKUP: backupDir,
          TOVRI_TEST_RESTORED: marker,
          TOVRI_TEST_CHILDPID: childPidFile,
          TOVRI_TEST_FAIL: failRestore ? '1' : '0',
        },
        stdout: 'pipe',
        stderr: 'pipe',
      })

      const reader = proc.stdout.getReader()
      const decoder = new TextDecoder()
      let seen = ''
      while (!seen.includes('READY')) {
        const chunk = await reader.read()
        if (chunk.done) break
        seen += decoder.decode(chunk.value)
      }
      reader.releaseLock()

      const childPid = Number(readFileSync(childPidFile, 'utf8').trim())
      proc.kill('SIGINT')
      const status = await proc.exited
      await new Response(proc.stderr).text()

      return { status, workDir, backupDir, marker, childPid }
    }

    const okRes = await runCase(false)
    expect(okRes.status).toBe(130)
    expect(existsSync(okRes.marker)).toBe(true)
    expect(existsSync(okRes.workDir)).toBe(false)
    expect(existsSync(okRes.backupDir)).toBe(false)
    expect(spawnSync('kill', ['-0', String(okRes.childPid)]).status).not.toBe(0)

    const failRes = await runCase(true)
    expect(failRes.status).toBe(1)
    expect(existsSync(failRes.marker)).toBe(true)
    expect(existsSync(failRes.workDir)).toBe(false)
    expect(existsSync(join(failRes.backupDir, 'prefs.plist'))).toBe(true)
    expect(spawnSync('kill', ['-0', String(failRes.childPid)]).status).not.toBe(0)
  })
})

describe('build.sh --output-dir CLI validation', () => {
  test('--help lists --output-dir and missing value exits 2 cleanly', () => {
    const help = spawnSync(join(SCRIPTS, 'build.sh'), ['--help'], { encoding: 'utf8' })
    expect(help.status).toBe(0)
    expect(help.stdout).toContain('--output-dir')

    const missing = spawnSync(join(SCRIPTS, 'build.sh'), ['--output-dir'], { encoding: 'utf8' })
    expect(missing.status).toBe(2)
    expect(missing.stderr).toContain('--output-dir')
  })
})
