#!/usr/bin/env bash
# Dry-run coverage for the optional RED4ext GOG Frida probe.
#
# The harness supplies Frida-shaped pointers and Interceptor behavior, so no
# game or Frida installation is needed. The fixture audit is the only source
# of candidate addresses; the binary hash check makes the read-only boundary
# observable.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${PROBE:-$REPOSITORY_DIR/tools/red4ext_gog_trace.js}"
WORK_DIR="$(mktemp -d /private/tmp/red4ext-gog-trace-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

[ -f "$PROBE" ] || fail "probe script is missing"
command -v node >/dev/null 2>&1 || fail "node is required for the dry-run harness"

AUDIT_JSON="$WORK_DIR/audit.json"
GAME_BINARY="$WORK_DIR/Cyberpunk2077"
printf 'fixture game image: this file must remain unchanged\n' > "$GAME_BINARY"
BEFORE_HASH="$(shasum -a 256 "$GAME_BINARY")"

node - "$AUDIT_JSON" <<'NODE'
const fs = require('fs');
const path = process.argv[2];

const hooks = [
  ['CGameApplication_AddState', '0xFBC216B3', ['0x1000']],
  ['Global_ExecuteProcess', '0x835D1F2F', ['0x2000', '0x2100']],
  ['CBaseEngine_InitScripts', '0xAB652585', ['0x3000']],
  ['CBaseEngine_LoadScripts', '0xD4CB1D59', ['0x4000']],
  ['ScriptValidator_Validate', '0x359024C2', ['0x5000']],
  ['AssertionFailed', '0xFF6B0CB1', ['1:0x60FFB8']],
  ['GameInstance_CollectSaveableSystems', '0xC0886390', ['0x7000']],
  ['GsmState_SessionActive_ReportErrorCode', '0x7FA31576', ['0x8000']]
];

const audit = {
  schema: 'red4ext-gog-audit/v1',
  binary_uuid: 'fixture-uuid',
  binary: { path: 'fixture/Cyberpunk2077', uuid: 'fixture-uuid' },
  hooks: Object.fromEntries(hooks.map(([name, hash, rva]) => [name, {
    hash,
    candidates: rva.map((candidateRva) => ({
      rva: candidateRva,
      function_start: true,
      confidence: 'high',
      evidence: ['fixture candidate'],
      string_args: [0]
    }))
  }]))
};
fs.writeFileSync(path, JSON.stringify(audit, null, 2) + '\n');
NODE

node - "$PROBE" "$AUDIT_JSON" "$GAME_BINARY" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const probePath = process.argv[2];
const auditPath = process.argv[3];
const gameBinary = process.argv[4];
const probe = require(probePath);

const expectedHooks = [
  'CGameApplication_AddState',
  'Global_ExecuteProcess',
  'CBaseEngine_InitScripts',
  'CBaseEngine_LoadScripts',
  'ScriptValidator_Validate',
  'AssertionFailed',
  'GameInstance_CollectSaveableSystems',
  'GsmState_SessionActive_ReportErrorCode'
];

class Pointer {
  constructor(value) { this.value = BigInt(value); }
  add(value) { return new Pointer(this.value + BigInt(value)); }
  isNull() { return this.value === 0n; }
  toString() { return `0x${this.value.toString(16)}`; }
  readCString() { return 'selected fixture string'; }
  readUtf8String() { return 'selected fixture string'; }
}

const rejectedAddress = '0x100003000';
const expectedAddresses = new Set([
  '0x100001000', '0x100002000', '0x100002100', '0x100003000', '0x100004000',
  '0x100005000', '0x10060ffb8', '0x100007000', '0x100008000'
]);

function createRuntime(output, attached, pendingCallbacks) {
  let writerClosed = false;
  return {
    enumerateModules() {
      return [{ name: 'Cyberpunk2077', base: new Pointer('0x100000000') }];
    },
    readText(path) {
      return fs.readFileSync(path, 'utf8');
    },
    createWriter() {
      return {
        writeLine(line) {
          if (writerClosed) throw new Error('file is closed');
          output.push(line);
        },
        close() { writerClosed = true; }
      };
    },
    attach(address, callbacks) {
      const rendered = address.toString();
      attached.push(rendered);
      if (rendered === rejectedAddress) {
        throw new Error('fixture attach failure');
      }
      pendingCallbacks.push(callbacks);
      return { detach() {} };
    },
    writerWasClosed() {
      return writerClosed;
    }
  };
}

function invokeCallbacks(pendingCallbacks) {
  for (const callbacks of pendingCallbacks) {
    callbacks.onEnter([
      new Pointer('0x200000000'),
      new Pointer('0x0')
    ]);
    callbacks.onLeave(new Pointer('0x1234'));
  }
}

function recordsFrom(output) {
  return output.map((line) => JSON.parse(line));
}

const before = crypto.createHash('sha256').update(fs.readFileSync(gameBinary)).digest('hex');
delete process.env.RED4EXT_GOG_HOOKS;

const noAllowlistOutput = [];
const noAllowlistAttached = [];
const noAllowlistCallbacks = [];
const noAllowlistRuntime = createRuntime(
  noAllowlistOutput,
  noAllowlistAttached,
  noAllowlistCallbacks
);
const noAllowlistResult = probe.runProbe({
  auditPath,
  tracePath: '/fixture/trace-no-allowlist.ndjson',
  runtime: noAllowlistRuntime
});

if (noAllowlistRuntime.writerWasClosed()) {
  throw new Error('writer closed before deferred callbacks ran without an allowlist');
}
if (noAllowlistResult.attached !== 0 || noAllowlistAttached.length !== 0) {
  throw new Error(`probe attached hooks without an allowlist: ${noAllowlistAttached}`);
}
const noAllowlistRecords = recordsFrom(noAllowlistOutput);
const filteredWithoutAllowlist = noAllowlistRecords.filter((entry) =>
  entry.type === 'metadata' && entry.event === 'hook_filtered'
);
if (filteredWithoutAllowlist.length !== expectedHooks.length) {
  throw new Error(
    `expected every hook to be filtered without an allowlist: ${JSON.stringify(filteredWithoutAllowlist)}`
  );
}
if (filteredWithoutAllowlist.some((entry) => !expectedHooks.includes(entry.hook))) {
  throw new Error(`filtered metadata named an unknown hook: ${JSON.stringify(filteredWithoutAllowlist)}`);
}
if (filteredWithoutAllowlist.some((entry) =>
  !Array.isArray(entry.hook_allowlist) || entry.hook_allowlist.length !== 0
)) {
  throw new Error(`no-allowlist metadata exposed an unexpected allowlist: ${JSON.stringify(filteredWithoutAllowlist)}`);
}
if (noAllowlistRecords.some((entry) => entry.event === 'hook_skipped_ambiguous')) {
  throw new Error('ambiguous-hook metadata was emitted for filtered hooks');
}

process.env.RED4EXT_GOG_HOOKS = expectedHooks.join(',');
const defaultOutput = [];
const defaultAttached = [];
const defaultCallbacks = [];
const defaultRuntime = createRuntime(defaultOutput, defaultAttached, defaultCallbacks);
const defaultResult = probe.runProbe({
  auditPath,
  tracePath: '/fixture/trace.ndjson',
  maxObservations: 3,
  probeAmbiguous: false,
  runtime: defaultRuntime
});

if (defaultRuntime.writerWasClosed()) {
  throw new Error('writer closed before deferred callbacks ran');
}
if (JSON.stringify(defaultResult.targets) !== JSON.stringify(expectedHooks)) {
  throw new Error(`probe did not inspect every required hook: ${JSON.stringify(defaultResult.targets)}`);
}
if (defaultResult.attached !== 6) {
  throw new Error(`expected six unambiguous attachments after one failure, got ${defaultResult.attached}`);
}
if (defaultAttached.includes('0x100002000') || defaultAttached.includes('0x100002100')) {
  throw new Error(`default probe attached ambiguous candidates: ${defaultAttached}`);
}
if (defaultAttached.some((address) => !expectedAddresses.has(address))) {
  throw new Error(`probe attached an address absent from audit JSON: ${defaultAttached}`);
}

let defaultRecords = recordsFrom(defaultOutput);
const ambiguousSkip = defaultRecords.find((entry) =>
  entry.type === 'metadata'
  && entry.event === 'hook_skipped_ambiguous'
  && entry.hook === 'Global_ExecuteProcess'
);
if (!ambiguousSkip || ambiguousSkip.candidate_count !== 2 || ambiguousSkip.probe_ambiguous !== false) {
  throw new Error(`ambiguous hook skip metadata was incomplete: ${JSON.stringify(ambiguousSkip)}`);
}
if (defaultResult.errors.some((entry) => entry.hook === 'Global_ExecuteProcess')) {
  throw new Error('default probe attempted to attach an ambiguous hook');
}

invokeCallbacks(defaultCallbacks);
defaultRecords = recordsFrom(defaultOutput);

const after = crypto.createHash('sha256').update(fs.readFileSync(gameBinary)).digest('hex');

if (before !== after) throw new Error('probe mutated the game binary fixture');
if (defaultResult.observationCount !== 3) {
  throw new Error(`observation limit was not enforced: ${defaultResult.observationCount}`);
}
if (!defaultResult.errors.some((entry) => entry.hook === 'CBaseEngine_InitScripts')) {
  throw new Error('attach failure was not isolated and reported');
}

const observations = defaultRecords.filter((entry) => entry.type === 'observation');
if (observations.length !== 3) throw new Error('unexpected NDJSON observation count');
for (const observation of observations) {
  for (const field of ['binary_uuid', 'hook', 'candidate_rva', 'call_count', 'argument_pointers', 'selected_strings', 'return_value']) {
    if (!(field in observation)) throw new Error(`observation lacks ${field}`);
  }
}
if (!observations.some((entry) => entry.selected_strings.arg0 === 'selected fixture string')) {
  throw new Error('safe selected string was not recorded');
}
if (!defaultRecords.some((entry) => entry.type === 'attach_error')) {
  throw new Error('NDJSON did not record the isolated attach error');
}

const optInOutput = [];
const optInAttached = [];
const optInCallbacks = [];
const optInRuntime = createRuntime(optInOutput, optInAttached, optInCallbacks);
const previousOptIn = process.env.RED4EXT_GOG_PROBE_AMBIGUOUS;
process.env.RED4EXT_GOG_PROBE_AMBIGUOUS = '1';
let optInResult;
try {
  optInResult = probe.runProbe({
    auditPath,
    tracePath: '/fixture/trace-opt-in.ndjson',
    runtime: optInRuntime
  });
} finally {
  if (previousOptIn === undefined) delete process.env.RED4EXT_GOG_PROBE_AMBIGUOUS;
  else process.env.RED4EXT_GOG_PROBE_AMBIGUOUS = previousOptIn;
}

if (optInResult.attached !== 8) {
  throw new Error(`explicit ambiguous opt-in did not attach all usable candidates: ${optInResult.attached}`);
}
if (!optInAttached.includes('0x100002000') || !optInAttached.includes('0x100002100')) {
  throw new Error(`explicit ambiguous opt-in did not attempt both candidates: ${optInAttached}`);
}
if (!optInResult.errors.some((entry) => entry.hook === 'CBaseEngine_InitScripts')) {
  throw new Error('opt-in attach failure was not isolated and reported');
}
if (recordsFrom(optInOutput).some((entry) => entry.event === 'hook_skipped_ambiguous')) {
  throw new Error('explicit ambiguous opt-in still emitted a skip');
}

process.env.RED4EXT_GOG_HOOKS = ' , CBaseEngine_LoadScripts , ';
const selectedOutput = [];
const selectedAttached = [];
const selectedCallbacks = [];
const selectedRuntime = createRuntime(selectedOutput, selectedAttached, selectedCallbacks);
const selectedResult = probe.runProbe({
  auditPath,
  tracePath: '/fixture/trace-selected.ndjson',
  runtime: selectedRuntime
});

if (selectedResult.attached !== 1 || JSON.stringify(selectedAttached) !== JSON.stringify(['0x100004000'])) {
  throw new Error(`allowlist selected unexpected hooks: ${JSON.stringify(selectedAttached)}`);
}
const selectedRecords = recordsFrom(selectedOutput);
const filteredSelected = selectedRecords.filter((entry) =>
  entry.type === 'metadata' && entry.event === 'hook_filtered'
);
if (filteredSelected.length !== expectedHooks.length - 1) {
  throw new Error(`allowlist filtered the wrong number of hooks: ${JSON.stringify(filteredSelected)}`);
}
if (filteredSelected.some((entry) => entry.hook === 'CBaseEngine_LoadScripts')) {
  throw new Error('allowlisted hook was reported as filtered');
}
if (filteredSelected.some((entry) => !expectedHooks.includes(entry.hook))) {
  throw new Error(`allowlist filtered an unknown hook: ${JSON.stringify(filteredSelected)}`);
}
if (filteredSelected.some((entry) =>
  JSON.stringify(entry.hook_allowlist) !== JSON.stringify(['CBaseEngine_LoadScripts'])
)) {
  throw new Error(`filtered metadata did not preserve the selected allowlist: ${JSON.stringify(filteredSelected)}`);
}

console.log('red4ext GOG trace dry-run passed');
NODE

node --check "$PROBE"

if rg -n 'Memory\.(write|copy|pro[dt]ected)|Interceptor\.replace|NativeCallback' "$PROBE"; then
    fail "probe contains a game-memory mutation or replacement primitive"
fi

AFTER_HASH="$(shasum -a 256 "$GAME_BINARY")"
[ "$BEFORE_HASH" = "$AFTER_HASH" ] || fail "probe changed the game binary on disk"

echo "red4ext GOG trace test passed"
