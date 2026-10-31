// Release gates must reject inconsistent versions and unusable update keys.
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

import {
  type Run,
  buildNumber,
  checkKeys,
  checkVersion,
  minimumMacOS,
  section,
  sign,
  toHtml,
  unwrap,
} from '../release-notes'

const SCRIPTS = resolve(import.meta.dir, '..')

function infoPlist(entries: Record<string, string>): string {
  const body = Object.entries(entries)
    .map(([key, value]) => `\t<key>${key}</key>\n\t<string>${value}</string>\n`)
    .join('')
  return `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n${body}</dict>\n</plist>\n`
}

describe('release versions', () => {
  let root = ''

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'tovri-release-'))
    mkdirSync(join(root, 'Resources'))
    writeFileSync(
      join(root, 'Resources/Info.plist'),
      infoPlist({ CFBundleShortVersionString: '0.1.0', CFBundleVersion: '1', LSMinimumSystemVersion: '14.0' }),
    )
    writeFileSync(join(root, 'Package.swift'), 'let package = Package(\n    platforms: [.macOS(.v14)],\n)\n')
    writeFileSync(join(root, 'CHANGELOG.md'), '## [0.1.0] - 2026-11-01\n\n- First release.\n')
  })
  afterEach(() => rmSync(root, { recursive: true, force: true }))

  test('consistent metadata passes', () => {
    checkVersion('0.1.0', root)
  })

  test('Info.plist must match the tag', () => {
    const path = join(root, 'Resources/Info.plist')
    writeFileSync(path, readFileSync(path, 'utf8').replace('0.1.0', '0.2.0'))
    expect(() => checkVersion('0.1.0', root)).toThrow('Resources/Info.plist')
  })

  test('a version recorded twice is rejected', () => {
    const path = join(root, 'Resources/Info.plist')
    writeFileSync(path, readFileSync(path, 'utf8').replace('</dict>', infoPlist({ CFBundleShortVersionString: '0.1.0' })))
    expect(() => checkVersion('0.1.0', root)).toThrow('once')
  })

  test.each(['## [Unreleased]\n', '## [0.1.0]\n\n'])('missing or empty release notes are rejected: %j', (changelog) => {
    writeFileSync(join(root, 'CHANGELOG.md'), changelog)
    expect(() => checkVersion('0.1.0', root)).toThrow()
  })

  test('a version never matches the section of a longer one', () => {
    writeFileSync(
      join(root, 'CHANGELOG.md'),
      '## [Unreleased]\n\n## [0.1.10] - 2026-11-20\n\n- Ten.\n\n## [0.1.1-beta]\n\n- Beta.\n\n## [0.1.1] - 2026-11-10\n\n- One.\n\n[0.1.1]: https://example.com\n',
    )
    expect(section('0.1.1', root)).toBe('- One.')
    expect(section('0.1.10', root)).toBe('- Ten.')
    expect(() => section('0.1.0', root)).toThrow('no section for 0.1.0')
  })

  test('the minimum macOS comes from Info.plist and must match Package.swift', () => {
    expect(minimumMacOS(root)).toBe('14.0')
    writeFileSync(join(root, 'Package.swift'), 'platforms: [.macOS(.v15)]\n')
    expect(() => checkVersion('0.1.0', root)).toThrow('Package.swift targets macOS 15.0')
    writeFileSync(join(root, 'Resources/Info.plist'), infoPlist({ CFBundleShortVersionString: '0.1.0' }))
    expect(() => checkVersion('0.1.0', root)).toThrow('LSMinimumSystemVersion')
  })

  test('build numbers increase at version boundaries', () => {
    expect(buildNumber('0.1.0')).toBe(100)
    expect(buildNumber('0.1.99')).toBeLessThan(buildNumber('0.2.0'))
    expect(buildNumber('0.99.99')).toBeLessThan(buildNumber('1.0.0'))
  })

  test.each(['01.2.3', '0.08.0', '1.100.0', '1.2.100', '1.2.3-beta', '1.2'])(
    'ambiguous and out of range versions are rejected: %s',
    (version) => {
      expect(() => buildNumber(version)).toThrow()
      for (const command of [
        [join(SCRIPTS, 'build.sh'), '--version', version],
        [join(SCRIPTS, 'bump-version.sh'), version],
      ]) {
        const [script = '', ...args] = command
        const result = spawnSync(script, args, { encoding: 'utf8' })
        expect(result.status, result.stderr).toBe(2)
      }
    },
  )
})

describe('release notes', () => {
  test('wrapped lines are joined for GitHub', () => {
    const markdown =
      'The first public release.\n\n### Editing\n\n' +
      '- Multiple cursors, column selection and\n  line commands.\n' +
      '- Code folding.\n\n' +
      'A paragraph that\nwraps onto two lines.\n'
    expect(unwrap(markdown)).toBe(
      'The first public release.\n\n### Editing\n\n' +
        '- Multiple cursors, column selection and line commands.\n' +
        '- Code folding.\n\n' +
        'A paragraph that wraps onto two lines.',
    )
  })
})

describe('release notes HTML', () => {
  test('wrapped list items stay inside their item', () => {
    expect(toHtml('### Fixes\n\n- One that\n  wraps.\n- Two that\nwraps lazily.\n\nAfter.')).toBe(
      '<h3>Fixes</h3>\n<ul>\n<li>One that wraps.</li>\n<li>Two that wraps lazily.</li>\n</ul>\n<p>After.</p>',
    )
  })

  test('text is escaped and inline markup is kept', () => {
    expect(toHtml('- **Bold** `a < b` & [link](https://github.com/rahatsagor/Tovri) <script>')).toBe(
      '<ul>\n<li><strong>Bold</strong> <code>a &lt; b</code> &amp; <a href="https://github.com/rahatsagor/Tovri">link</a> &lt;script&gt;</li>\n</ul>',
    )
  })
})

describe('the real changelog', () => {
  test('the current version has release notes', () => {
    const plist = readFileSync(join(SCRIPTS, '../Resources/Info.plist'), 'utf8')
    const version = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(plist)?.[1] ?? ''
    checkVersion(version, resolve(SCRIPTS, '..'))
  })
})

describe('Sparkle keys', () => {
  function keys(legacy = false) {
    // RFC 8032 section 7.1, test 1 (public test vector, not a release key).
    const seed = Buffer.from('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', 'hex')
    const publicKey = Buffer.from('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', 'hex')
    let privateKey = seed
    if (legacy) {
      const expanded = createHash('sha512').update(seed).digest()
      expanded[0] = expanded[0]! & 248
      expanded[31] = (expanded[31]! & 63) | 64
      privateKey = Buffer.concat([expanded, publicKey])
    }
    return { SPARKLE_PUBLIC_KEY: publicKey.toString('base64'), SPARKLE_PRIVATE_KEY: privateKey.toString('base64') }
  }

  test.each([false, true])('current and legacy exports are accepted (legacy: %p)', (legacy) => {
    checkKeys(keys(legacy))
  })

  test('mismatched keys are rejected without printing the secret', () => {
    const env = { ...keys(), SPARKLE_PUBLIC_KEY: Buffer.alloc(32).toString('base64') }
    let message = ''
    try {
      checkKeys(env)
    } catch (error) {
      message = (error as Error).message
    }
    expect(message).toContain('do not match')
    expect(message).not.toContain(env.SPARKLE_PRIVATE_KEY)
  })

  test('missing, malformed and wrong length keys are rejected', () => {
    const invalid: Record<string, string>[] = [
      {},
      { SPARKLE_PUBLIC_KEY: 'not base64!', SPARKLE_PRIVATE_KEY: 'bad' },
      { ...keys(), SPARKLE_PRIVATE_KEY: Buffer.alloc(64).toString('base64') },
      { ...keys(), SPARKLE_PUBLIC_KEY: `${keys().SPARKLE_PUBLIC_KEY}\n` },
    ]
    for (const env of invalid) {
      expect(() => checkKeys(env), Object.keys(env).join()).toThrow()
    }
  })

  test('the build accepts only a valid public key', () => {
    const result = spawnSync(join(SCRIPTS, 'build.sh'), ['--version', '0.1.0'], {
      encoding: 'utf8',
      env: { ...process.env, TOVRI_UPDATE_KEY: `${keys().SPARKLE_PUBLIC_KEY.slice(0, -2)}=` },
    })
    expect(result.status, result.stderr).toBe(2)
    expect(result.stderr).toContain('TOVRI_UPDATE_KEY')
  })

  test('the archive signature is verified before use', () => {
    const signature = Buffer.alloc(64).toString('base64')
    const calls: { command: string[]; input?: string }[] = []
    const results = [
      { status: 0, stdout: `${signature}\n`, stderr: '' },
      { status: 0, stdout: '', stderr: '' },
    ]
    const exec: Run = (command, input) => {
      calls.push({ command, input })
      return results.shift()!
    }
    const env = { SPARKLE_SIGN_UPDATE: '/sparkle/sign_update', ...keys() }
    expect(sign('Tovri.zip', env, exec)).toBe(signature)
    expect(calls[1]?.command).toEqual(['/sparkle/sign_update', '--ed-key-file', '-', '--verify', 'Tovri.zip', signature])
    expect(calls[1]?.input).toBe(env.SPARKLE_PRIVATE_KEY)
  })

  test('the Keychain account is used without a private key', () => {
    const calls: string[][] = []
    const exec: Run = (command) => {
      calls.push(command)
      return { status: 0, stdout: 'signature', stderr: '' }
    }
    sign('Tovri.zip', { SPARKLE_SIGN_UPDATE: '/sparkle/sign_update' }, exec)
    expect(calls[0]?.slice(1, 3)).toEqual(['--account', 'tovri'])
  })

  test('a failed archive verification stops the release', () => {
    const results = [
      { status: 0, stdout: 'signature', stderr: '' },
      { status: 1, stdout: '', stderr: 'invalid signature' },
    ]
    const exec: Run = () => results.shift()!
    expect(() => sign('Tovri.zip', { SPARKLE_SIGN_UPDATE: '/sparkle/sign_update' }, exec)).toThrow(
      'archive signature verification failed',
    )
  })
})
