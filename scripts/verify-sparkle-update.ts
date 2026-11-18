#!/usr/bin/env bun
import { spawnSync } from 'node:child_process'
import { generateKeyPairSync } from 'node:crypto'
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ROOT, SIGN_UPDATE, buildNumber, checkKeys, minimumMacOS, sign } from './release-notes.ts'

export interface ExecResult {
  status: number
  stdout: string
  stderr: string
}

export interface RestoreContext {
  prefsDomain: string
  prefsPlist: string
  prefsBackup: string
  hadPrefs: boolean
  appCacheDir: string
  appCacheBackup: string
  hadAppCache: boolean
  autoupdateCacheDir: string
  autoupdateCacheBackup: string
  hadAutoupdateCache: boolean
}

export interface RestoreDeps {
  runDefaults?: (args: string[]) => ExecResult
  copyDir?: typeof cpSync
  removePath?: typeof rmSync
  pathExists?: typeof existsSync
  fileSize?: (path: string) => number
}

export interface RestoreResult {
  ok: boolean
  errors: string[]
}

export interface LifecycleContext {
  markStateModified: () => void
  trackChild: (proc: ReturnType<typeof Bun.spawn> | null) => void
  registerServer: (server: ReturnType<typeof Bun.serve> | null) => void
}

interface VerificationReport {
  ok: boolean
  stage: string
  foundVersion?: string
  foundBuild?: string
  downloadedBytes?: number
  extracted?: boolean
  error?: string
}

export class HarnessError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'HarnessError'
  }
}

const PREFS_DOMAIN = 'app.tovri.Tovri'
const WAIT_ARRAY = new Int32Array(new SharedArrayBuffer(4))

function sleepSyncMs(ms: number): void {
  Atomics.wait(WAIT_ARRAY, 0, 0, ms)
}

function fail(message: string): never {
  throw new HarnessError(message)
}

function exec(
  command: string[],
  options: { cwd?: string; env?: Record<string, string | undefined>; input?: string } = {},
): ExecResult {
  const [tool = '', ...args] = command
  const res = spawnSync(tool, args, {
    cwd: options.cwd ?? ROOT,
    env: options.env ? { ...process.env, ...options.env } : process.env,
    input: options.input,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  })
  return {
    status: res.status ?? (res.error ? 1 : 0),
    stdout: res.stdout ?? '',
    stderr: res.stderr || String(res.error ?? ''),
  }
}

function mustExec(
  command: string[],
  label: string,
  options: { cwd?: string; env?: Record<string, string | undefined>; input?: string } = {},
): ExecResult {
  const res = exec(command, options)
  if (res.status !== 0) {
    fail(`${label} failed (exit ${res.status}):\n${res.stderr || res.stdout}`)
  }
  return res
}

function plistGet(plistPath: string, key: string): string {
  return mustExec(['/usr/libexec/PlistBuddy', '-c', `Print :${key}`, plistPath], `PlistBuddy Print :${key}`).stdout.trim()
}

function plistSetOrAddString(plistPath: string, key: string, value: string): void {
  const setRes = exec(['/usr/libexec/PlistBuddy', '-c', `Set :${key} ${value}`, plistPath])
  if (setRes.status !== 0) {
    mustExec(['/usr/libexec/PlistBuddy', '-c', `Add :${key} string ${value}`, plistPath], `PlistBuddy Add :${key}`)
  }
}

function plistSetLocalNetworking(plistPath: string): void {
  if (exec(['/usr/libexec/PlistBuddy', '-c', 'Print :NSAppTransportSecurity', plistPath]).status !== 0) {
    mustExec(['/usr/libexec/PlistBuddy', '-c', 'Add :NSAppTransportSecurity dict', plistPath], 'add NSAppTransportSecurity')
  }
  if (
    exec(['/usr/libexec/PlistBuddy', '-c', 'Set :NSAppTransportSecurity:NSAllowsLocalNetworking true', plistPath]).status !==
    0
  ) {
    mustExec(
      ['/usr/libexec/PlistBuddy', '-c', 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true', plistPath],
      'add NSAllowsLocalNetworking',
    )
  }
}

function detectSigningIdentity(): string {
  if (process.env.TOVRI_SIGN_IDENTITY) return process.env.TOVRI_SIGN_IDENTITY
  const found = exec(['security', 'find-identity', '-p', 'codesigning']).stdout
  return found.includes('"Tovri Self-Signed"') ? 'Tovri Self-Signed' : '-'
}

function resignApp(appPath: string, identity: string, scratchDir: string): void {
  const sparkle = join(appPath, 'Contents/Frameworks/Sparkle.framework/Versions/B')
  const installerXpc = join(sparkle, 'XPCServices/Installer.xpc')
  const downloaderXpc = join(sparkle, 'XPCServices/Downloader.xpc')
  const autoupdate = join(sparkle, 'Autoupdate')
  const updaterApp = join(sparkle, 'Updater.app')
  const framework = join(appPath, 'Contents/Frameworks/Sparkle.framework')

  const downloaderEnt = join(scratchDir, 'downloader.entitlements')
  const dumped = exec(['codesign', '-d', '--entitlements', '-', '--xml', downloaderXpc])
  writeFileSync(downloaderEnt, dumped.status === 0 ? dumped.stdout : '', 'utf8')

  const baseSign = ['codesign', '--force', '--timestamp=none', '--sign', identity, '--options', 'runtime']
  mustExec([...baseSign, installerXpc], 'sign Installer.xpc')
  if (statSync(downloaderEnt).size > 0) {
    mustExec([...baseSign, '--entitlements', downloaderEnt, downloaderXpc], 'sign Downloader.xpc')
  } else {
    mustExec([...baseSign, '--preserve-metadata=entitlements', downloaderXpc], 'sign Downloader.xpc')
  }
  mustExec([...baseSign, autoupdate], 'sign Autoupdate')
  mustExec([...baseSign, updaterApp], 'sign Updater.app')
  mustExec([...baseSign, framework], 'sign Sparkle.framework')
  mustExec([...baseSign, '--entitlements', join(ROOT, 'Resources/Tovri.entitlements'), appPath], 'sign Tovri.app')
  mustExec(['codesign', '--verify', '--deep', '--strict', appPath], 'verify re-signed app')
}

function buildAppcastXml(version: string, zipUrl: string, zipBytes: number, edSignature: string): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tovri</title>
    <link>http://127.0.0.1/</link>
    <description>Tovri loopback update test</description>
    <language>en</language>
    <item>
      <title>Tovri ${version}</title>
      <pubDate>${new Date().toUTCString()}</pubDate>
      <sparkle:version>${buildNumber(version)}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${minimumMacOS(ROOT)}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <description><![CDATA[<p>Sparkle loopback verification build ${version}</p>]]></description>
      <enclosure url="${zipUrl}" length="${zipBytes}" type="application/octet-stream" sparkle:edSignature="${edSignature}"/>
    </item>
  </channel>
</rss>
`
}

function signFeedXml(signUpdatePath: string, privateSeedBase64: string, xmlPath: string, xml: string): string {
  writeFileSync(xmlPath, xml, 'utf8')
  mustExec([signUpdatePath, '--ed-key-file', '-', xmlPath], 'sign appcast XML', { input: privateSeedBase64 })
  mustExec([signUpdatePath, '--verify', '--ed-key-file', '-', xmlPath], 'verify signed appcast XML', {
    input: privateSeedBase64,
  })
  return readFileSync(xmlPath, 'utf8')
}

function clearSparkleState(appCacheDir: string, autoupdateCacheDir: string): void {
  exec(['defaults', 'delete', PREFS_DOMAIN])
  rmSync(appCacheDir, { recursive: true, force: true })
  rmSync(autoupdateCacheDir, { recursive: true, force: true })
}

function readReport(path: string): VerificationReport {
  if (!existsSync(path)) fail(`missing verification output JSON at ${path}`)
  return JSON.parse(readFileSync(path, 'utf8')) as VerificationReport
}

async function pollUntil(timeoutMs: number, intervalMs: number, predicate: () => boolean): Promise<boolean> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return true
    await Bun.sleep(intervalMs)
  }
  return predicate()
}

export function restoreSparkleState(ctx: RestoreContext, deps: RestoreDeps = {}): RestoreResult {
  const runDefaults = deps.runDefaults ?? ((args: string[]) => exec(['defaults', ...args]))
  const copyDir = deps.copyDir ?? cpSync
  const removePath = deps.removePath ?? rmSync
  const pathExists = deps.pathExists ?? existsSync
  const fileSize = deps.fileSize ?? ((path: string) => statSync(path).size)
  const errors: string[] = []

  // 1. Restore or remove user defaults.
  try {
    if (ctx.hadPrefs) {
      if (!pathExists(ctx.prefsBackup) || fileSize(ctx.prefsBackup) === 0) {
        errors.push(`preferences backup is missing or empty at ${ctx.prefsBackup}`)
      } else {
        const imp = runDefaults(['import', ctx.prefsDomain, ctx.prefsBackup])
        if (imp.status !== 0) {
          errors.push(`defaults import ${ctx.prefsDomain} failed (exit ${imp.status}): ${(imp.stderr || imp.stdout).trim()}`)
        } else {
          const verified = runDefaults(['export', ctx.prefsDomain, '-'])
          if (verified.status !== 0 || verified.stdout.length === 0) {
            errors.push(`preferences verification export failed for ${ctx.prefsDomain}`)
          }
        }
      }
    } else {
      if (runDefaults(['read', ctx.prefsDomain]).status === 0) {
        const del = runDefaults(['delete', ctx.prefsDomain])
        if (del.status !== 0) {
          errors.push(`defaults delete ${ctx.prefsDomain} failed (exit ${del.status}): ${(del.stderr || del.stdout).trim()}`)
        }
      }
      if (pathExists(ctx.prefsPlist)) {
        removePath(ctx.prefsPlist, { force: true })
      }
      if (runDefaults(['read', ctx.prefsDomain]).status === 0 || pathExists(ctx.prefsPlist)) {
        errors.push(`temporary preferences for ${ctx.prefsDomain} still remain after cleanup`)
      }
    }
  } catch (err) {
    errors.push(`preferences restoration threw: ${err instanceof Error ? err.message : String(err)}`)
  }

  // 2. Restore or remove Sparkle caches by copying (never moving) so backups remain intact on partial failure.
  const cacheEntries: Array<[string, string, boolean, string]> = [
    [ctx.appCacheDir, ctx.appCacheBackup, ctx.hadAppCache, 'app cache'],
    [ctx.autoupdateCacheDir, ctx.autoupdateCacheBackup, ctx.hadAutoupdateCache, 'Autoupdate cache'],
  ]
  for (const [targetDir, backupDir, hadOriginal, label] of cacheEntries) {
    try {
      if (hadOriginal) {
        if (!pathExists(backupDir)) {
          errors.push(`${label} backup is missing at ${backupDir}`)
          continue
        }
        removePath(targetDir, { recursive: true, force: true })
        copyDir(backupDir, targetDir, { recursive: true, verbatimSymlinks: true })
        if (!pathExists(targetDir)) {
          errors.push(`${label} missing at ${targetDir} after restore`)
        }
      } else {
        removePath(targetDir, { recursive: true, force: true })
        if (pathExists(targetDir)) {
          errors.push(`temporary ${label} still exists at ${targetDir}`)
        }
      }
    } catch (err) {
      errors.push(`${label} restoration failed: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  return { ok: errors.length === 0, errors }
}

export async function runWithProtection(
  options: {
    workDir: string
    backupDir: string
    restore: () => RestoreResult
  },
  body: (lifecycle: LifecycleContext) => Promise<void>,
): Promise<void> {
  let stateModified = false
  let activeChild: ReturnType<typeof Bun.spawn> | null = null
  let server: ReturnType<typeof Bun.serve> | null = null
  let finalized = false
  let finalizeResult: RestoreResult = { ok: true, errors: [] }

  const finalize = (): RestoreResult => {
    if (finalized) return finalizeResult
    finalized = true

    try {
      server?.stop(true)
    } catch {
      // Best-effort shutdown.
    }
    server = null

    if (activeChild) {
      try {
        activeChild.kill('SIGTERM')
      } catch {
        // Already exited.
      }
      activeChild = null
    }

    if (exec(['pgrep', '-f', options.workDir]).status === 0) {
      exec(['pkill', '-TERM', '-f', options.workDir])
      const deadline = Date.now() + 3_000
      while (Date.now() < deadline && exec(['pgrep', '-f', options.workDir]).status === 0) {
        sleepSyncMs(100)
      }
      if (exec(['pgrep', '-f', options.workDir]).status === 0) {
        exec(['pkill', '-KILL', '-f', options.workDir])
        sleepSyncMs(100)
      }
    }

    if (stateModified) {
      finalizeResult = options.restore()
      try {
        rmSync(options.workDir, { recursive: true, force: true })
      } catch {
        // Leave workDir cleanup best-effort; backupDir tracks the user state.
      }
      if (finalizeResult.ok) {
        try {
          rmSync(options.backupDir, { recursive: true, force: true })
        } catch (err) {
          finalizeResult = {
            ok: false,
            errors: [
              ...finalizeResult.errors,
              `failed to remove backup directory ${options.backupDir}: ${err instanceof Error ? err.message : String(err)}`,
            ],
          }
        }
      }
      if (!finalizeResult.ok) {
        for (const err of finalizeResult.errors) {
          console.error(`error: ${err}`)
        }
        console.error(`error: Sparkle state restoration failed; backups retained at ${options.backupDir}`)
      }
    } else {
      try {
        rmSync(options.workDir, { recursive: true, force: true })
      } catch {
        // Ignore workDir cleanup failure if live state was untouched.
      }
      try {
        rmSync(options.backupDir, { recursive: true, force: true })
      } catch {
        // Ignore backupDir cleanup failure if live state was untouched.
      }
    }

    return finalizeResult
  }

  const signalCodes: Record<string, number> = { SIGINT: 130, SIGTERM: 143, SIGHUP: 129 }
  const handlers = new Map<NodeJS.Signals, () => void>()
  const removeHandlers = (): void => {
    for (const [sig, handler] of handlers) {
      process.off(sig, handler)
    }
    handlers.clear()
  }

  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) {
    const handler = (): void => {
      removeHandlers()
      console.error(`\nInterrupted by ${sig}; restoring Sparkle state...`)
      const res = finalize()
      process.exit(res.ok ? (signalCodes[sig] ?? 1) : 1)
    }
    handlers.set(sig, handler)
    process.on(sig, handler)
  }

  let restoreAfterSuccess: RestoreResult = { ok: true, errors: [] }
  try {
    await body({
      markStateModified: () => {
        stateModified = true
      },
      trackChild: (proc) => {
        activeChild = proc
      },
      registerServer: (s) => {
        server = s
      },
    })
  } finally {
    removeHandlers()
    restoreAfterSuccess = finalize()
  }

  if (!restoreAfterSuccess.ok) {
    throw new HarnessError(
      `restoration failed; backups retained at ${options.backupDir}: ${restoreAfterSuccess.errors.join('; ')}`,
    )
  }
}

export async function runVerification(): Promise<void> {
  const uid = mustExec(['id', '-u'], 'id -u').stdout.trim()
  if (exec(['pgrep', '-x', '-U', uid, 'Tovri']).status === 0) {
    fail('Tovri is currently running; quit it before running live Sparkle update verification')
  }

  const home = process.env.HOME
  if (!home) fail('HOME is not set')
  const prefsPlist = join(home, 'Library/Preferences', `${PREFS_DOMAIN}.plist`)
  const appCacheDir = join(home, 'Library/Caches', PREFS_DOMAIN)
  const autoupdateCacheDir = join(home, 'Library/Caches/org.sparkle-project.Sparkle.Autoupdate')

  const workDir = realpathSync(mkdtempSync(join(tmpdir(), 'tovri-sparkle-work-')))
  const backupDir = realpathSync(mkdtempSync(join(tmpdir(), 'tovri-sparkle-backup-')))
  const prefsBackup = join(backupDir, 'prefs-backup.plist')
  const appCacheBackup = join(backupDir, 'app-cache-backup')
  const autoupdateCacheBackup = join(backupDir, 'autoupdate-cache-backup')

  const hadPrefs = exec(['defaults', 'read', PREFS_DOMAIN]).status === 0 || existsSync(prefsPlist)
  const hadAppCache = existsSync(appCacheDir)
  const hadAutoupdateCache = existsSync(autoupdateCacheDir)

  const restoreCtx: RestoreContext = {
    prefsDomain: PREFS_DOMAIN,
    prefsPlist,
    prefsBackup,
    hadPrefs,
    appCacheDir,
    appCacheBackup,
    hadAppCache,
    autoupdateCacheDir,
    autoupdateCacheBackup,
    hadAutoupdateCache,
  }

  await runWithProtection(
    {
      workDir,
      backupDir,
      restore: () => restoreSparkleState(restoreCtx),
    },
    async (lifecycle) => {
      if (hadPrefs) {
        mustExec(['defaults', 'export', PREFS_DOMAIN, prefsBackup], 'export existing prefs')
        if (!existsSync(prefsBackup) || statSync(prefsBackup).size === 0) {
          fail(`exported preferences backup missing or empty at ${prefsBackup}`)
        }
      }
      if (hadAppCache) {
        cpSync(appCacheDir, appCacheBackup, { recursive: true, verbatimSymlinks: true })
        if (!existsSync(appCacheBackup)) {
          fail(`failed to copy app cache backup to ${appCacheBackup}`)
        }
      }
      if (hadAutoupdateCache) {
        cpSync(autoupdateCacheDir, autoupdateCacheBackup, { recursive: true, verbatimSymlinks: true })
        if (!existsSync(autoupdateCacheBackup)) {
          fail(`failed to copy Autoupdate cache backup to ${autoupdateCacheBackup}`)
        }
      }
      writeFileSync(join(backupDir, 'manifest.json'), JSON.stringify(restoreCtx, null, 2), 'utf8')

      const execAsync = async (command: string[]): Promise<ExecResult> => {
        const proc = Bun.spawn(command, {
          cwd: ROOT,
          stdout: 'pipe',
          stderr: 'pipe',
        })
        lifecycle.trackChild(proc)
        try {
          const [stdout, stderr, status] = await Promise.all([
            new Response(proc.stdout).text(),
            new Response(proc.stderr).text(),
            proc.exited,
          ])
          return { status, stdout, stderr }
        } finally {
          lifecycle.trackChild(null)
        }
      }

      // Ephemeral Ed25519 keypair in memory only (matches Sparkle's 32-byte seed & 32-byte SPKI formats).
      const { publicKey, privateKey } = generateKeyPairSync('ed25519')
      const pubBase64 = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64')
      const privSeedBase64 = privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32).toString('base64')
      checkKeys({ SPARKLE_PUBLIC_KEY: pubBase64, SPARKLE_PRIVATE_KEY: privSeedBase64 })

      const signUpdatePath = join(ROOT, SIGN_UPDATE)

      // 1. Build target 0.6.2 bundle into its own dedicated directory and archive it.
      const v062Dir = join(workDir, 'v062')
      mkdirSync(v062Dir, { recursive: true })
      mustExec([join(ROOT, 'scripts/build.sh'), '--version', '0.6.2', '--output-dir', v062Dir], 'build 0.6.2', {
        env: { TOVRI_UPDATE_KEY: pubBase64 },
      })
      const v062App = join(v062Dir, 'Tovri.app')
      const zipPath = join(workDir, 'Tovri-0.6.2.zip')
      mustExec(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', 'Tovri.app', zipPath], 'zip 0.6.2', {
        cwd: v062Dir,
      })
      const zipBytes = statSync(zipPath).size
      const validZipSig = sign(zipPath, { SPARKLE_PRIVATE_KEY: privSeedBase64 })

      // 2. Build base 0.6.1 bundle into its own dedicated directory before modifying live Sparkle state.
      const installedDir = join(workDir, 'installed')
      mkdirSync(installedDir, { recursive: true })
      mustExec([join(ROOT, 'scripts/build.sh'), '--version', '0.6.1', '--output-dir', installedDir], 'build 0.6.1', {
        env: { TOVRI_UPDATE_KEY: pubBase64 },
      })
      const installedApp = join(installedDir, 'Tovri.app')

      // Check 1: Unmodified production bundle refuses --verify-sparkle-update (feed host is github.com).
      lifecycle.markStateModified()
      const guardOut = join(workDir, 'guard.json')
      const guardRes = await execAsync([join(v062App, 'Contents/MacOS/Tovri'), '--verify-sparkle-update', guardOut])
      if (guardRes.status !== 2) {
        fail(`expected production bundle guard exit 2, got ${guardRes.status}: ${guardRes.stderr}`)
      }
      const guardReport = readReport(guardOut)
      if (guardReport.ok || guardReport.stage !== 'refused') {
        fail(`unexpected production guard report: ${JSON.stringify(guardReport)}`)
      }
      console.log('✓ Check 1: production bundle refuses --verify-sparkle-update (exit 2)')

      // 3. Start local loopback HTTP server serving appcast.xml and Tovri-0.6.2.zip.
      let currentAppcastXml = ''
      let zipRequests = 0
      const server = Bun.serve({
        hostname: '127.0.0.1',
        port: 0,
        fetch(req) {
          const pathname = new URL(req.url).pathname
          if (pathname === '/appcast.xml') {
            return new Response(currentAppcastXml, {
              headers: { 'content-type': 'application/xml; charset=utf-8' },
            })
          }
          if (pathname === '/Tovri-0.6.2.zip') {
            zipRequests += 1
            return new Response(Bun.file(zipPath), {
              headers: { 'content-type': 'application/octet-stream' },
            })
          }
          return new Response('Not found', { status: 404 })
        },
      })
      lifecycle.registerServer(server)

      const baseUrl = `http://127.0.0.1:${server.port}`
      const feedUrl = `${baseUrl}/appcast.xml`
      const zipUrl = `${baseUrl}/Tovri-0.6.2.zip`

      // Patch staged 0.6.1 Info.plist & Downloader.xpc to allow loopback HTTP feed, then re-sign inside-out.
      const installedPlist = join(installedApp, 'Contents/Info.plist')
      const downloaderPlist = join(
        installedApp,
        'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/Info.plist',
      )
      plistSetOrAddString(installedPlist, 'SUFeedURL', feedUrl)
      plistSetLocalNetworking(installedPlist)
      plistSetLocalNetworking(downloaderPlist)
      mustExec(['plutil', '-lint', installedPlist], 'lint patched Info.plist')
      mustExec(['plutil', '-lint', downloaderPlist], 'lint patched Downloader.xpc Info.plist')
      const identity = detectSigningIdentity()
      resignApp(installedApp, identity, workDir)

      const installedBin = join(installedApp, 'Contents/MacOS/Tovri')

      // Check 2: Unsigned appcast feed must be rejected when SURequireSignedFeed=true.
      clearSparkleState(appCacheDir, autoupdateCacheDir)
      currentAppcastXml = buildAppcastXml('0.6.2', zipUrl, zipBytes, validZipSig)
      const unsignedOut = join(workDir, 'unsigned-feed.json')
      const unsignedRes = await execAsync([installedBin, '--verify-sparkle-update', unsignedOut])
      if (unsignedRes.status !== 1) {
        fail(`expected unsigned feed check exit 1, got ${unsignedRes.status}: ${unsignedRes.stderr}`)
      }
      const unsignedReport = readReport(unsignedOut)
      if (unsignedReport.ok) fail(`unsigned feed unexpectedly succeeded: ${JSON.stringify(unsignedReport)}`)
      if (plistGet(installedPlist, 'CFBundleShortVersionString') !== '0.6.1') {
        fail('installed bundle mutated after unsigned feed failure')
      }
      await pollUntil(10_000, 100, () => exec(['pgrep', '-f', workDir]).status !== 0)
      console.log(`✓ Check 2: unsigned appcast feed rejected (${unsignedReport.error ?? unsignedReport.stage})`)

      // Check 3: Signed feed with tampered enclosure EdDSA signature must be rejected before installation.
      clearSparkleState(appCacheDir, autoupdateCacheDir)
      const corruptedSig = (validZipSig.startsWith('A') ? 'B' : 'A') + validZipSig.slice(1)
      const badXml = buildAppcastXml('0.6.2', zipUrl, zipBytes, corruptedSig)
      currentAppcastXml = signFeedXml(signUpdatePath, privSeedBase64, join(workDir, 'appcast-bad.xml'), badXml)
      const badSigOut = join(workDir, 'bad-sig.json')
      const badSigRes = await execAsync([installedBin, '--verify-sparkle-update', badSigOut])
      if (badSigRes.status !== 1) {
        fail(`expected corrupted archive signature exit 1, got ${badSigRes.status}: ${badSigRes.stderr}`)
      }
      const badSigReport = readReport(badSigOut)
      if (badSigReport.ok) fail(`corrupted enclosure signature unexpectedly succeeded: ${JSON.stringify(badSigReport)}`)
      if (plistGet(installedPlist, 'CFBundleShortVersionString') !== '0.6.1') {
        fail('installed bundle mutated after bad archive signature')
      }
      await pollUntil(10_000, 100, () => exec(['pgrep', '-f', workDir]).status !== 0)
      console.log(`✓ Check 3: tampered enclosure EdDSA signature rejected (${badSigReport.error ?? badSigReport.stage})`)

      // Check 4: Valid signed appcast + signed 0.6.2 ZIP downloads, verifies, installs on disk, and passes strict codesign.
      clearSparkleState(appCacheDir, autoupdateCacheDir)
      zipRequests = 0
      const goodXml = buildAppcastXml('0.6.2', zipUrl, zipBytes, validZipSig)
      currentAppcastXml = signFeedXml(signUpdatePath, privSeedBase64, join(workDir, 'appcast-good.xml'), goodXml)
      const okOut = join(workDir, 'ok.json')
      const okRes = await execAsync([installedBin, '--verify-sparkle-update', okOut])
      if (okRes.status !== 0) {
        const reportText = existsSync(okOut) ? readFileSync(okOut, 'utf8') : '(no report JSON written)'
        fail(
          `expected valid Sparkle update run exit 0, got ${okRes.status}:\nreport=${reportText}\nstderr=${okRes.stderr}\nstdout=${okRes.stdout}`,
        )
      }
      const okReport = readReport(okOut)
      if (
        !okReport.ok ||
        okReport.stage !== 'readyToInstall' ||
        okReport.foundVersion !== '0.6.2' ||
        okReport.foundBuild !== '602' ||
        okReport.downloadedBytes !== zipBytes ||
        !okReport.extracted ||
        zipRequests < 1
      ) {
        fail(
          `unexpected loopback update report: ${JSON.stringify(okReport)} (zipRequests=${zipRequests}, zipBytes=${zipBytes})`,
        )
      }

      const updated = await pollUntil(20_000, 200, () => {
        if (!existsSync(installedPlist)) return false
        const ver = exec(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', installedPlist]).stdout.trim()
        const bld = exec(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion', installedPlist]).stdout.trim()
        return ver === '0.6.2' && bld === '602'
      })
      if (!updated) {
        const actual = existsSync(installedPlist) ? plistGet(installedPlist, 'CFBundleShortVersionString') : 'missing'
        fail(`Sparkle Autoupdate did not replace 0.6.1 with 0.6.2 within timeout (current=${actual})`)
      }

      await pollUntil(10_000, 200, () => exec(['pgrep', '-f', workDir]).status !== 0)

      mustExec(['codesign', '--verify', '--deep', '--strict', installedApp], 'verify updated 0.6.2 bundle signature')
      const postOut = join(workDir, 'post-update.json')
      const postRes = await execAsync([join(installedApp, 'Contents/MacOS/Tovri'), '--verify-sparkle-update', postOut])
      if (postRes.status !== 2) {
        fail(`expected updated unmodified 0.6.2 bundle to refuse loopback flag (exit 2), got ${postRes.status}`)
      }
      console.log(
        `✓ Check 4: Sparkle live update 0.6.1 (601) -> 0.6.2 (602) installed ${zipBytes} bytes via SPUUpdater + Autoupdate and passed codesign --verify --deep --strict`,
      )
    },
  )
}

if (import.meta.main) {
  try {
    await runVerification()
  } catch (err) {
    console.error(`error: ${err instanceof Error ? err.message : String(err)}`)
    process.exit(1)
  }
}
