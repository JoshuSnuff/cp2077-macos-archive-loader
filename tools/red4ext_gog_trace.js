/*
 * Optional RED4ext GOG runtime probe for Frida Gadget.
 *
 * This file is deliberately an observer only. It reads candidates produced by
 * red4ext_gog_audit.py, attaches Interceptor callbacks to those candidates, and
 * records bounded observations. It never replaces a function or writes game
 * memory. In particular, there is no embedded Steam offset fallback: even the
 * known `AssertionFailed` candidate `1:0x60FFB8` must come from audit JSON.
 */

'use strict';

const REQUIRED_HOOKS = Object.freeze([
    { name: 'CGameApplication_AddState', hash: '0xFBC216B3' },
    { name: 'Global_ExecuteProcess', hash: '0x835D1F2F' },
    { name: 'CBaseEngine_InitScripts', hash: '0xAB652585' },
    { name: 'CBaseEngine_LoadScripts', hash: '0xD4CB1D59' },
    { name: 'ScriptValidator_Validate', hash: '0x359024C2' },
    { name: 'AssertionFailed', hash: '0xFF6B0CB1' },
    { name: 'GameInstance_CollectSaveableSystems', hash: '0xC0886390' },
    { name: 'GsmState_SessionActive_ReportErrorCode', hash: '0x7FA31576' }
]);

// Edit these values for a fixed local setup, or use the environment variables
// documented in README-red4ext-gog.md. Empty paths are safe: the probe reports
// its JSON to the Frida console instead of guessing a file location.
// Ambiguous hooks are skipped unless RED4EXT_GOG_PROBE_AMBIGUOUS is explicitly
// set to a true value for a deliberate exploratory run.
const CONFIG = Object.freeze({
    auditPath: '',
    tracePath: '',
    hooks: Object.freeze([]),
    maxObservations: 256,
    maxArguments: 6,
    maxStringLength: 256,
    moduleName: 'Cyberpunk2077'
});

function log(message) {
    try {
        console.log('[RED4ext-GOG-trace] ' + message);
    } catch (_) {
        // Logging must never interfere with the game or the probe callbacks.
    }
}

function errorMessage(error) {
    try {
        if (error && error.message) return String(error.message);
        return String(error);
    } catch (_) {
        return 'unknown error';
    }
}

function environmentValue(name) {
    try {
        if (typeof Process !== 'undefined' && typeof Process.getEnv === 'function') {
            const value = Process.getEnv(name);
            if (value) return value;
        }
    } catch (_) {
        // Fall through to the other host-specific environment mechanisms.
    }

    try {
        if (typeof process !== 'undefined' && process.env && process.env[name]) {
            return process.env[name];
        }
    } catch (_) {
        // Node's process object is not present in Frida Gadget.
    }

    // Older Frida Gadget versions do not expose Process.getEnv. Calling libc's
    // getenv is read-only and keeps the probe usable on those versions.
    try {
        if (typeof Module !== 'undefined'
            && typeof Memory !== 'undefined'
            && typeof NativeFunction !== 'undefined') {
            const findExport = Module.getExportByName || Module.findExportByName;
            if (typeof findExport === 'function') {
                const getenvAddress = findExport.call(Module, null, 'getenv');
                if (getenvAddress) {
                    const getenv = new NativeFunction(
                        getenvAddress,
                        'pointer',
                        ['pointer']
                    );
                    const value = getenv(Memory.allocUtf8String(name));
                    if (value && !value.isNull()) return value.readUtf8String();
                }
            }
        }
    } catch (_) {
        // Missing libc exports or an unreadable value simply means disabled.
    }

    return null;
}

function positiveInteger(value, fallback) {
    const parsed = Number(value);
    if (!Number.isFinite(parsed) || parsed < 1) return fallback;
    return Math.floor(parsed);
}

function booleanValue(value, fallback) {
    if (value === undefined || value === null || value === '') return fallback;
    if (typeof value === 'boolean') return value;

    const normalized = String(value).trim().toLowerCase();
    if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
    if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
    return fallback;
}

function hookAllowlist(value) {
    const values = Array.isArray(value) ? value : String(value || '').split(',');
    return Object.freeze([...new Set(values
        .map((hook) => String(hook).trim())
        .filter(Boolean))]);
}

function resolveConfig(options) {
    const supplied = options || {};
    return {
        auditPath: supplied.auditPath
            || environmentValue('RED4EXT_GOG_AUDIT_JSON')
            || CONFIG.auditPath,
        tracePath: supplied.tracePath
            || environmentValue('RED4EXT_GOG_TRACE_OUTPUT')
            || CONFIG.tracePath,
        hooks: hookAllowlist(
            supplied.hooks !== undefined
                ? supplied.hooks
                : environmentValue('RED4EXT_GOG_HOOKS') || CONFIG.hooks
        ),
        maxObservations: positiveInteger(
            supplied.maxObservations
                || environmentValue('RED4EXT_GOG_MAX_OBSERVATIONS')
                || CONFIG.maxObservations,
            CONFIG.maxObservations
        ),
        maxArguments: positiveInteger(supplied.maxArguments || CONFIG.maxArguments, CONFIG.maxArguments),
        maxStringLength: positiveInteger(
            supplied.maxStringLength || CONFIG.maxStringLength,
            CONFIG.maxStringLength
        ),
        moduleName: supplied.moduleName || CONFIG.moduleName,
        probeAmbiguous: booleanValue(
            supplied.probeAmbiguous !== undefined
                ? supplied.probeAmbiguous
                : environmentValue('RED4EXT_GOG_PROBE_AMBIGUOUS'),
            false
        )
    };
}

function readFileText(path) {
    if (typeof File !== 'undefined' && typeof File.readAllText === 'function') {
        return File.readAllText(path);
    }

    const file = new File(path, 'r');
    try {
        if (typeof file.readText === 'function') return file.readText();
        if (typeof file.readUtf8String === 'function') return file.readUtf8String();
        throw new Error('Frida File has no text reader');
    } finally {
        if (typeof file.close === 'function') file.close();
    }
}

function createFileWriter(path) {
    if (!path) {
        return {
            writeLine(line) { log(line); },
            close() {}
        };
    }

    const file = new File(path, 'w');
    return {
        writeLine(line) {
            file.write(line + '\n');
            if (typeof file.flush === 'function') file.flush();
        },
        close() {
            if (typeof file.close === 'function') file.close();
        }
    };
}

function defaultRuntime() {
    return {
        enumerateModules() {
            return Process.enumerateModules();
        },
        readText: readFileText,
        createWriter: createFileWriter,
        attach(address, callbacks) {
            return Interceptor.attach(address, callbacks);
        }
    };
}

function writeRecord(writer, record) {
    const line = JSON.stringify(record);
    try {
        writer.writeLine(line);
    } catch (error) {
        log('could not write trace record: ' + errorMessage(error));
    }
}

function loadAudit(path, runtime) {
    if (!path) throw new Error('audit JSON path is not configured');
    const parsed = JSON.parse(runtime.readText(path));
    if (!parsed || typeof parsed !== 'object') {
        throw new Error('audit JSON root is not an object');
    }
    return parsed;
}

function hookTable(audit) {
    const table = audit.hooks || audit.required_hooks || audit.candidates;
    if (Array.isArray(table)) {
        const result = {};
        for (const entry of table) {
            if (entry && entry.name) result[entry.name] = entry;
        }
        return result;
    }
    return table && typeof table === 'object' ? table : {};
}

function hookRecord(audit, spec) {
    const table = hookTable(audit);
    if (table[spec.name]) return table[spec.name];

    // Also accept a flat candidate list from early analyzer reports. Unknown
    // hook names are never attached because the caller iterates REQUIRED_HOOKS.
    if (Array.isArray(audit.candidates)) {
        const candidates = audit.candidates.filter((entry) => entry && entry.hook === spec.name);
        if (candidates.length > 0) return { candidates };
    }
    return null;
}

function auditIdentity(audit) {
    const binary = audit && audit.binary;
    const metadata = audit && audit.metadata;
    const values = [
        audit && audit.binary_uuid,
        audit && audit.uuid,
        binary && binary.uuid,
        metadata && metadata.binary_uuid,
        metadata && metadata.uuid
    ];
    for (const value of values) {
        if (typeof value === 'string' && value.trim()) return value.trim();
    }
    return null;
}

function hashMatches(record, spec) {
    if (!record || record.hash === undefined || record.hash === null) return true;
    return String(record.hash).replace(/^0x/i, '').toUpperCase()
        === spec.hash.replace(/^0x/i, '').toUpperCase();
}

function candidateList(record) {
    if (!record) return [];
    if (Array.isArray(record)) return record;
    if (Array.isArray(record.candidates)) return record.candidates;
    if (record.rva !== undefined || record.offset !== undefined) return [record];
    return [];
}

function parseRva(value) {
    if (typeof value === 'number') {
        if (!Number.isSafeInteger(value) || value < 0) return null;
        return { number: value, display: '0x' + value.toString(16).toUpperCase() };
    }
    if (typeof value !== 'string') return null;

    const text = value.trim();
    const match = /^(?:(\d+):)?(0x[0-9a-f]+|[0-9]+)$/i.exec(text);
    if (!match) return null;
    if (match[1] !== undefined && match[1] !== '1') return null;

    const number = Number(match[2]);
    if (!Number.isSafeInteger(number) || number < 0) return null;
    const display = (match[1] === undefined ? '' : '1:')
        + '0x' + number.toString(16).toUpperCase();
    return { number, display };
}

function normalizeCandidate(raw) {
    if (typeof raw === 'string' || typeof raw === 'number') {
        const parsed = parseRva(raw);
        return parsed ? { ...parsed, stringArgs: [] } : null;
    }
    if (!raw || typeof raw !== 'object') return null;

    if (raw.valid === false || raw.accepted === false || raw.function_start === false
        || raw.is_function_start === false || raw.confidence === 'rejected') {
        return null;
    }

    // `rva` is the analyzer contract. `offset` is accepted for the same
    // image:RVA value because it is the spelling used by RED4ext's database.
    const parsed = parseRva(
        raw.rva !== undefined ? raw.rva
            : raw.offset !== undefined ? raw.offset
                : raw.image_rva
    );
    if (!parsed) return null;

    const stringArgs = raw.string_args || raw.stringArgs || [];
    return {
        ...parsed,
        stringArgs: Array.isArray(stringArgs)
            ? stringArgs.filter((index) => Number.isInteger(index) && index >= 0)
            : []
    };
}

function findModule(runtime, moduleName) {
    const modules = runtime.enumerateModules();
    if (!Array.isArray(modules)) return null;
    const exact = modules.find((module) => module && module.name === moduleName);
    if (exact) return exact;
    return modules.find((module) => module && module.name
        && module.name.indexOf(moduleName) !== -1) || null;
}

function pointerText(pointer) {
    if (pointer === null || pointer === undefined) return null;
    try {
        return pointer.toString();
    } catch (_) {
        return null;
    }
}

function safeString(pointer, maxLength) {
    if (pointer === null || pointer === undefined) return null;
    try {
        if (typeof pointer.isNull === 'function' && pointer.isNull()) return null;
        let value = null;
        if (typeof pointer.readUtf8String === 'function') {
            value = pointer.readUtf8String(maxLength);
        } else if (typeof pointer.readCString === 'function') {
            value = pointer.readCString(maxLength);
        }
        if (typeof value !== 'string' || value.length === 0) return null;
        return value.slice(0, maxLength).replace(/[\u0000-\u001f\u007f]/g, '?');
    } catch (_) {
        return null;
    }
}

function argumentPointers(args, maxArguments) {
    const pointers = [];
    for (let index = 0; index < maxArguments; index += 1) {
        if (!args || args[index] === undefined) break;
        pointers.push(pointerText(args[index]));
    }
    return pointers;
}

function selectedStrings(args, indexes, maxLength) {
    const strings = {};
    for (const index of indexes) {
        if (!args || args[index] === undefined) continue;
        const value = safeString(args[index], maxLength);
        if (value !== null) strings['arg' + index] = value;
    }
    return strings;
}

function addressFromRva(base, rva) {
    if (!base || typeof base.add !== 'function') {
        throw new Error('target module has no usable base address');
    }
    return base.add(rva);
}

function attachCandidate(spec, candidate, module, emit, state, runtime, config) {
    const address = addressFromRva(module.base, candidate.number);
    const candidateState = { callCount: 0 };
    const callbacks = {
        onEnter(args) {
            try {
                if (state.observationCount >= config.maxObservations) return;
                candidateState.callCount += 1;
                state.observationCount += 1;
                this.__red4extGogObservation = {
                    type: 'observation',
                    hook: spec.name,
                    hash: spec.hash,
                    candidate_rva: candidate.display,
                    call_count: candidateState.callCount,
                    argument_pointers: argumentPointers(args, config.maxArguments),
                    selected_strings: selectedStrings(args, candidate.stringArgs, config.maxStringLength)
                };
            } catch (error) {
                state.errors.push({
                    type: 'callback_error',
                    hook: spec.name,
                    candidate_rva: candidate.display,
                    error: errorMessage(error)
                });
            }
        },
        onLeave(returnValue) {
            try {
                const observation = this.__red4extGogObservation;
                if (!observation) return;
                observation.return_value = pointerText(returnValue);
                emit(observation);
                this.__red4extGogObservation = null;
            } catch (error) {
                state.errors.push({
                    type: 'callback_error',
                    hook: spec.name,
                    candidate_rva: candidate.display,
                    error: errorMessage(error)
                });
            }
        }
    };

    runtime.attach(address, callbacks);
}

function runProbe(options) {
    const config = resolveConfig(options);
    const runtime = (options && options.runtime) || defaultRuntime();
    const state = {
        observationCount: 0,
        errors: [],
        attached: 0,
        targets: []
    };

    let writer;
    try {
        writer = (options && options.writer)
            || (typeof runtime.createWriter === 'function'
                ? runtime.createWriter(config.tracePath)
                : createFileWriter(config.tracePath));
    } catch (error) {
        state.errors.push({ type: 'output_error', error: errorMessage(error) });
        log('could not open trace output: ' + errorMessage(error));
        return state;
    }

    const emit = (record) => {
        const output = { ...record };
        if (state.binaryUuid && output.binary_uuid === undefined) {
            output.binary_uuid = state.binaryUuid;
        }
        writeRecord(writer, output);
    };

    let audit;
    try {
        audit = (options && options.audit) || loadAudit(config.auditPath, runtime);
    } catch (error) {
        state.errors.push({ type: 'audit_error', error: errorMessage(error) });
        emit({
            type: 'probe_error',
            error: errorMessage(error)
        });
        if (writer && typeof writer.close === 'function') writer.close();
        return { ...state, fatalError: errorMessage(error) };
    }

    state.binaryUuid = auditIdentity(audit);
    if (!state.binaryUuid) {
        const message = 'audit JSON has no binary UUID';
        state.errors.push({ type: 'audit_error', error: message });
        emit({ type: 'probe_error', error: message });
        if (writer && typeof writer.close === 'function') writer.close();
        return { ...state, fatalError: message };
    }

    emit({
        type: 'metadata',
        event: 'probe_start',
        module: config.moduleName,
        max_observations: config.maxObservations,
        probe_ambiguous: config.probeAmbiguous,
        hook_allowlist: config.hooks
    });

    const module = findModule(runtime, config.moduleName);
    if (!module) {
        const message = 'target module not found: ' + config.moduleName;
        state.errors.push({ type: 'module_error', error: message });
        emit({ type: 'metadata', event: 'probe_error', error: message });
        if (writer && typeof writer.close === 'function') writer.close();
        return { ...state, fatalError: message };
    }

    for (const spec of REQUIRED_HOOKS) {
        state.targets.push(spec.name);
        if (!config.hooks.includes(spec.name)) {
            emit({
                type: 'metadata',
                event: 'hook_filtered',
                hook: spec.name,
                hash: spec.hash,
                hook_allowlist: config.hooks,
                reason: 'hook is not in RED4EXT_GOG_HOOKS allowlist'
            });
            continue;
        }
        const record = hookRecord(audit, spec);
        if (!record) {
            emit({
                type: 'metadata',
                event: 'hook_missing',
                hook: spec.name,
                hash: spec.hash
            });
            continue;
        }
        if (!hashMatches(record, spec)) {
            const message = 'audit hash does not match required hook hash';
            state.errors.push({ type: 'audit_error', hook: spec.name, error: message });
            emit({
                type: 'metadata',
                event: 'hook_rejected',
                hook: spec.name,
                hash: spec.hash,
                error: message
            });
            continue;
        }

        const candidates = candidateList(record);
        if (candidates.length === 0) {
            emit({
                type: 'metadata',
                event: 'candidate_missing',
                hook: spec.name,
                hash: spec.hash
            });
            continue;
        }

        if (candidates.length > 1 && !config.probeAmbiguous) {
            emit({
                type: 'metadata',
                event: 'hook_skipped_ambiguous',
                hook: spec.name,
                hash: spec.hash,
                candidate_count: candidates.length,
                probe_ambiguous: false,
                reason: 'more than one candidate'
            });
            continue;
        }

        for (const rawCandidate of candidates) {
            const candidate = normalizeCandidate(rawCandidate);
            if (!candidate) {
                emit({
                    type: 'metadata',
                    event: 'candidate_rejected',
                    hook: spec.name,
                    hash: spec.hash,
                    reason: 'candidate has no accepted analyzer RVA'
                });
                continue;
            }

            try {
                attachCandidate(spec, candidate, module, emit, state, runtime, config);
                state.attached += 1;
            } catch (error) {
                const entry = {
                    type: 'attach_error',
                    hook: spec.name,
                    hash: spec.hash,
                    candidate_rva: candidate.display,
                    call_count: 0,
                    error: errorMessage(error)
                };
                state.errors.push(entry);
                emit(entry);
                // One bad candidate must not prevent the other seven hooks or
                // later candidates from being attempted.
            }
        }
    }

    emit({
        type: 'metadata',
        event: 'probe_complete',
        attached: state.attached,
        observation_count: state.observationCount,
        max_observations: config.maxObservations
    });
    // Interceptor callbacks run after setup returns. Keep the writer alive for
    // those callbacks; file writers flush after every record.
    return state;
}

function startProbe() {
    try {
        return runProbe();
    } catch (error) {
        log('probe stopped safely: ' + errorMessage(error));
        return { errors: [{ type: 'probe_error', error: errorMessage(error) }] };
    }
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        REQUIRED_HOOKS,
        CONFIG,
        parseRva,
        normalizeCandidate,
        runProbe
    };
}

if (typeof Process !== 'undefined' && typeof Interceptor !== 'undefined') {
    startProbe();
}
