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

interface ExecResult {
  status: number
  stdout: string
  stderr: string
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

const PREFS_DOMAIN = 'app.tovri.Tovri'

function fail(message: string): never {
  console.error(`error: ${message}`)
  process.exit(1)
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

async function execAsync(command: string[]): Promise<ExecResult> {
  const proc = Bun.spawn(command, {
    cwd: ROOT,
    stdout: 'pipe',
    stderr: 'pipe',
  })
  const [stdout, stderr, status] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  return { status, stdout, stderr }
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

function buildAppcastXml(
  version: string,
  zipUrl: string,
  zipBytes: number,
  edSignature: string,
): string {
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

async function main(): Promise<void> {
  const uid = mustExec(['id', '-u'], 'id -u').stdout.trim()
  if (exec(['pgrep', '-x', '-U', uid, 'Tovri']).status === 0) {
    fail('Tovri is currently running; quit it before running live Sparkle update verification')
  }

  const home = process.env.HOME
  if (!home) fail('HOME is not set')
  const prefsPlist = join(home, 'Library/Preferences', `${PREFS_DOMAIN}.plist`)
  const appCacheDir = join(home, 'Library/Caches', PREFS_DOMAIN)
  const autoupdateCacheDir = join(home, 'Library/Caches/org.sparkle-project.Sparkle.Autoupdate')

  const workDir = realpathSync(mkdtempSync(join(tmpdir(), 'tovri-sparkle-verify-')))
  const prefsBackup = join(workDir, 'prefs-backup.plist')
  const appCacheBackup = join(workDir, 'app-cache-backup')
  const autoupdateCacheBackup = join(workDir, 'autoupdate-cache-backup')

  const hadPrefs = existsSync(prefsPlist)
  if (hadPrefs) mustExec(['defaults', 'export', PREFS_DOMAIN, prefsBackup], 'export existing prefs')
  const hadAppCache = existsSync(appCacheDir)
  if (hadAppCache) cpSync(appCacheDir, appCacheBackup, { recursive: true, verbatimSymlinks: true })
  const hadAutoupdateCache = existsSync(autoupdateCacheDir)
  if (hadAutoupdateCache) cpSync(autoupdateCacheDir, autoupdateCacheBackup, { recursive: true, verbatimSymlinks: true })

  let server: ReturnType<typeof Bun.serve> | null = null

  try {
    // Ephemeral Ed25519 keypair in memory only (matches Sparkle's 32-byte seed & 32-byte SPKI formats).
    const { publicKey, privateKey } = generateKeyPairSync('ed25519')
    const pubBase64 = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64')
    const privSeedBase64 = privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32).toString('base64')
    checkKeys({ SPARKLE_PUBLIC_KEY: pubBase64, SPARKLE_PRIVATE_KEY: privSeedBase64 })

    const signUpdatePath = join(ROOT, SIGN_UPDATE)
    const buildOutputApp = join(ROOT, 'build/Release/Tovri.app')

    // 1. Build target 0.6.2 bundle & archive it.
    mustExec([join(ROOT, 'scripts/build.sh'), '--version', '0.6.2'], 'build 0.6.2', {
      env: { TOVRI_UPDATE_KEY: pubBase64 },
    })
    const v062Dir = join(workDir, 'v062')
    const v062App = join(v062Dir, 'Tovri.app')
    mkdirSync(v062Dir, { recursive: true })
    mustExec(['ditto', buildOutputApp, v062App], 'stage 0.6.2 bundle')
    const zipPath = join(workDir, 'Tovri-0.6.2.zip')
    mustExec(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', 'Tovri.app', zipPath], 'zip 0.6.2', {
      cwd: v062Dir,
    })
    const zipBytes = statSync(zipPath).size
    const validZipSig = sign(zipPath, { SPARKLE_PRIVATE_KEY: privSeedBase64 })

    // Check 1: Unmodified production bundle must refuse --verify-sparkle-update (feed host is github.com).
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

    // 2. Build base 0.6.1 bundle and stage a clean copy for loopback update testing.
    mustExec([join(ROOT, 'scripts/build.sh'), '--version', '0.6.1'], 'build 0.6.1', {
      env: { TOVRI_UPDATE_KEY: pubBase64 },
    })
    const installedDir = join(workDir, 'installed')
    const installedApp = join(installedDir, 'Tovri.app')
    mkdirSync(installedDir, { recursive: true })
    mustExec(['ditto', buildOutputApp, installedApp], 'stage 0.6.1 bundle')

    // 3. Start local loopback HTTP server serving appcast.xml and Tovri-0.6.2.zip.
    let currentAppcastXml = ''
    let zipRequests = 0
    server = Bun.serve({
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
    // Wait for Check 3's transient Autoupdate/Updater helpers (and their -spks Mach port) to exit cleanly.
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
      fail(`unexpected loopback update report: ${JSON.stringify(okReport)} (zipRequests=${zipRequests}, zipBytes=${zipBytes})`)
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

    // Wait for Sparkle Autoupdate/Updater helper processes tied to workDir to exit cleanly.
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
  } finally {
    server?.stop(true)
    if (hadPrefs && existsSync(prefsBackup)) {
      exec(['defaults', 'import', PREFS_DOMAIN, prefsBackup])
    } else {
      exec(['defaults', 'delete', PREFS_DOMAIN])
    }
    rmSync(appCacheDir, { recursive: true, force: true })
    if (hadAppCache && existsSync(appCacheBackup)) {
      cpSync(appCacheBackup, appCacheDir, { recursive: true, verbatimSymlinks: true })
    }
    rmSync(autoupdateCacheDir, { recursive: true, force: true })
    if (hadAutoupdateCache && existsSync(autoupdateCacheBackup)) {
      cpSync(autoupdateCacheBackup, autoupdateCacheDir, { recursive: true, verbatimSymlinks: true })
    }
    rmSync(join(ROOT, 'build'), { recursive: true, force: true })
    rmSync(join(ROOT, 'dist'), { recursive: true, force: true })
    rmSync(workDir, { recursive: true, force: true })
  }
}

await main()
