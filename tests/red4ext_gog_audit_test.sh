#!/usr/bin/env bash
# Fixture coverage for the read-only GOG Mach-O/ARM64 audit.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANALYZER="$REPOSITORY_DIR/tools/red4ext_gog_audit.py"
WORK_DIR="$(mktemp -d /private/tmp/red4ext-gog-audit-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

FIXTURE="$WORK_DIR/Cyberpunk2077"
REPORT="$WORK_DIR/audit.json"

# This is a deliberately small, hand-built arm64 Mach-O.  The expected values
# below are literals so a parser that mirrors its own calculations cannot make
# the test pass accidentally.
python3 - "$FIXTURE" <<'PY'
import struct
import sys

out = sys.argv[1]
base = 0x100000000
text_rva = 0x100
text_fileoff = 0x400
cstring_rva = 0x1000
cstring_fileoff = 0xC00
function_starts = [text_rva + 0x40 * index for index in range(8)]
strings = [
    b"CGameApplication::AddState",
    b"Global::ExecuteProcess",
    b"CBaseEngine::InitScripts",
    b"CBaseEngine::LoadScripts",
    b"ScriptValidator::Validate",
    b"AssertionFailed",
    b"GameInstance::CollectSaveableSystems",
    b"GsmState_SessionActive::ReportErrorCode",
]

def pack_command(cmd, payload):
    return struct.pack("<II", cmd, 8 + len(payload)) + payload

def c_string(value, offset):
    return struct.pack("<16s16sQQIIIIIII", b"__cstring", b"__TEXT", base + cstring_rva + offset,
                       len(value) + 1, cstring_fileoff + offset, 0, 0, 0, 0, 0, 0, 0)

def adrp(pc, target, register=0):
    delta_pages = ((target & ~0xFFF) - (pc & ~0xFFF)) >> 12
    immediate = delta_pages & 0x1FFFFF
    return 0x90000000 | ((immediate & 0x3) << 29) | (((immediate >> 2) & 0x7FFFF) << 5) | register

def add_immediate(register=0, immediate=0):
    return 0x91000000 | (immediate << 10) | (register << 5) | register

text = bytearray(0x800)
cstrings = bytearray()
for index, value in enumerate(strings):
    string_offset = len(cstrings)
    cstrings.extend(value + b"\0")
    start = text_rva + 0x40 * index
    file_index = start - text_rva
    pc = base + start
    words = [
        0xA9BF7BFD,  # stp x29, x30, [sp, #-0x10]!
        adrp(pc + 4, base + cstring_rva + string_offset),
        add_immediate(immediate=string_offset),
        0x94000000,  # bl (a valid ARM64 branch encoding)
        0xD65F03C0,  # ret
    ]
    text[file_index:file_index + 4 * len(words)] = b"".join(struct.pack("<I", word) for word in words)

# An instruction-looking sequence and hook string at a non-start address must
# not turn into a candidate.  It is placed outside all candidate function
# windows so the test isolates function-start validation.
decoy_rva = 0x500
decoy_file_index = decoy_rva - text_rva
text[decoy_file_index:decoy_file_index + 4] = struct.pack("<I", 0xA9BF7BFD)

uuid = bytes.fromhex("00112233445566778899aabbccddeeff")
commands = []
segment_payload = struct.pack(
    "<16sQQQQiiII",
    b"__TEXT", base, 0x2000, 0, 0x2000, 7, 5, 2, 0
)
text_section = struct.pack(
    "<16s16sQQIIIIIIII",
    b"__text", b"__TEXT", base + text_rva, len(text), text_fileoff, 2,
    0, 0, 0x80000400, 0, 0, 0
)
cstring_section = struct.pack(
    "<16s16sQQIIIIIIII",
    b"__cstring", b"__TEXT", base + cstring_rva, len(cstrings), cstring_fileoff, 0,
    0, 0, 0x00000002, 0, 0, 0
)
commands.append(pack_command(0x19, segment_payload + text_section + cstring_section))
commands.append(pack_command(0x1B, uuid))
# LC_BUILD_VERSION: platform macOS, minimum 14.0, SDK 14.2.
commands.append(pack_command(0x32, struct.pack("<IIII", 1, 0x000E0000, 0x000E0200, 0)))

encoded_starts = bytearray()
previous = 0
for start in function_starts:
    delta = start - previous
    previous = start
    while True:
        byte = delta & 0x7F
        delta >>= 7
        if delta:
            encoded_starts.append(byte | 0x80)
        else:
            encoded_starts.append(byte)
            break
encoded_starts.append(0)
function_dataoff = 0x1400
commands.append(pack_command(0x26, struct.pack("<II", function_dataoff, len(encoded_starts))))

header = struct.pack(
    "<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, len(commands),
    sum(len(command) for command in commands), 0, 0
)
image = bytearray(function_dataoff + len(encoded_starts))
image[:len(header)] = header
cursor = len(header)
for command in commands:
    image[cursor:cursor + len(command)] = command
    cursor += len(command)
image[text_fileoff:text_fileoff + len(text)] = text
image[cstring_fileoff:cstring_fileoff + len(cstrings)] = cstrings
image[function_dataoff:function_dataoff + len(encoded_starts)] = encoded_starts
with open(out, "wb") as stream:
    stream.write(image)
PY

python3 "$ANALYZER" "$FIXTURE" --json "$REPORT"

python3 - "$REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
expected_hooks = {
    "CGameApplication_AddState": ("FBC216B3", "CGameApplication::AddState", "1:0x100"),
    "Global_ExecuteProcess": ("835D1F2F", "Global::ExecuteProcess", "1:0x140"),
    "CBaseEngine_InitScripts": ("AB652585", "CBaseEngine::InitScripts", "1:0x180"),
    "CBaseEngine_LoadScripts": ("D4CB1D59", "CBaseEngine::LoadScripts", "1:0x1C0"),
    "ScriptValidator_Validate": ("359024C2", "ScriptValidator::Validate", "1:0x200"),
    "AssertionFailed": ("FF6B0CB1", "AssertionFailed", "1:0x240"),
    "GameInstance_CollectSaveableSystems": (
        "C0886390", "GameInstance::CollectSaveableSystems", "1:0x280"
    ),
    "GsmState_SessionActive_ReportErrorCode": (
        "7FA31576", "GsmState_SessionActive::ReportErrorCode", "1:0x2C0"
    ),
}

assert report["architecture"] == "arm64"
assert report["uuid"] == "00112233-4455-6677-8899-aabbccddeeff"
assert report["version"]["platform"] == "macos"
assert report["version"]["minimum_os"] == "14.0.0"
assert report["version"]["sdk"] == "14.2.0"
assert report["function_starts"] == [
    "1:0x100", "1:0x140", "1:0x180", "1:0x1C0",
    "1:0x200", "1:0x240", "1:0x280", "1:0x2C0",
]
assert set(report["hooks"]) == set(expected_hooks)

function_starts = set(report["function_starts"])
for name, (expected_hash, needle, expected_offset) in expected_hooks.items():
    hook = report["hooks"][name]
    assert hook["hash"] == expected_hash
    assert hook["candidates"], name
    candidate = hook["candidates"][0]
    assert candidate["offset"] == expected_offset
    assert candidate["offset"] in function_starts
    assert candidate["confidence"] == "high"
    assert any(needle in evidence for evidence in candidate["evidence"])
    assert any("instruction: adrp" in evidence for evidence in candidate["evidence"])
    assert any("instruction: add" in evidence for evidence in candidate["evidence"])

# The legacy AssertionFailed location is an evidence hint only.  It is not a
# candidate unless it is a real LC_FUNCTION_STARTS entry.
assert report["hooks"]["AssertionFailed"]["legacy_offsets"] == ["1:0x60FFB8"]
assert all(candidate["offset"] != "1:0x60ffb8" for candidate in report["hooks"]["AssertionFailed"]["candidates"])
assert all(candidate["offset"] != "1:0x500" for hook in report["hooks"].values() for candidate in hook["candidates"])
PY

echo "red4ext GOG audit test passed"
