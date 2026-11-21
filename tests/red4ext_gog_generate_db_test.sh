#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$REPOSITORY_DIR/tools/red4ext_gog_generate_db.py"
WORK_DIR="$(mktemp -d /private/tmp/red4ext-gog-generate-db-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

AUDIT="$WORK_DIR/audit.json"
TRACE="$WORK_DIR/trace.ndjson"
UUID="11111111-2222-3333-4444-555555555555"

python3 - "$AUDIT" "$TRACE" "$UUID" <<'PY'
import json
import sys

audit_path, trace_path, binary_uuid = sys.argv[1:]
hooks = [
    ("CGameApplication_AddState", "4223801011"),
    ("Global_ExecuteProcess", "2203918127"),
    ("CBaseEngine_InitScripts", "2875532677"),
    ("CBaseEngine_LoadScripts", "3570081113"),
    ("ScriptValidator_Validate", "898639042"),
    ("AssertionFailed", "4285205681"),
    ("GameInstance_CollectSaveableSystems", "3230163856"),
    ("GsmState_SessionActive_ReportErrorCode", "2141394294"),
]

function_starts = [0x4000 + index * 0x100 for index in range(len(hooks))]
audit = {
    "binary": "/fixture/Cyberpunk2077",
    "binary_uuid": binary_uuid,
    "game_version": "2.3.1",
    "function_starts": function_starts,
    "hooks": {},
}
trace = []
for index, (name, hash_value) in enumerate(hooks):
    rva = function_starts[index]
    audit["hooks"][name] = {
        "hash": hash_value,
        "candidates": [
            {
                "rva": rva,
                "function_start": True,
                "confidence": "high",
                "evidence": ["fixture pattern match"],
            }
        ],
    }
    trace.append({
        "binary_uuid": binary_uuid,
        "hook": name,
        "candidate_rva": rva,
        "call_count": 3,
    })

with open(audit_path, "w", encoding="utf-8") as stream:
    json.dump(audit, stream, indent=2)
    stream.write("\n")
with open(trace_path, "w", encoding="utf-8") as stream:
    for observation in trace:
        json.dump(observation, stream)
        stream.write("\n")
PY

ANALYZER_AUDIT="$WORK_DIR/analyzer-audit.json"
ANALYZER_TRACE="$WORK_DIR/analyzer-trace.ndjson"
python3 - "$AUDIT" "$ANALYZER_AUDIT" "$ANALYZER_TRACE" "$UUID" <<'PY'
import json
import sys

source_path, audit_path, trace_path, binary_uuid = sys.argv[1:]
with open(source_path, encoding="utf-8") as stream:
    source = json.load(stream)

audit = {
    "format": "red4ext-gog-audit/v1",
    "binary": source["binary"],
    "architecture": "arm64",
    "uuid": binary_uuid,
    "binary_uuid": binary_uuid,
    "version": {"platform": "macos", "minimum_os": "14.0.0", "sdk": "14.2.0"},
    "version_metadata": {"platform": "macos", "minimum_os": "14.0.0", "sdk": "14.2.0"},
    "game_version": source["game_version"],
    "text": {"segment": "__TEXT", "section": "__text", "rva": 0, "size": 0x1000},
    "function_starts": [f"1:0x{rva:X}" for rva in source["function_starts"]],
    "invalid_function_starts": [],
    "hooks": {},
    "required_hooks": list(source["hooks"]),
}
trace = []
for name, hook in source["hooks"].items():
    rva = hook["candidates"][0]["rva"]
    hash_hex = f"{int(hook['hash']):08X}"
    audit["hooks"][name] = {
        "hash": hash_hex,
        "hash_decimal": int(hash_hex, 16),
        "legacy_offsets": [],
        "legacy_offset_status": [],
        "confidence": "high",
        "evidence": ["fixture pattern match"],
        "candidates": [
            {
                "offset": f"1:0x{rva:X}",
                "rva": rva,
                "vm_address": f"0x{rva + 0x100000:X}",
                "file_offset": rva + 0x200,
                "confidence": "high",
                "score": 9,
                "evidence": ["fixture pattern match"],
            }
        ],
    }
    trace.append({
        "type": "observation",
        "binary_uuid": binary_uuid,
        "hook": name,
        "hash": f"0x{hash_hex}",
        "candidate_rva": f"1:0x{rva:X}",
        "call_count": 3,
    })

with open(audit_path, "w", encoding="utf-8") as stream:
    json.dump(audit, stream, indent=2)
    stream.write("\n")
with open(trace_path, "w", encoding="utf-8") as stream:
    for observation in trace:
        json.dump(observation, stream)
        stream.write("\n")
PY

run_generator() {
    local audit_path="$1"
    local trace_path="$2"
    local output_path="$3"
    python3 "$GENERATOR" "$audit_path" "$trace_path" \
        --output "$output_path" --require-all
}

assert_output_unchanged() {
    local output_path="$1"
    local expected="$2"
    [ -f "$output_path" ] || fail "rejected generation removed $output_path"
    [ "$(cat "$output_path")" = "$expected" ] \
        || fail "rejected generation modified $output_path"
}

# --- A complete, evidenced audit produces exactly eight address records ------
SUCCESS_OUTPUT="$WORK_DIR/success.json"
run_generator "$AUDIT" "$TRACE" "$SUCCESS_OUTPUT" \
    || fail "complete audit and trace were rejected"
python3 - "$SUCCESS_OUTPUT" "$UUID" <<'PY'
import json
import sys

output_path, expected_uuid = sys.argv[1:]
with open(output_path, encoding="utf-8") as stream:
    database = json.load(stream)

assert database["game_version"] == "2.3.1"
assert database["binary_uuid"] == expected_uuid
assert database["stats"] == {"total": 8, "resolved": 8, "unresolved": 0}
addresses = database["Addresses"]
assert len(addresses) == 8
assert [record["offset"] for record in addresses] == [
    "1:0x4000",
    "1:0x4100",
    "1:0x4200",
    "1:0x4300",
    "1:0x4400",
    "1:0x4500",
    "1:0x4600",
    "1:0x4700",
]
assert all(record["hash"].isdigit() for record in addresses)
PY

# --- The real analyzer schema's bare hexadecimal hashes are accepted ---------
ANALYZER_OUTPUT="$WORK_DIR/analyzer-output.json"
run_generator "$ANALYZER_AUDIT" "$ANALYZER_TRACE" "$ANALYZER_OUTPUT" \
    || fail "analyzer-shaped bare hexadecimal hashes were rejected"
python3 - "$ANALYZER_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    database = json.load(stream)

assert database["stats"] == {"total": 8, "resolved": 8, "unresolved": 0}
assert [record["hash"] for record in database["Addresses"]] == [
    "4223801011",
    "2203918127",
    "2875532677",
    "3570081113",
    "898639042",
    "4285205681",
    "3230163856",
    "2141394294",
]
assert [record["offset"] for record in database["Addresses"]] == [
    "1:0x4000",
    "1:0x4100",
    "1:0x4200",
    "1:0x4300",
    "1:0x4400",
    "1:0x4500",
    "1:0x4600",
    "1:0x4700",
]
PY

# --- A malformed analyzer hash remains rejected atomically -------------------
MALFORMED_AUDIT="$WORK_DIR/malformed-analyzer-audit.json"
python3 - "$ANALYZER_AUDIT" "$MALFORMED_AUDIT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    audit = json.load(stream)
audit["hooks"]["AssertionFailed"]["hash"] = "FF6B0CB?"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(audit, stream)
    stream.write("\n")
PY
MALFORMED_OUTPUT="$WORK_DIR/malformed-output.json"
printf 'keep malformed output\n' > "$MALFORMED_OUTPUT"
MALFORMED_BEFORE="$(cat "$MALFORMED_OUTPUT")"
if run_generator "$MALFORMED_AUDIT" "$ANALYZER_TRACE" "$MALFORMED_OUTPUT" >"$WORK_DIR/malformed.stderr" 2>&1; then
    fail "malformed analyzer hash was accepted"
fi
assert_output_unchanged "$MALFORMED_OUTPUT" "$MALFORMED_BEFORE"
grep -q "hash" "$WORK_DIR/malformed.stderr" \
    || fail "malformed-hash error was not reported"

# --- Missing required hooks refuse an existing output atomically -------------
MISSING_AUDIT="$WORK_DIR/missing-audit.json"
python3 - "$AUDIT" "$MISSING_AUDIT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    audit = json.load(stream)
audit["hooks"].pop("AssertionFailed")
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(audit, stream)
    stream.write("\n")
PY
MISSING_OUTPUT="$WORK_DIR/missing-output.json"
printf 'keep missing output\n' > "$MISSING_OUTPUT"
MISSING_BEFORE="$(cat "$MISSING_OUTPUT")"
if run_generator "$MISSING_AUDIT" "$TRACE" "$MISSING_OUTPUT" >"$WORK_DIR/missing.stderr" 2>&1; then
    fail "missing hook was accepted"
fi
assert_output_unchanged "$MISSING_OUTPUT" "$MISSING_BEFORE"
grep -q "AssertionFailed" "$WORK_DIR/missing.stderr" \
    || fail "missing-hook error did not name the hook"

# --- A trace for another executable is not runtime evidence ------------------
MISMATCHED_TRACE="$WORK_DIR/mismatched-trace.ndjson"
sed 's/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/' \
    "$TRACE" > "$MISMATCHED_TRACE"
MISMATCHED_OUTPUT="$WORK_DIR/mismatched-output.json"
printf 'keep mismatched output\n' > "$MISMATCHED_OUTPUT"
MISMATCHED_BEFORE="$(cat "$MISMATCHED_OUTPUT")"
if run_generator "$AUDIT" "$MISMATCHED_TRACE" "$MISMATCHED_OUTPUT" >"$WORK_DIR/mismatched.stderr" 2>&1; then
    fail "mismatched UUID was accepted"
fi
assert_output_unchanged "$MISMATCHED_OUTPUT" "$MISMATCHED_BEFORE"
grep -q "UUID" "$WORK_DIR/mismatched.stderr" \
    || fail "UUID error was not reported"

# --- A candidate not proven to be a function start is rejected ---------------
INVALID_AUDIT="$WORK_DIR/invalid-audit.json"
python3 - "$AUDIT" "$INVALID_AUDIT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    audit = json.load(stream)
audit["hooks"]["AssertionFailed"]["candidates"][0]["function_start"] = False
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(audit, stream)
    stream.write("\n")
PY
INVALID_OUTPUT="$WORK_DIR/invalid-output.json"
printf 'keep invalid output\n' > "$INVALID_OUTPUT"
INVALID_BEFORE="$(cat "$INVALID_OUTPUT")"
if run_generator "$INVALID_AUDIT" "$TRACE" "$INVALID_OUTPUT" >"$WORK_DIR/invalid.stderr" 2>&1; then
    fail "invalid function start was accepted"
fi
assert_output_unchanged "$INVALID_OUTPUT" "$INVALID_BEFORE"
grep -q "function start" "$WORK_DIR/invalid.stderr" \
    || fail "function-start error was not reported"

# --- Runtime evidence is required for every selected candidate ---------------
INCOMPLETE_TRACE="$WORK_DIR/incomplete-trace.ndjson"
head -n 7 "$TRACE" > "$INCOMPLETE_TRACE"
INCOMPLETE_OUTPUT="$WORK_DIR/incomplete-output.json"
printf 'keep incomplete output\n' > "$INCOMPLETE_OUTPUT"
INCOMPLETE_BEFORE="$(cat "$INCOMPLETE_OUTPUT")"
if run_generator "$AUDIT" "$INCOMPLETE_TRACE" "$INCOMPLETE_OUTPUT" >"$WORK_DIR/incomplete.stderr" 2>&1; then
    fail "incomplete runtime evidence was accepted"
fi
assert_output_unchanged "$INCOMPLETE_OUTPUT" "$INCOMPLETE_BEFORE"
grep -q "runtime" "$WORK_DIR/incomplete.stderr" \
    || fail "runtime-evidence error was not reported"

echo "red4ext GOG database generation test passed"
