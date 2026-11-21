/**
 * RED4ext Hooks for macOS - Frida Gadget Implementation
 * 
 * This script implements the RED4ext hook system using Frida's Interceptor API,
 * bypassing Apple Silicon's W^X enforcement through JIT-based trampolines.
 * 
 * @version 1.2.0-offline
 * @author RED4ext macOS Port
 */

'use strict';

// ============================================================================
// Configuration
// ============================================================================

const CONFIG = {
    // Log level: 0=errors only, 1=info, 2=debug, 3=trace
    logLevel: 1,
    
    // Log prefix for all messages
    logPrefix: '[RED4ext-Frida]',
    
    // Module name to hook (main game executable)
    targetModule: 'Cyberpunk2077',

    // No 2.5.0 offset has matching production runtime evidence. The static
    // audit is useful for candidate discovery, but it is not permission to
    // attach a hook. Keep every entry disabled until a trace from this exact
    // executable identity is reviewed.
    shutdownGuardEnabled: false,
    
    // Hook offsets from __TEXT segment base
    hooks: {
        // Main function - App startup/shutdown
        0x0E54032B: { name: 'Main', offset: 0x0, enabled: false },
        
        // CGameApplication::AddState - Game state management
        0xFBC216B3: { name: 'CGameApplication_AddState', offset: 0x0, candidateOffset: 0x4298948, enabled: false },
        
        // Global::ExecuteProcess - Script compilation redirect
        // Disabled: no matching production runtime observation exists.
        0x835D1F2F: { name: 'Global_ExecuteProcess', offset: 0x0, enabled: false },
        
        // CBaseEngine::InitScripts - Script initialization
        0xAB652585: { name: 'CBaseEngine_InitScripts', offset: 0x0, candidateOffset: 0x366EAF4, enabled: false },
        
        // CBaseEngine::LoadScripts - Script loading
        0xD4CB1D59: { name: 'CBaseEngine_LoadScripts', offset: 0x0, candidateOffset: 0x366EAF4, enabled: false },
        
        // ScriptValidator::Validate - Script validation
        0x359024C2: { name: 'ScriptValidator_Validate', offset: 0x0, candidateOffset: 0x145A328, enabled: false },
        
        // AssertionFailed - Assertion logging
        0xFF6B0CB1: { name: 'AssertionFailed', offset: 0x0, candidateOffset: 0x60FFB8, enabled: false },
        
        // GameInstance::CollectSaveableSystems - Save system
        0xC0886390: { name: 'GameInstance_CollectSaveableSystems', offset: 0x0, candidateOffset: 0x25DF8C0, enabled: false },
        
        // GsmState_SessionActive::ReportErrorCode - Session state
        0x7FA31576: { name: 'GsmState_SessionActive_ReportErrorCode', offset: 0x0, candidateOffset: 0xA4AE3C, enabled: false },
        
        // =====================================================================
        // TweakXL-specific hooks (TweakDB functions)
        // NOTE: Offsets need to be found via reverse engineering
        // =====================================================================
        
        // TweakDB_Init - Database initialization (hash: 3062572522)
        0xB6832FEA: { name: 'TweakDB_Init', offset: 0x0, enabled: false },
        
        // TweakDB_Load - Load optimized DB (hash: 3602585178)
        0xD6B1DB5A: { name: 'TweakDB_Load', offset: 0x0, enabled: false },
        
        // TweakDB_TryLoad - Try loading DB (hash: 3512345737)
        0xD16A2999: { name: 'TweakDB_TryLoad', offset: 0x0, enabled: false },
        
        // TweakDB_CreateRecord - Create DB record (hash: 838931066)
        0x31FB0F6A: { name: 'TweakDB_CreateRecord', offset: 0x0, enabled: false },
        
        // TweakDBID_Derive - Derive TweakDB ID (hash: 326438016)
        0x137620C0: { name: 'TweakDBID_Derive', offset: 0x0, enabled: false },
    }
};

// ============================================================================
// Logging
// ============================================================================

const LogLevel = {
    ERROR: 0,
    INFO: 1,
    DEBUG: 2,
    TRACE: 3
};

function log(level, message) {
    if (level <= CONFIG.logLevel) {
        const prefix = level === LogLevel.ERROR ? '[ERROR]' : 
                       level === LogLevel.DEBUG ? '[DEBUG]' : 
                       level === LogLevel.TRACE ? '[TRACE]' : '';
        console.log(`${CONFIG.logPrefix} ${prefix} ${message}`.trim());
    }
}

function logError(msg) { log(LogLevel.ERROR, msg); }
function logInfo(msg) { log(LogLevel.INFO, msg); }
function logDebug(msg) { log(LogLevel.DEBUG, msg); }
function logTrace(msg) { log(LogLevel.TRACE, msg); }

// ============================================================================
// Fail-closed runtime identity gate
// ============================================================================

const SUPPORTED_TARGET = Object.freeze({
    schema: 'cp2077-compatibility/v1',
    architecture: 'arm64',
    version: '2.5.0',
    bundleVersion: '5814786',
    gogBuildId: '60152051833789151',
    executablePath: 'Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077',
    uuid: '1dfa005c-ed12-306f-b349-67be555f2f72',
    sha256: 'aadfdbdf145d6b7bc67f0898b4718d00816d84f0e6f1b7bf1057e04522b3f9ce'
});

const AUTHORITATIVE_METADATA = Object.freeze({
    infoPlistPath: 'Cyberpunk2077.app/Contents/Info.plist',
    versionKey: 'CFBundleShortVersionString',
    bundleVersionKey: 'CFBundleVersion',
    gogInfoPath: 'Contents/Resources/goggame-1423049311.info',
    gogBuildIdKey: 'buildId'
});

function dirname(filePath) {
    const slash = filePath.lastIndexOf('/');
    return slash <= 0 ? '/' : filePath.slice(0, slash);
}

function gameRootForExecutable(executablePath) {
    const suffix = '/' + SUPPORTED_TARGET.executablePath;
    if (!executablePath.endsWith(suffix)) {
        throw new Error(`unexpected executable path: ${executablePath}`);
    }
    return executablePath.slice(0, -suffix.length);
}

function plistString(document, key) {
    const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = document.match(
        new RegExp(`<key>\\s*${escaped}\\s*</key>\\s*<string>\\s*([^<]+?)\\s*</string>`)
    );
    if (!match) throw new Error(`Info.plist is missing ${key}`);
    return match[1];
}

function bytesFrom(value) {
    if (value instanceof Uint8Array) return value;
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (value && value.buffer instanceof ArrayBuffer) {
        return new Uint8Array(value.buffer, value.byteOffset || 0, value.byteLength);
    }
    // Values supplied by a test VM or another JS realm fail instanceof even
    // though they are ordinary byte views.
    if (value && typeof value.length === 'number' && typeof value.byteLength === 'number') {
        return Uint8Array.from(value);
    }
    throw new Error('runtime returned invalid binary data');
}

function rotateRight(value, count) {
    return (value >>> count) | (value << (32 - count));
}

// Small dependency-free SHA-256 implementation. Frida Gadget cannot invoke a
// shell command, so the hook loader hashes the complete executable itself.
function sha256Hex(input) {
    const bytes = bytesFrom(input);
    const bitLength = bytes.length * 8;
    const paddedLength = Math.ceil((bytes.length + 9) / 64) * 64;
    const padded = new Uint8Array(paddedLength);
    padded.set(bytes);
    padded[bytes.length] = 0x80;
    const view = new DataView(padded.buffer);
    const high = Math.floor(bitLength / 0x100000000);
    const low = bitLength >>> 0;
    view.setUint32(paddedLength - 8, high, false);
    view.setUint32(paddedLength - 4, low, false);

    const constants = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];
    const hash = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ];
    const words = new Uint32Array(64);

    for (let offset = 0; offset < paddedLength; offset += 64) {
        for (let index = 0; index < 16; index++) {
            words[index] = view.getUint32(offset + index * 4, false);
        }
        for (let index = 16; index < 64; index++) {
            const s0 = rotateRight(words[index - 15], 7)
                ^ rotateRight(words[index - 15], 18)
                ^ (words[index - 15] >>> 3);
            const s1 = rotateRight(words[index - 2], 17)
                ^ rotateRight(words[index - 2], 19)
                ^ (words[index - 2] >>> 10);
            words[index] = (words[index - 16] + s0 + words[index - 7] + s1) >>> 0;
        }

        let [a, b, c, d, e, f, g, h] = hash;
        for (let index = 0; index < 64; index++) {
            const upperE = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
            const choice = (e & f) ^ (~e & g);
            const first = (h + upperE + choice + constants[index] + words[index]) >>> 0;
            const upperA = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
            const majority = (a & b) ^ (a & c) ^ (b & c);
            const second = (upperA + majority) >>> 0;
            h = g;
            g = f;
            f = e;
            e = (d + first) >>> 0;
            d = c;
            c = b;
            b = a;
            a = (first + second) >>> 0;
        }
        const next = [a, b, c, d, e, f, g, h];
        for (let index = 0; index < 8; index++) {
            hash[index] = (hash[index] + next[index]) >>> 0;
        }
    }
    return hash.map((value) => value.toString(16).padStart(8, '0')).join('');
}

function executableUuid(input) {
    const bytes = bytesFrom(input);
    if (bytes.length < 32) throw new Error('executable has a truncated Mach-O header');
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (view.getUint32(0, true) !== 0xfeedfacf) {
        throw new Error('executable is not a thin 64-bit little-endian Mach-O');
    }
    if (view.getInt32(4, true) !== 0x0100000c) {
        throw new Error('executable Mach-O slice is not arm64');
    }
    const commandCount = view.getUint32(16, true);
    const commandBytes = view.getUint32(20, true);
    if (32 + commandBytes > bytes.length) throw new Error('Mach-O load commands are truncated');
    let offset = 32;
    for (let index = 0; index < commandCount; index++) {
        if (offset + 8 > bytes.length) throw new Error('Mach-O load command is truncated');
        const command = view.getUint32(offset, true);
        const size = view.getUint32(offset + 4, true);
        if (size < 8 || offset + size > 32 + commandBytes) {
            throw new Error('Mach-O load command has an invalid size');
        }
        if (command === 0x1b) {
            if (size < 24) throw new Error('LC_UUID is truncated');
            const hex = Array.from(bytes.slice(offset + 8, offset + 24))
                .map((value) => value.toString(16).padStart(2, '0'))
                .join('');
            return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
        }
        offset += size;
    }
    throw new Error('executable is missing LC_UUID');
}

function createFridaRuntime() {
    function readFile(filePath, mode, method) {
        const file = new File(filePath, mode);
        try {
            return file[method]();
        } finally {
            file.close();
        }
    }

    function exitProcess(status) {
        const lookups = [
            () => Module.getGlobalExportByName('_exit'),
            () => Module.findGlobalExportByName('_exit'),
            () => Module.findExportByName(null, '_exit')
        ];
        for (const lookup of lookups) {
            try {
                const address = lookup();
                if (address) {
                    new NativeFunction(address, 'void', ['int'])(status);
                    return;
                }
            } catch (_) {
                // Try the API spelling supported by this Frida version.
            }
        }
        throw new Error('cannot resolve _exit for fail-closed termination');
    }

    function globalExport(symbol) {
        const lookups = [
            () => Module.getGlobalExportByName(symbol),
            () => Module.findGlobalExportByName(symbol),
            () => Module.findExportByName(null, symbol)
        ];
        for (const lookup of lookups) {
            try {
                const address = lookup();
                if (address) return address;
            } catch (_) {
                // Try the API spelling supported by this Frida version.
            }
        }
        throw new Error(`cannot resolve ${symbol}`);
    }

    function sha256File(filePath) {
        // CC_SHA256_CTX is private to CommonCrypto's ABI; 256 bytes is larger
        // than every supported macOS definition and remains suitably aligned.
        const context = Memory.alloc(256);
        const digest = Memory.alloc(32);
        const bufferSize = 1024 * 1024;
        const buffer = Memory.alloc(bufferSize);
        const initialize = new NativeFunction(globalExport('CC_SHA256_Init'), 'int', ['pointer']);
        const update = new NativeFunction(
            globalExport('CC_SHA256_Update'),
            'int',
            ['pointer', 'pointer', 'uint']
        );
        const finalize = new NativeFunction(
            globalExport('CC_SHA256_Final'),
            'int',
            ['pointer', 'pointer']
        );
        if (initialize(context) !== 1) throw new Error('CC_SHA256_Init failed');

        const file = new File(filePath, 'rb');
        try {
            while (true) {
                const chunk = file.readBytes(bufferSize);
                if (!chunk || chunk.byteLength === 0) break;
                buffer.writeByteArray(chunk);
                if (update(context, buffer, chunk.byteLength) !== 1) {
                    throw new Error('CC_SHA256_Update failed');
                }
            }
        } finally {
            file.close();
        }
        if (finalize(digest, context) !== 1) throw new Error('CC_SHA256_Final failed');
        return Array.from(new Uint8Array(digest.readByteArray(32)))
            .map((value) => value.toString(16).padStart(2, '0'))
            .join('');
    }

    const mainModule = Process.mainModule || Process.enumerateModules()[0];
    return {
        executablePath: mainModule.path,
        architecture: Process.arch,
        readText: (filePath) => readFile(filePath, 'r', 'readText'),
        // One MiB comfortably covers the Mach-O header and load commands.
        readBytes: (filePath) => {
            const file = new File(filePath, 'rb');
            try {
                return file.readBytes(1024 * 1024);
            } finally {
                file.close();
            }
        },
        sha256: sha256File,
        exit: exitProcess
    };
}

function assertEqual(label, actual, expected) {
    if (actual !== expected) {
        throw new Error(`${label} mismatch: expected ${expected}, found ${actual}`);
    }
}

function verifyRuntimeIdentity(runtime) {
    const supported = runtime.supportedTarget || SUPPORTED_TARGET;
    const gameRoot = gameRootForExecutable(runtime.executablePath);
    const manifestPath = `${gameRoot}/archive-loader/compatibility/manifest.json`;
    const manifest = JSON.parse(runtime.readText(manifestPath));
    if (!manifest || !manifest.target || !manifest.target.executable) {
        throw new Error('compatibility manifest is missing required target metadata');
    }
    const target = manifest.target;
    const expected = target.executable;
    const sources = manifest.metadataSources;
    if (!sources || !sources.version || !sources.bundleVersion || !sources.gogBuildId) {
        throw new Error('compatibility manifest is missing authoritative metadata sources');
    }

    assertEqual('manifest schema', manifest.schema, supported.schema);
    assertEqual('manifest architecture', target.architecture, supported.architecture);
    assertEqual('manifest game version', target.version, supported.version);
    assertEqual('manifest bundle version', target.bundleVersion, supported.bundleVersion);
    assertEqual('manifest GOG build ID', target.gogBuildId, supported.gogBuildId);
    assertEqual('manifest executable path', expected.path, supported.executablePath);
    assertEqual('manifest executable UUID', String(expected.uuid).toLowerCase(), supported.uuid);
    assertEqual('manifest executable SHA-256', String(expected.sha256).toLowerCase(), supported.sha256);

    assertEqual('version metadata path', sources.version.path, AUTHORITATIVE_METADATA.infoPlistPath);
    assertEqual('version metadata key', sources.version.key, AUTHORITATIVE_METADATA.versionKey);
    assertEqual(
        'bundle version metadata path',
        sources.bundleVersion.path,
        AUTHORITATIVE_METADATA.infoPlistPath
    );
    assertEqual(
        'bundle version metadata key',
        sources.bundleVersion.key,
        AUTHORITATIVE_METADATA.bundleVersionKey
    );
    assertEqual('GOG metadata path', sources.gogBuildId.path, AUTHORITATIVE_METADATA.gogInfoPath);
    assertEqual('GOG metadata key', sources.gogBuildId.key, AUTHORITATIVE_METADATA.gogBuildIdKey);

    const infoPlist = runtime.readText(`${gameRoot}/${sources.version.path}`);
    const gogInfo = JSON.parse(runtime.readText(`${gameRoot}/${sources.gogBuildId.path}`));
    const executableBytes = runtime.readBytes(runtime.executablePath);
    const actual = {
        architecture: runtime.architecture,
        version: plistString(infoPlist, sources.version.key),
        bundleVersion: plistString(infoPlist, sources.bundleVersion.key),
        gogBuildId: String(gogInfo[sources.gogBuildId.key] || ''),
        uuid: executableUuid(executableBytes).toLowerCase(),
        sha256: runtime.sha256
            ? runtime.sha256(runtime.executablePath)
            : sha256Hex(executableBytes)
    };

    assertEqual('architecture', actual.architecture, target.architecture);
    assertEqual('game version', actual.version, target.version);
    assertEqual('bundle version', actual.bundleVersion, target.bundleVersion);
    assertEqual('GOG build ID', actual.gogBuildId, target.gogBuildId);
    assertEqual('executable UUID', actual.uuid, String(expected.uuid).toLowerCase());
    assertEqual('executable SHA-256', actual.sha256, String(expected.sha256).toLowerCase());
    return actual;
}

// ============================================================================
// Safe Memory Access Utilities
// ============================================================================

function safeReadPointer(ptr) {
    try {
        if (ptr.isNull()) return null;
        // Check if pointer looks valid (in reasonable address range)
        const addr = ptr.toUInt32 ? ptr.toUInt32() : parseInt(ptr.toString());
        if (addr < 0x1000 || addr > 0x7FFFFFFFFFFF) return null;
        return ptr.readPointer();
    } catch (e) {
        return null;
    }
}

function safeReadCString(ptr, maxLen = 256) {
    try {
        if (ptr.isNull()) return null;
        const addr = ptr.toUInt32 ? ptr.toUInt32() : parseInt(ptr.toString());
        if (addr < 0x1000 || addr > 0x7FFFFFFFFFFF) return null;
        return ptr.readCString(maxLen);
    } catch (e) {
        return null;
    }
}

function safeReadInt32(ptr) {
    try {
        if (ptr.isNull()) return null;
        return ptr.toInt32();
    } catch (e) {
        return null;
    }
}

function formatPtr(ptr) {
    if (!ptr) return 'null';
    try {
        return ptr.toString();
    } catch (e) {
        return 'invalid';
    }
}

// ============================================================================
// Module Resolution
// ============================================================================

let moduleBase = null;
let hookCount = 0;
let hookStats = {};

function getModuleBase() {
    if (moduleBase !== null) {
        return moduleBase;
    }
    
    const modules = Process.enumerateModules();
    
    for (const mod of modules) {
        if (mod.name.includes(CONFIG.targetModule)) {
            moduleBase = mod.base;
            logInfo(`Found module '${mod.name}' at base ${mod.base}`);
            return moduleBase;
        }
    }
    
    // Fallback: use the first module (main executable)
    if (modules.length > 0) {
        moduleBase = modules[0].base;
        logInfo(`Using fallback module '${modules[0].name}' at base ${modules[0].base}`);
        return moduleBase;
    }
    
    logError('Could not find target module!');
    return null;
}

// ============================================================================
// Hook Handlers
// ============================================================================

/**
 * Hook: Main
 */
function hookMain(address) {
    let gameStartTime = null;
    
    Interceptor.attach(address, {
        onEnter: function(args) {
            gameStartTime = Date.now();
            logInfo('Main() called - Game starting');
            hookStats['Main'] = (hookStats['Main'] || 0) + 1;
        },
        onLeave: function(retval) {
            const elapsed = gameStartTime ? (Date.now() - gameStartTime) : 0;
            logInfo(`Main() returned after ${elapsed}ms - Game shutting down`);
        }
    });
}

/**
 * Hook: CGameApplication::AddState
 */
function hookCGameApplication_AddState(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['AddState'] = (hookStats['AddState'] || 0) + 1;
            logInfo('CGameApplication::AddState called');
            logTrace(`  this: ${formatPtr(args[0])}, state: ${formatPtr(args[1])}`);
        },
        onLeave: function(retval) {
            logTrace(`CGameApplication::AddState returned: ${retval}`);
        }
    });
}

/**
 * Hook: Global::ExecuteProcess
 */
function hookGlobal_ExecuteProcess(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['ExecuteProcess'] = (hookStats['ExecuteProcess'] || 0) + 1;
            
            // Try to read command string safely
            const commandPtr = args[1];
            let commandStr = null;
            
            if (commandPtr && !commandPtr.isNull()) {
                // CString typically has char* at offset 0 or has inline storage
                const innerPtr = safeReadPointer(commandPtr);
                if (innerPtr) {
                    commandStr = safeReadCString(innerPtr);
                }
            }
            
            if (commandStr) {
                logInfo(`ExecuteProcess: ${commandStr}`);
                if (commandStr.includes('scc')) {
                    logInfo('  -> Script compiler detected');
                    this.isScc = true;
                }
            } else {
                logDebug('ExecuteProcess called (could not read command)');
            }
        },
        onLeave: function(retval) {
            if (this.isScc) {
                const success = retval.toInt32();
                logInfo(`Script compilation ${success ? 'succeeded' : 'failed'}`);
            }
        }
    });
}

/**
 * Hook: CBaseEngine::InitScripts
 */
function hookCBaseEngine_InitScripts(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['InitScripts'] = (hookStats['InitScripts'] || 0) + 1;
            logInfo('CBaseEngine::InitScripts called');
        },
        onLeave: function(retval) {
            logInfo('CBaseEngine::InitScripts completed');
        }
    });
}

/**
 * Hook: CBaseEngine::LoadScripts
 */
function hookCBaseEngine_LoadScripts(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['LoadScripts'] = (hookStats['LoadScripts'] || 0) + 1;
            logInfo('CBaseEngine::LoadScripts called');
        },
        onLeave: function(retval) {
            logInfo('CBaseEngine::LoadScripts completed');
        }
    });
}

/**
 * Hook: ScriptValidator::Validate
 */
function hookScriptValidator_Validate(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['Validate'] = (hookStats['Validate'] || 0) + 1;
            logDebug('ScriptValidator::Validate called');
        },
        onLeave: function(retval) {
            const result = safeReadInt32(retval);
            if (result !== null && result !== 0) {
                logInfo(`ScriptValidator::Validate found issues (code: ${result})`);
            }
        }
    });
}

/**
 * Hook: AssertionFailed
 */
function hookAssertionFailed(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['AssertionFailed'] = (hookStats['AssertionFailed'] || 0) + 1;
            
            logError('=== ASSERTION FAILED ===');
            
            const file = safeReadCString(args[0]);
            const line = safeReadInt32(args[1]);
            const expr = safeReadCString(args[2]);
            const msg = safeReadCString(args[3]);
            
            if (file) logError(`  File: ${file}`);
            if (line !== null) logError(`  Line: ${line}`);
            if (expr) logError(`  Expression: ${expr}`);
            if (msg) logError(`  Message: ${msg}`);
            
            logError('========================');
        }
    });
}

/**
 * Hook: GameInstance::CollectSaveableSystems
 */
function hookGameInstance_CollectSaveableSystems(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['CollectSaveableSystems'] = (hookStats['CollectSaveableSystems'] || 0) + 1;
            logDebug('GameInstance::CollectSaveableSystems called');
        }
    });
}

/**
 * Hook: GsmState_SessionActive::ReportErrorCode
 */
function hookGsmState_SessionActive_ReportErrorCode(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['ReportErrorCode'] = (hookStats['ReportErrorCode'] || 0) + 1;
            
            const errorCode = safeReadInt32(args[1]);
            if (errorCode !== null && errorCode !== 0) {
                logInfo(`GsmState_SessionActive::ReportErrorCode - Error: ${errorCode}`);
            }
        }
    });
}

// ============================================================================
// TweakXL Hook Handlers
// ============================================================================

/**
 * Hook: TweakDB_Init - Database initialization
 */
function hookTweakDB_Init(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_Init'] = (hookStats['TweakDB_Init'] || 0) + 1;
            logInfo('TweakDB::Init called - TweakDB initializing');
            logTrace(`  this: ${formatPtr(args[0])}, arg1: ${formatPtr(args[1])}`);
        },
        onLeave: function(retval) {
            logInfo('TweakDB::Init completed');
        }
    });
}

/**
 * Hook: TweakDB_Load - Load optimized database
 */
function hookTweakDB_Load(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_Load'] = (hookStats['TweakDB_Load'] || 0) + 1;
            logInfo('TweakDB::Load called - Loading TweakDB');
            
            // Try to read the path argument (CString)
            const pathPtr = args[1];
            if (pathPtr && !pathPtr.isNull()) {
                const innerPtr = safeReadPointer(pathPtr);
                if (innerPtr) {
                    const path = safeReadCString(innerPtr);
                    if (path) {
                        logInfo(`  Loading: ${path}`);
                    }
                }
            }
        },
        onLeave: function(retval) {
            logInfo('TweakDB::Load completed');
        }
    });
}

/**
 * Hook: TweakDB_TryLoad - Try loading database
 */
function hookTweakDB_TryLoad(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_TryLoad'] = (hookStats['TweakDB_TryLoad'] || 0) + 1;
            logInfo('TweakDB::TryLoad called');
        },
        onLeave: function(retval) {
            const success = retval.toInt32();
            logInfo(`TweakDB::TryLoad ${success ? 'succeeded' : 'failed'}`);
        }
    });
}

/**
 * Hook: TweakDB_CreateRecord - Create database record
 */
function hookTweakDB_CreateRecord(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_CreateRecord'] = (hookStats['TweakDB_CreateRecord'] || 0) + 1;
            logDebug('TweakDB::CreateRecord called');
            
            // args[0] = this (TweakDB*)
            // args[1] = recordType (uint32)
            // args[2] = recordId (TweakDBID)
            const recordType = safeReadInt32(args[1]);
            if (recordType !== null) {
                logTrace(`  recordType: 0x${recordType.toString(16)}`);
            }
        }
    });
}

/**
 * Hook: TweakDBID_Derive - Derive TweakDB ID from base
 */
function hookTweakDBID_Derive(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDBID_Derive'] = (hookStats['TweakDBID_Derive'] || 0) + 1;
            
            // args[2] = name string
            const nameStr = safeReadCString(args[2]);
            if (nameStr) {
                logTrace(`TweakDBID::Derive: ${nameStr}`);
            }
        }
    });
}

// ============================================================================
// Hook Installation
// ============================================================================

const hookFunctions = {
    'Main': hookMain,
    'CGameApplication_AddState': hookCGameApplication_AddState,
    'Global_ExecuteProcess': hookGlobal_ExecuteProcess,
    'CBaseEngine_InitScripts': hookCBaseEngine_InitScripts,
    'CBaseEngine_LoadScripts': hookCBaseEngine_LoadScripts,
    'ScriptValidator_Validate': hookScriptValidator_Validate,
    'AssertionFailed': hookAssertionFailed,
    'GameInstance_CollectSaveableSystems': hookGameInstance_CollectSaveableSystems,
    'GsmState_SessionActive_ReportErrorCode': hookGsmState_SessionActive_ReportErrorCode,
    // TweakXL hooks
    'TweakDB_Init': hookTweakDB_Init,
    'TweakDB_Load': hookTweakDB_Load,
    'TweakDB_TryLoad': hookTweakDB_TryLoad,
    'TweakDB_CreateRecord': hookTweakDB_CreateRecord,
    'TweakDBID_Derive': hookTweakDBID_Derive,
};

function installHooks() {
    console.log(`${CONFIG.logPrefix} ========================================`);
    console.log(`${CONFIG.logPrefix} RED4ext Frida Hooks - Initializing`);
    console.log(`${CONFIG.logPrefix} ========================================`);
    
    const base = getModuleBase();
    if (base === null) {
        logError('Failed to get module base address');
        return;
    }
    
    logInfo(`Module base: ${base}`);
    logInfo('');
    logInfo('Installing hooks...');
    
    for (const [hashStr, hookInfo] of Object.entries(CONFIG.hooks)) {
        const { name, offset, enabled } = hookInfo;
        
        if (!enabled) {
            logDebug(`  [SKIP] ${name} (disabled)`);
            continue;
        }
        
        const hookFunc = hookFunctions[name];
        if (!hookFunc) {
            logError(`  [ERROR] ${name} - No handler function`);
            continue;
        }
        
        try {
            const address = base.add(offset);
            hookFunc(address);
            hookCount++;
            logInfo(`  [OK] ${name} at ${address} (offset 0x${offset.toString(16)})`);
        } catch (e) {
            logError(`  [FAIL] ${name} - ${e.message}`);
        }
    }
    
    logInfo('');
    console.log(`${CONFIG.logPrefix} Hook installation complete: ${hookCount}/${Object.keys(CONFIG.hooks).length} hooks active`);
    console.log(`${CONFIG.logPrefix} ========================================`);
}

// ============================================================================
// Shutdown Crash Workaround
// ============================================================================

// Keeps the replacement callback alive; Frida frees a collected NativeCallback
// out from under the patched function.
let shutdownGuardCallback = null;

/**
 * Stops the segfault that fires every time the game quits.
 *
 * RED4ext's own Detour system resolves none of its function hashes on macOS
 * (they are absent from cyberpunk2077_addresses.json), so each DetourAttach
 * leaves a null entry in its DetourTransaction. On exit, __cxa_finalize_ranges
 * -> RED4extShutdown() -> App::Destruct() walks that transaction and
 * dereferences null at 0x38, long after the game has finished shutting down.
 *
 * Our hooks are Frida trampolines and need none of that teardown, so replace
 * App::Destruct with a no-op. It runs exactly once, at process exit, where the
 * OS reclaims everything regardless. App::Shutdown is left alone so logger and
 * plugin shutdown still run normally.
 */
function installShutdownGuard() {
    const OFFSET = 0xA504;                      // App::Destruct() in RED4ext.dylib
    const SYMBOLS = ['_ZN3App8DestructEv', '__ZN3App8DestructEv'];

    let red4ext = null;
    for (const mod of Process.enumerateModules()) {
        if (mod.name.includes('RED4ext')) {
            red4ext = mod;
            break;
        }
    }

    if (red4ext === null) {
        logError('  [FAIL] ShutdownGuard - RED4ext module not loaded');
        return;
    }

    // Prefer the exported symbol; fall back to the offset if this Frida build
    // exposes a different lookup API or mangles the name differently.
    let address = null;
    for (const symbol of SYMBOLS) {
        try {
            address = red4ext.findExportByName
                ? red4ext.findExportByName(symbol)
                : Module.findExportByName(red4ext.name, symbol);
        } catch (e) {
            address = null;
        }
        if (address) {
            logDebug(`  ShutdownGuard resolved via symbol ${symbol}`);
            break;
        }
    }

    if (!address) {
        address = red4ext.base.add(OFFSET);
        logDebug(`  ShutdownGuard resolved via offset 0x${OFFSET.toString(16)}`);
    }

    try {
        shutdownGuardCallback = new NativeCallback(function () {}, 'void', ['pointer']);
        Interceptor.replace(address, shutdownGuardCallback);
        logInfo(`  [OK] ShutdownGuard - App::Destruct neutralized at ${address}`);
    } catch (e) {
        logError(`  [FAIL] ShutdownGuard - ${e.message}`);
    }
}

// ============================================================================
// Entry Point
// ============================================================================

const runtime = typeof __RED4EXT_TEST_RUNTIME__ !== 'undefined'
    ? __RED4EXT_TEST_RUNTIME__
    : createFridaRuntime();

try {
    verifyRuntimeIdentity(runtime);
    logInfo('Runtime identity gate passed for Cyberpunk 2077 2.5.0');
} catch (error) {
    logError(`Runtime identity gate failed: ${error.message || error}`);
    // EX_CONFIG makes a gate rejection distinguishable from a game crash.
    runtime.exit(78);
    throw error;
}

// Identity verification is deliberately above every Interceptor operation.
installHooks();
if (CONFIG.shutdownGuardEnabled) {
    installShutdownGuard();
} else {
    logInfo('ShutdownGuard disabled: no audited RED4ext 2.5.0 runtime is installed');
}

// Export for external access
rpc.exports = {
    getHookCount: function() {
        return hookCount;
    },
    
    getHookStats: function() {
        return JSON.stringify(hookStats);
    },
    
    setLogLevel: function(level) {
        CONFIG.logLevel = level;
        return `Log level set to ${level}`;
    }
};
