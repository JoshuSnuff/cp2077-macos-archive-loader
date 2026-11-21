'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');

const repositoryDir = path.resolve(__dirname, '..');
const hooksPath = path.join(repositoryDir, 'gamefiles/red4ext/red4ext_hooks.js');
const addressesPath = path.join(
    repositoryDir,
    'gamefiles/red4ext/cyberpunk2077_addresses.json'
);
const source = fs.readFileSync(hooksPath, 'utf8');
const gateCase = process.env.RED4EXT_GATE_CASE || 'all';

const EXPECTED_UUID = '1dfa005c-ed12-306f-b349-67be555f2f72';

function makeExecutable(filePath) {
    const bytes = Buffer.alloc(128, 0);
    bytes.writeUInt32LE(0xfeedfacf, 0);
    bytes.writeInt32LE(0x0100000c, 4);
    bytes.writeInt32LE(0, 8);
    bytes.writeUInt32LE(2, 12);
    bytes.writeUInt32LE(1, 16);
    bytes.writeUInt32LE(24, 20);
    bytes.writeUInt32LE(0, 24);
    bytes.writeUInt32LE(0, 28);
    bytes.writeUInt32LE(0x1b, 32);
    bytes.writeUInt32LE(24, 36);
    Buffer.from(EXPECTED_UUID.replaceAll('-', ''), 'hex').copy(bytes, 40);
    fs.writeFileSync(filePath, bytes);
}

function fixture(overrides = {}) {
    const gameDir = fs.mkdtempSync(path.join(os.tmpdir(), 'red4ext-runtime-gate.'));
    const executablePath = path.join(
        gameDir,
        'Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077'
    );
    fs.mkdirSync(path.dirname(executablePath), { recursive: true });
    fs.mkdirSync(path.join(gameDir, 'Contents/Resources'), { recursive: true });
    fs.mkdirSync(path.join(gameDir, 'archive-loader/compatibility'), { recursive: true });
    makeExecutable(executablePath);

    fs.writeFileSync(
        path.join(gameDir, 'Cyberpunk2077.app/Contents/Info.plist'),
        `<?xml version="1.0"?><plist><dict>
        <key>CFBundleShortVersionString</key><string>2.5.0</string>
        <key>CFBundleVersion</key><string>5814786</string>
        </dict></plist>`
    );
    fs.writeFileSync(
        path.join(
            gameDir,
            'Contents/Resources/goggame-1423049311.info'
        ),
        JSON.stringify({ buildId: '60152051833789151' })
    );
    // A root-level file is deliberately present as a decoy. It is never an
    // authoritative fallback for the Resources metadata.
    fs.writeFileSync(
        path.join(gameDir, 'goggame-1423049311.info'),
        JSON.stringify({ buildId: '60152051833789151' })
    );

    const manifest = {
        schema: 'cp2077-compatibility/v1',
        target: {
            game: 'Cyberpunk 2077',
            distribution: 'gog',
            platform: 'macos',
            architecture: 'arm64',
            version: '2.5.0',
            bundleVersion: '5814786',
            gogBuildId: '60152051833789151',
            executable: {
                path: 'Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077',
                uuid: EXPECTED_UUID,
                sha256: crypto.createHash('sha256').update(fs.readFileSync(executablePath)).digest('hex')
            }
        },
        metadataSources: {
            version: {
                path: 'Cyberpunk2077.app/Contents/Info.plist',
                key: 'CFBundleShortVersionString'
            },
            bundleVersion: {
                path: 'Cyberpunk2077.app/Contents/Info.plist',
                key: 'CFBundleVersion'
            },
            gogBuildId: {
                path: 'Contents/Resources/goggame-1423049311.info',
                key: 'buildId'
            },
            architecture: {
                path: 'Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077',
                command: 'lipo -archs'
            },
            executableUuid: {
                path: 'Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077',
                command: 'otool -arch arm64 -l',
                loadCommand: 'LC_UUID'
            },
            executableSha256: {
                path: 'Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077',
                command: 'shasum -a 256'
            }
        }
    };
    Object.assign(manifest.target, overrides.target || {});
    if (overrides.executable) {
        Object.assign(manifest.target.executable, overrides.executable);
    }
    fs.writeFileSync(
        path.join(gameDir, 'archive-loader/compatibility/manifest.json'),
        JSON.stringify(manifest)
    );
    return {
        gameDir,
        executablePath,
        supportedTarget: {
            schema: manifest.schema,
            architecture: manifest.target.architecture,
            version: manifest.target.version,
            bundleVersion: manifest.target.bundleVersion,
            gogBuildId: manifest.target.gogBuildId,
            executablePath: manifest.target.executable.path,
            uuid: manifest.target.executable.uuid,
            sha256: manifest.target.executable.sha256
        }
    };
}

function runHooks(testFixture) {
    const calls = { attach: 0, replace: 0, exits: [], logs: [] };
    const runtime = {
        executablePath: testFixture.executablePath,
        architecture: 'arm64',
        supportedTarget: testFixture.supportedTarget,
        readText: (filePath) => fs.readFileSync(filePath, 'utf8'),
        readBytes: (filePath) => new Uint8Array(fs.readFileSync(filePath)),
        exit: (status) => {
            calls.exits.push(status);
            throw new Error(`TEST_EXIT_${status}`);
        }
    };
    const context = {
        __RED4EXT_TEST_RUNTIME__: runtime,
        console: { log: (message) => calls.logs.push(String(message)) },
        Interceptor: {
            attach: () => { calls.attach += 1; },
            replace: () => { calls.replace += 1; }
        },
        Process: {
            enumerateModules: () => [{ name: 'Cyberpunk2077', base: { add: () => ({}) } }]
        },
        rpc: { exports: {} }
    };

    try {
        vm.runInNewContext(source, context, { filename: hooksPath });
    } catch (error) {
        if (!String(error.message).startsWith('TEST_EXIT_')) throw error;
    }
    return calls;
}

if (gateCase === 'all' || gateCase === 'missing') {
    const missing = fixture();
    fs.rmSync(
        path.join(
            missing.gameDir,
            'Contents/Resources/goggame-1423049311.info'
        )
    );
    const calls = runHooks(missing);
    assert.deepStrictEqual(
        calls.exits,
        [78],
        'missing Resources metadata must not fall back to the root-level decoy'
    );
    assert.strictEqual(calls.attach, 0, 'missing Resources metadata must fail before hooks');
    assert.strictEqual(calls.replace, 0, 'missing Resources metadata must fail before replacement');
}

if (gateCase === 'all' || gateCase === 'mismatch') {
    const mismatched = fixture();
    fs.writeFileSync(
        path.join(
            mismatched.gameDir,
            'Contents/Resources/goggame-1423049311.info'
        ),
        JSON.stringify({ buildId: 'wrong-build' })
    );
    const calls = runHooks(mismatched);
    assert.deepStrictEqual(
        calls.exits,
        [78],
        'a mismatched Resources build ID must not be hidden by the root-level decoy'
    );
    assert.strictEqual(calls.attach, 0, 'a mismatched build ID must fail before hooks');
    assert.strictEqual(calls.replace, 0, 'a mismatched build ID must fail before replacement');
}

{
    const bad = fixture({ executable: { sha256: '0'.repeat(64) } });
    const calls = runHooks(bad);
    assert.deepStrictEqual(calls.exits, [78], 'a SHA mismatch must terminate the process');
    assert.strictEqual(calls.attach, 0, 'a SHA mismatch must occur before hook registration');
    assert.strictEqual(calls.replace, 0, 'a SHA mismatch must occur before shutdown replacement');
}

{
    const good = fixture();
    const calls = runHooks(good);
    assert.deepStrictEqual(
        calls.exits,
        [],
        `matching identity must pass the runtime gate: ${calls.logs.join(' | ')}`
    );
    assert.strictEqual(calls.attach, 0, 'offline-only game hooks must remain disabled');
    assert.strictEqual(calls.replace, 0, 'offline-only shutdown replacement must remain disabled');
}

{
    const database = JSON.parse(fs.readFileSync(addressesPath, 'utf8'));
    assert.strictEqual(database.game_version, '2.5.0');
    assert.strictEqual(database.binary_uuid, EXPECTED_UUID);
    assert.deepStrictEqual(database.stats, { total: 8, resolved: 0, unresolved: 8 });
    assert.strictEqual(database.Addresses.length, 0, 'unverified offsets must not be resolvable');
    assert.strictEqual(database.unresolved.length, 8);
    assert(database.unresolved.every((entry) => entry.enabled === false));
    assert(database.unresolved.every((entry) => entry.offset === '1:0x0'));
}

console.log('RED4ext runtime gate test passed');
