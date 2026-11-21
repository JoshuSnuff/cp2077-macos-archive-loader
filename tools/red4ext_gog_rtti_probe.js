'use strict';

const OUTPUT = '/private/tmp/red4ext-gog-rtti.ndjson';

function emit(record) {
    try {
        const file = new File(OUTPUT, 'a');
        file.write(JSON.stringify(record) + '\n');
        file.flush();
        file.close();
    } catch (_) {
        try { console.log('[RED4ext-GOG-rtti] ' + JSON.stringify(record)); } catch (__) {}
    }
}

function fnv1a64(value) {
    let hash = BigInt('0xcbf29ce484222325');
    const prime = BigInt('0x100000001b3');
    const mask = (BigInt(1) << BigInt(64)) - BigInt(1);
    for (let index = 0; index < value.length; index += 1) {
        hash ^= BigInt(value.charCodeAt(index));
        hash = (hash * prime) & mask;
    }
    return hash;
}

function hex(value) {
    try { return value.toString(); } catch (_) { return 'unreadable'; }
}

function pointerFields(value, offsets) {
    const fields = {};
    for (const offset of offsets) {
        try { fields[`0x${offset.toString(16)}`] = hex(value.add(offset).readPointer()); } catch (_) {}
    }
    return fields;
}

function findClass(getClass, registry, name) {
    try { return getClass(registry, fnv1a64(name)); } catch (_) { return ptr(0); }
}

function inspectClass(getClass, registry, name) {
    const klass = findClass(getClass, registry, name);
    if (klass.isNull()) {
        emit({ type: 'class_missing', name });
        return;
    }

    emit({ type: 'class', name, address: hex(klass) });
    const targetHash = uint64('0x' + fnv1a64('ExecuteProcess').toString(16));
    for (const tableOffset of [0x48, 0x58]) {
        try {
            const entries = klass.add(tableOffset).readPointer();
            const count = klass.add(tableOffset + 8).readU32();
            emit({ type: 'table', name, table_offset: `0x${tableOffset.toString(16)}`, count });
            if (count > 4096 || entries.isNull()) continue;
            for (let index = 0; index < count; index += 1) {
                const functionObject = entries.add(index * Process.pointerSize).readPointer();
                if (functionObject.isNull()) continue;
                let methodHash;
                try { methodHash = functionObject.add(0x10).readU64(); } catch (_) { continue; }
                if (methodHash.equals(targetHash.toString(16))) {
                    emit({
                        type: 'match', name, table_offset: `0x${tableOffset.toString(16)}`,
                        index, function_object: hex(functionObject),
                        pointers: pointerFields(functionObject, [0x18, 0x20, 0x28, 0x30, 0x38, 0x40])
                    });
                }
            }
        } catch (error) {
            emit({ type: 'table_error', name, table_offset: `0x${tableOffset.toString(16)}`, error: String(error) });
        }
    }
}

try {
    const game = Process.enumerateModules().find((module) => module.name.includes('Cyberpunk2077'));
    if (!game) throw new Error('Cyberpunk2077 module not found');
    const base = game.base;
    const registryFactory = new NativeFunction(base.add(0x2188e8c), 'pointer', []);
    const registry = registryFactory();
    const registryVtable = registry.readPointer();
    const getClass = new NativeFunction(registryVtable.add(0x10).readPointer(), 'pointer', ['pointer', 'uint64']);
    emit({ type: 'start', base: hex(base), registry: hex(registry) });
    for (const name of ['Global', 'global', 'GlobalFunctions', 'GlobalFunc']) {
        inspectClass(getClass, registry, name);
    }
} catch (error) {
    emit({ type: 'error', error: String(error) });
}
