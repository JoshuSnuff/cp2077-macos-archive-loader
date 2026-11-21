#!/usr/bin/env python3
"""Static, read-only RED4ext detour audit for the macOS GOG executable.

The audit deliberately treats the existing Steam offsets as hints, never as
answers.  A candidate is emitted only when its address comes from a valid
LC_FUNCTION_STARTS entry in the arm64 __text section and the surrounding code
contains both a hook-specific string reference and a recognizable arm64
function shape.

Only the Python standard library is used.  The parser handles thin and fat
64-bit Mach-O files directly; ``otool`` is not required for the static audit.
"""

from __future__ import annotations

import argparse
from bisect import bisect_right
import json
import os
import struct
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_UUID = 0x1B
LC_VERSION_MIN_MACOSX = 0x24
LC_FUNCTION_STARTS = 0x26
LC_SOURCE_VERSION = 0x2A
LC_BUILD_VERSION = 0x32

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

ARM64_PROLOGUE_MASK = 0xFFC00000
ARM64_PROLOGUE = 0xA9800000
ARM64_ADRP_MASK = 0x9F000000
ARM64_ADRP = 0x90000000
ARM64_ADR_MASK = 0x9F000000
ARM64_ADR = 0x10000000
ARM64_ADD_IMMEDIATE_MASK = 0x7F000000
ARM64_ADD_IMMEDIATE = 0x11000000
ARM64_LDR_LITERAL_MASK = 0x3B000000
ARM64_LDR_LITERAL = 0x18000000
ARM64_BL_MASK = 0xFC000000
ARM64_BL = 0x94000000
ARM64_RET_MASK = 0xFFFFFC1F
ARM64_RET = 0xD65F0000


class AuditError(Exception):
    """An input that cannot be safely analyzed."""


@dataclass(frozen=True)
class HookSpec:
    name: str
    hash_hex: str
    legacy_offsets: Tuple[str, ...]
    string_needles: Tuple[str, ...]
    instruction_kinds: Tuple[str, ...]


# Main is an observer entry point in the existing Frida table, not one of the
# eight native RED4ext detour targets recovered by this audit.  Keep this list
# explicit and ordered: Task 3 consumes the same order when it builds a DB.
HOOK_SPECS: Tuple[HookSpec, ...] = (
    HookSpec(
        "CGameApplication_AddState",
        "FBC216B3",
        ("1:0x3F22E98",),
        ("CGameApplication::AddState", "AddState", "CGameApplication"),
        ("prologue", "bl"),
    ),
    HookSpec(
        "Global_ExecuteProcess",
        "835D1F2F",
        ("1:0x1D46808",),
        ("Global::ExecuteProcess", "ExecuteProcess"),
        ("adrp", "add", "bl"),
    ),
    HookSpec(
        "CBaseEngine_InitScripts",
        "AB652585",
        ("1:0x3D8C1A0",),
        ("CBaseEngine::InitScripts", "InitScripts", "CBaseEngine"),
        ("prologue", "bl"),
    ),
    HookSpec(
        "CBaseEngine_LoadScripts",
        "D4CB1D59",
        ("1:0x3D9A03C",),
        ("CBaseEngine::LoadScripts", "LoadScripts", "CBaseEngine"),
        ("prologue", "bl"),
    ),
    HookSpec(
        "ScriptValidator_Validate",
        "359024C2",
        ("1:0x3D96BFC",),
        ("ScriptValidator::Validate", "ScriptValidator", "Validate"),
        ("adrp", "add", "ret"),
    ),
    HookSpec(
        "AssertionFailed",
        "FF6B0CB1",
        # This is retained as a legacy evidence hint only.  It must never be
        # emitted without an independently valid function-start entry.
        ("1:0x60FFB8",),
        ("AssertionFailed", "assertion failed", "Assertion failed", "assert"),
        ("prologue", "ret"),
    ),
    HookSpec(
        "GameInstance_CollectSaveableSystems",
        "C0886390",
        ("1:0x87FEC",),
        (
            "GameInstance::CollectSaveableSystems",
            "CollectSaveableSystems",
            "GameInstance",
        ),
        ("adrp", "add", "bl"),
    ),
    HookSpec(
        "GsmState_SessionActive_ReportErrorCode",
        "7FA31576",
        ("1:0x3F5E9B0",),
        (
            "GsmState_SessionActive::ReportErrorCode",
            "ReportErrorCode",
            "SessionActive",
        ),
        ("prologue", "bl"),
    ),
)


@dataclass(frozen=True)
class Section:
    segment_name: str
    name: str
    address: int
    size: int
    file_offset: int
    flags: int


@dataclass(frozen=True)
class Segment:
    name: str
    vm_address: int
    vm_size: int
    file_offset: int
    file_size: int
    sections: Tuple[Section, ...]


@dataclass(frozen=True)
class FunctionStart:
    rva: int
    vm_address: int
    file_offset: int
    end_rva: int


@dataclass(frozen=True)
class FunctionInspection:
    referenced_strings: Tuple[str, ...]
    nearby_strings: Tuple[str, ...]
    instruction_evidence: Tuple[str, ...]


@dataclass
class MachOImage:
    data: bytes
    slice_offset: int
    endian: str
    architecture: str
    segments: Tuple[Segment, ...]
    uuid: Optional[str]
    version: Dict[str, Optional[str]]
    function_starts_raw: Tuple[int, ...]
    function_starts: Tuple[FunctionStart, ...]
    invalid_function_starts: Tuple[Dict[str, object], ...]
    text_segment: Segment
    text_section: Section
    cstring_sections: Tuple[Section, ...]

    @property
    def text_rva(self) -> int:
        return self.text_section.address - self.text_segment.vm_address


def _read_struct(data: bytes, offset: int, format_string: str, endian: str):
    size = struct.calcsize(endian + format_string)
    if offset < 0 or offset + size > len(data):
        raise AuditError("Mach-O structure extends past the input file")
    return struct.unpack_from(endian + format_string, data, offset)


def _decode_name(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("ascii", errors="replace")


def _format_version(value: int) -> str:
    major = (value >> 16) & 0xFFFF
    minor = (value >> 8) & 0xFF
    patch = value & 0xFF
    return f"{major}.{minor}.{patch}"


def _format_source_version(value: int) -> str:
    components = [
        (value >> 40) & 0xFFFFFF,
        (value >> 30) & 0x3FF,
        (value >> 20) & 0x3FF,
        (value >> 10) & 0x3FF,
        value & 0x3FF,
    ]
    while len(components) > 1 and components[-1] == 0:
        components.pop()
    return ".".join(str(component) for component in components)


def _platform_name(platform: int) -> str:
    return {
        1: "macos",
        2: "ios",
        3: "tvos",
        4: "watchos",
        5: "bridgeos",
        6: "macos-catalyst",
        7: "ios-simulator",
        8: "tvos-simulator",
        9: "watchos-simulator",
        10: "driverkit",
    }.get(platform, f"platform-{platform}")


def _decode_uleb128(data: bytes, offset: int) -> Tuple[int, int]:
    value = 0
    shift = 0
    for _ in range(10):
        if offset >= len(data):
            raise AuditError("truncated LC_FUNCTION_STARTS ULEB128 data")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, offset
        shift += 7
    raise AuditError("LC_FUNCTION_STARTS contains an overlong ULEB128 value")


def _select_macho_slice(data: bytes) -> Tuple[bytes, int, str, str]:
    if len(data) < 4:
        raise AuditError("input is too small to be a Mach-O file")

    little_magic = struct.unpack_from("<I", data, 0)[0]
    big_magic = struct.unpack_from(">I", data, 0)[0]
    if little_magic == MH_MAGIC_64:
        return data, 0, "<", "arm64"
    if big_magic == MH_MAGIC_64:
        return data, 0, ">", "arm64"

    fat_endian: Optional[str] = None
    fat_magic: Optional[int] = None
    if little_magic in (FAT_MAGIC, FAT_MAGIC_64):
        fat_endian, fat_magic = "<", little_magic
    elif big_magic in (FAT_MAGIC, FAT_MAGIC_64):
        fat_endian, fat_magic = ">", big_magic
    if fat_endian is None or fat_magic is None:
        raise AuditError("input is not a supported 64-bit Mach-O or fat Mach-O")

    (architecture_count,) = _read_struct(data, 4, "I", fat_endian)
    cursor = 8
    for _ in range(architecture_count):
        if fat_magic == FAT_MAGIC:
            cputype, _subtype, offset, size, _align = _read_struct(
                data, cursor, "iiIII", fat_endian
            )
            cursor += struct.calcsize(fat_endian + "iiIII")
        else:
            cputype, _subtype, offset, size, _align, _reserved = _read_struct(
                data, cursor, "iiQQII", fat_endian
            )
            cursor += struct.calcsize(fat_endian + "iiQQII")
        if cputype != CPU_TYPE_ARM64:
            continue
        if offset + size > len(data):
            raise AuditError("arm64 fat slice extends past the input file")
        slice_data = data[offset:offset + size]
        if len(slice_data) < 4:
            raise AuditError("arm64 fat slice is empty")
        slice_little = struct.unpack_from("<I", slice_data, 0)[0]
        slice_big = struct.unpack_from(">I", slice_data, 0)[0]
        if slice_little == MH_MAGIC_64:
            return slice_data, offset, "<", "arm64"
        if slice_big == MH_MAGIC_64:
            return slice_data, offset, ">", "arm64"
        raise AuditError("arm64 fat slice is not a 64-bit Mach-O image")
    raise AuditError("fat Mach-O does not contain an arm64 slice")


def _parse_macho_commands(
    data: bytes, endian: str
) -> Tuple[Tuple[Segment, ...], Optional[str], Dict[str, Optional[str]], Optional[Tuple[int, int]]]:
    magic, cputype, _cpusubtype, _filetype, ncmds, sizeofcmds, _flags, _reserved = _read_struct(
        data, 0, "IiiIIIII", endian
    )
    if magic != MH_MAGIC_64:
        raise AuditError("unsupported Mach-O magic")
    if cputype != CPU_TYPE_ARM64:
        raise AuditError("Mach-O image is not arm64")
    commands_end = 32 + sizeofcmds
    if commands_end > len(data):
        raise AuditError("Mach-O load commands extend past the input file")

    segments: List[Segment] = []
    uuid: Optional[str] = None
    version: Dict[str, Optional[str]] = {
        "platform": None,
        "minimum_os": None,
        "sdk": None,
        "source": None,
    }
    function_data: Optional[Tuple[int, int]] = None
    cursor = 32
    for _ in range(ncmds):
        command, command_size = _read_struct(data, cursor, "II", endian)
        if command_size < 8 or cursor + command_size > commands_end:
            raise AuditError("invalid Mach-O load command size")

        if command == LC_SEGMENT_64:
            if command_size < 72:
                raise AuditError("truncated LC_SEGMENT_64 command")
            (
                _command,
                _command_size,
                raw_name,
                vm_address,
                vm_size,
                file_offset,
                file_size,
                _max_protection,
                _initial_protection,
                section_count,
                _segment_flags,
            ) = _read_struct(data, cursor, "II16sQQQQiiII", endian)
            section_cursor = cursor + 72
            sections: List[Section] = []
            for _ in range(section_count):
                (
                    raw_section_name,
                    raw_section_segment,
                    address,
                    size,
                    section_file_offset,
                    _alignment,
                    _relocation_offset,
                    _relocation_count,
                    section_flags,
                    _reserved1,
                    _reserved2,
                    _reserved3,
                ) = _read_struct(data, section_cursor, "16s16sQQIIIIIIII", endian)
                sections.append(
                    Section(
                        _decode_name(raw_section_segment),
                        _decode_name(raw_section_name),
                        address,
                        size,
                        section_file_offset,
                        section_flags,
                    )
                )
                section_cursor += 80
            expected_size = 72 + 80 * section_count
            if command_size < expected_size:
                raise AuditError("LC_SEGMENT_64 section table is truncated")
            segments.append(
                Segment(
                    _decode_name(raw_name),
                    vm_address,
                    vm_size,
                    file_offset,
                    file_size,
                    tuple(sections),
                )
            )
        elif command == LC_UUID:
            if command_size < 24:
                raise AuditError("truncated LC_UUID command")
            raw_uuid = data[cursor + 8:cursor + 24]
            uuid = "-".join(
                (
                    raw_uuid[0:4].hex(),
                    raw_uuid[4:6].hex(),
                    raw_uuid[6:8].hex(),
                    raw_uuid[8:10].hex(),
                    raw_uuid[10:16].hex(),
                )
            )
        elif command == LC_BUILD_VERSION:
            if command_size < 24:
                raise AuditError("truncated LC_BUILD_VERSION command")
            _command, _size, platform, minimum_os, sdk, _tool_count = _read_struct(
                data, cursor, "IIIIII", endian
            )
            version["platform"] = _platform_name(platform)
            version["minimum_os"] = _format_version(minimum_os)
            version["sdk"] = _format_version(sdk)
        elif command == LC_VERSION_MIN_MACOSX:
            if command_size < 16:
                raise AuditError("truncated LC_VERSION_MIN_MACOSX command")
            _command, _size, minimum_os, sdk = _read_struct(data, cursor, "IIII", endian)
            version["platform"] = "macos"
            version["minimum_os"] = _format_version(minimum_os)
            version["sdk"] = _format_version(sdk)
        elif command == LC_SOURCE_VERSION:
            if command_size < 16:
                raise AuditError("truncated LC_SOURCE_VERSION command")
            (_command, _size, source_version) = _read_struct(data, cursor, "IIQ", endian)
            version["source"] = _format_source_version(source_version)
        elif command == LC_FUNCTION_STARTS:
            if command_size < 16:
                raise AuditError("truncated LC_FUNCTION_STARTS command")
            _command, _size, data_offset, data_size = _read_struct(
                data, cursor, "IIII", endian
            )
            if data_offset + data_size > len(data):
                raise AuditError("LC_FUNCTION_STARTS data extends past the input file")
            function_data = (data_offset, data_size)
        cursor += command_size

    if not segments:
        raise AuditError("Mach-O image has no segments")
    return tuple(segments), uuid, version, function_data


def _parse_function_starts(
    data: bytes,
    endian: str,
    function_data: Optional[Tuple[int, int]],
    text_segment: Segment,
    text_section: Section,
) -> Tuple[Tuple[int, ...], Tuple[FunctionStart, ...], Tuple[Dict[str, object], ...]]:
    if function_data is None:
        return (), (), ()
    data_offset, data_size = function_data
    encoded = data[data_offset:data_offset + data_size]
    cursor = 0
    address = 0
    raw_starts: List[int] = []
    while cursor < len(encoded):
        delta, cursor = _decode_uleb128(encoded, cursor)
        if delta == 0:
            break
        address += delta
        raw_starts.append(address)

    text_rva = text_section.address - text_segment.vm_address
    text_end = text_rva + text_section.size
    valid: List[FunctionStart] = []
    invalid: List[Dict[str, object]] = []
    for rva in raw_starts:
        reason: Optional[str] = None
        if rva % 4 != 0:
            reason = "not-4-byte-aligned"
        elif rva < text_rva or rva >= text_end:
            reason = "outside-__text"
        else:
            file_offset = text_section.file_offset + rva - text_rva
            if file_offset < 0 or file_offset + 4 > len(data):
                reason = "outside-file"
        if reason is not None:
            invalid.append({"rva": rva, "offset": _format_offset(rva), "reason": reason})
            continue
        valid.append(
            FunctionStart(
                rva,
                text_segment.vm_address + rva,
                text_section.file_offset + rva - text_rva,
                text_end,
            )
        )

    valid.sort(key=lambda item: item.rva)
    with_ends: List[FunctionStart] = []
    for index, function in enumerate(valid):
        next_rva = valid[index + 1].rva if index + 1 < len(valid) else text_end
        with_ends.append(
            FunctionStart(function.rva, function.vm_address, function.file_offset, next_rva)
        )
    return tuple(raw_starts), tuple(with_ends), tuple(invalid)


def parse_macho(data: bytes) -> MachOImage:
    """Parse the supported Mach-O metadata and validated function starts."""

    image_data, slice_offset, endian, architecture = _select_macho_slice(data)
    segments, uuid, version, function_data = _parse_macho_commands(image_data, endian)
    text_segment = next((segment for segment in segments if segment.name == "__TEXT"), None)
    if text_segment is None:
        raise AuditError("Mach-O image has no __TEXT segment")
    text_section = next(
        (section for section in text_segment.sections if section.name == "__text"), None
    )
    if text_section is None or text_section.size == 0:
        raise AuditError("Mach-O image has no non-empty __TEXT,__text section")
    if text_section.file_offset + text_section.size > len(image_data):
        raise AuditError("__TEXT,__text extends past the input file")
    cstring_sections = tuple(
        section
        for segment in segments
        for section in segment.sections
        if section.name in ("__cstring", "__const") and section.size
    )
    raw_starts, function_starts, invalid_starts = _parse_function_starts(
        image_data, endian, function_data, text_segment, text_section
    )
    return MachOImage(
        image_data,
        slice_offset,
        endian,
        architecture,
        segments,
        uuid,
        version,
        raw_starts,
        function_starts,
        invalid_starts,
        text_segment,
        text_section,
        cstring_sections,
    )


def _format_offset(rva: int) -> str:
    return f"1:0x{rva:X}"


def _sign_extend(value: int, bits: int) -> int:
    sign_bit = 1 << (bits - 1)
    return (value ^ sign_bit) - sign_bit


def _decode_adrp(word: int, pc: int) -> Optional[Tuple[int, int]]:
    if word & ARM64_ADRP_MASK != ARM64_ADRP:
        return None
    immediate = ((word >> 29) & 0x3) | (((word >> 5) & 0x7FFFF) << 2)
    immediate = _sign_extend(immediate, 21) << 12
    target = (pc & ~0xFFF) + immediate
    return word & 0x1F, target


def _decode_adr(word: int, pc: int) -> Optional[Tuple[int, int]]:
    if word & ARM64_ADR_MASK != ARM64_ADR:
        return None
    immediate = ((word >> 29) & 0x3) | (((word >> 5) & 0x7FFFF) << 2)
    immediate = _sign_extend(immediate, 21)
    return word & 0x1F, pc + immediate


def _decode_add_immediate(word: int) -> Optional[Tuple[int, int, int]]:
    if word & ARM64_ADD_IMMEDIATE_MASK != ARM64_ADD_IMMEDIATE:
        return None
    destination = word & 0x1F
    source = (word >> 5) & 0x1F
    immediate = (word >> 10) & 0xFFF
    if word & (1 << 22):
        immediate <<= 12
    return destination, source, immediate


def _decode_ldr_literal(word: int, pc: int) -> Optional[Tuple[int, int]]:
    if word & ARM64_LDR_LITERAL_MASK != ARM64_LDR_LITERAL:
        return None
    immediate = _sign_extend((word >> 5) & 0x7FFFF, 19) << 2
    return word & 0x1F, pc + immediate


def _is_prologue(word: int) -> bool:
    return word & ARM64_PROLOGUE_MASK == ARM64_PROLOGUE


def _is_bl(word: int) -> bool:
    return word & ARM64_BL_MASK == ARM64_BL


def _is_ret(word: int) -> bool:
    return word & ARM64_RET_MASK == ARM64_RET


def _extract_ascii_strings(data: bytes, base_address: int) -> Dict[int, str]:
    strings: Dict[int, str] = {}
    start: Optional[int] = None
    for index, byte in enumerate(data + b"\0"):
        printable = 0x20 <= byte < 0x7F
        if printable and start is None:
            start = index
        elif not printable and start is not None:
            if index - start >= 3:
                strings[base_address + start] = data[start:index].decode("ascii", errors="replace")
            start = None
    return strings


def _string_at(
    strings: Dict[int, str], address: int, string_starts: Sequence[int]
) -> Optional[str]:
    index = bisect_right(string_starts, address) - 1
    if index < 0:
        return None
    start = string_starts[index]
    value = strings[start]
    if start <= address < start + len(value) + 1:
        return value
    return None


def _image_strings(image: MachOImage) -> Dict[int, str]:
    """Return only strings that can provide evidence for a required hook."""

    strings: Dict[int, str] = {}
    needles = tuple(
        needle.lower() for spec in HOOK_SPECS for needle in spec.string_needles
    )
    for section in image.cstring_sections:
        end = section.file_offset + section.size
        if end > len(image.data):
            continue
        for address, value in _extract_ascii_strings(
            image.data[section.file_offset:end], section.address
        ).items():
            if any(needle in value.lower() for needle in needles):
                strings[address] = value
    return strings


def _inspect_function(
    image: MachOImage,
    function: FunctionStart,
) -> FunctionInspection:
    text_end = image.text_section.file_offset + image.text_section.size
    function_end = image.text_section.file_offset + function.end_rva - image.text_rva
    file_end = min(function_end, text_end)
    function_data = image.data[function.file_offset:file_end]
    instruction_evidence: List[str] = []
    for word_offset in range(0, len(function_data) - 3, 4):
        word = struct.unpack_from(image.endian + "I", function_data, word_offset)[0]
        pc = function.vm_address + word_offset
        if (adrp := _decode_adrp(word, pc)) is not None:
            register, target = adrp
            instruction_evidence.append(f"instruction: adrp x{register} -> 0x{target:X}")
            continue
        if (adr := _decode_adr(word, pc)) is not None:
            register, target = adr
            instruction_evidence.append(f"instruction: adr x{register} -> 0x{target:X}")
            continue
        add = _decode_add_immediate(word)
        if add is not None:
            destination, source, immediate = add
            evidence = f"instruction: add x{destination}, x{source}, #0x{immediate:X}"
            instruction_evidence.append(evidence)
            continue
        ldr = _decode_ldr_literal(word, pc)
        if ldr is not None:
            register, target = ldr
            instruction_evidence.append(
                f"instruction: ldr literal x{register} -> 0x{target:X}"
            )
            continue
        if _is_prologue(word):
            instruction_evidence.append("instruction: stp stack-frame prologue")
        if _is_bl(word):
            instruction_evidence.append("instruction: bl call")
        if _is_ret(word):
            instruction_evidence.append("instruction: ret")

    return FunctionInspection(
        (),
        (),
        tuple(dict.fromkeys(instruction_evidence)),
    )


def _scan_string_references(
    image: MachOImage, strings: Dict[int, str]
) -> Dict[int, Dict[str, Tuple[str, ...]]]:
    """Scan __text once and retain references only for hook strings."""

    if not strings or not image.function_starts:
        return {}
    string_starts = tuple(sorted(strings))
    text_start = image.text_section.file_offset
    text_end = text_start + image.text_section.size
    text_data = image.data[text_start:text_end]
    word_count = len(text_data) // 4
    references: Dict[int, Dict[str, List[str]]] = {}
    function_index = -1
    register_targets: Dict[int, int] = {}

    for word_index, (word,) in enumerate(
        struct.iter_unpack(image.endian + "I", text_data[:word_count * 4])
    ):
        rva = image.text_rva + word_index * 4
        while (
            function_index + 1 < len(image.function_starts)
            and image.function_starts[function_index + 1].rva <= rva
        ):
            function_index += 1
            register_targets.clear()
        if function_index < 0:
            continue
        function = image.function_starts[function_index]
        if rva >= function.end_rva:
            continue
        pc = function.vm_address + (rva - function.rva)
        target: Optional[int] = None
        adrp = _decode_adrp(word, pc)
        if adrp is not None:
            register, target = adrp
            register_targets[register] = target
        else:
            adr = _decode_adr(word, pc)
            if adr is not None:
                register, target = adr
                register_targets[register] = target
            else:
                add = _decode_add_immediate(word)
                if add is not None:
                    destination, source, immediate = add
                    if source in register_targets:
                        target = register_targets[source] + immediate
                        register_targets[destination] = target
                else:
                    ldr = _decode_ldr_literal(word, pc)
                    if ldr is not None:
                        _register, target = ldr
        if target is None:
            continue
        value = _string_at(strings, target, string_starts)
        if value is None:
            continue
        for spec in HOOK_SPECS:
            if not any(needle.lower() in value.lower() for needle in spec.string_needles):
                continue
            hook_references = references.setdefault(function.rva, {})
            values = hook_references.setdefault(spec.name, [])
            if value not in values:
                values.append(value)
    return {
        rva: {name: tuple(values) for name, values in hooks.items()}
        for rva, hooks in references.items()
    }


def _candidate_for_hook(
    image: MachOImage,
    function: FunctionStart,
    spec: HookSpec,
    inspection: FunctionInspection,
    referenced_strings: Sequence[str],
) -> Optional[Dict[str, object]]:
    instruction_evidence = inspection.instruction_evidence
    matched_strings: List[str] = []
    string_specificity: Dict[str, int] = {}
    reference_values = list(referenced_strings)
    for value in reference_values:
        matches = [
            len(needle)
            for needle in spec.string_needles
            if needle.lower() in value.lower()
        ]
        if matches:
            matched_strings.append(value)
            string_specificity[value] = max(string_specificity.get(value, 0), max(matches))
    if not matched_strings:
        return None

    instruction_kinds = set()
    if any(evidence.startswith("instruction: stp") for evidence in instruction_evidence):
        instruction_kinds.add("prologue")
    if any(evidence.startswith("instruction: adrp") for evidence in instruction_evidence):
        instruction_kinds.add("adrp")
    if any(evidence.startswith("instruction: add") for evidence in instruction_evidence):
        instruction_kinds.add("add")
    if any(evidence.startswith("instruction: bl") for evidence in instruction_evidence):
        instruction_kinds.add("bl")
    if any(evidence.startswith("instruction: ret") for evidence in instruction_evidence):
        instruction_kinds.add("ret")
    matched_rules = instruction_kinds.intersection(spec.instruction_kinds)
    if not matched_rules:
        return None

    evidence: List[str] = [f"string: {value}" for value in dict.fromkeys(matched_strings)]
    evidence.extend(instruction_evidence)
    evidence.append(
        "rule: " + ", ".join(spec.instruction_kinds) + " with hook-specific string evidence"
    )
    evidence = list(dict.fromkeys(evidence))
    score = (
        4
        + sum(string_specificity.values())
        + len(matched_rules)
        + len(set(instruction_evidence))
    )
    confidence = "high" if len(matched_rules) >= 2 and reference_values else "medium"
    return {
        "offset": _format_offset(function.rva),
        "rva": function.rva,
        "vm_address": f"0x{function.vm_address:X}",
        "file_offset": image.slice_offset + function.file_offset,
        "confidence": confidence,
        "score": score,
        "evidence": evidence,
    }


def _legacy_offset_status(image: MachOImage, offset: str) -> Dict[str, object]:
    try:
        prefix, hexadecimal = offset.split(":0x", 1)
        rva = int(hexadecimal, 16)
    except ValueError:
        return {"offset": offset, "function_start": False, "reason": "malformed-offset"}
    starts = {function.rva for function in image.function_starts}
    return {
        "offset": offset,
        "function_start": rva in starts,
        "reason": "valid-function-start" if rva in starts else "not-lc-function-start",
    }


def analyze_bytes(data: bytes, binary_name: str = "<memory>") -> Dict[str, object]:
    """Return a JSON-serializable audit report for one Mach-O image."""

    image = parse_macho(data)
    strings = _image_strings(image)
    hook_references = _scan_string_references(image, strings)
    function_starts = [_format_offset(function.rva) for function in image.function_starts]
    functions_by_rva = {function.rva: function for function in image.function_starts}
    inspections = {
        rva: _inspect_function(image, functions_by_rva[rva])
        for rva in hook_references
        if rva in functions_by_rva
    }
    hooks: Dict[str, Dict[str, object]] = {}
    for spec in HOOK_SPECS:
        candidates: List[Dict[str, object]] = []
        for rva, references in hook_references.items():
            function = functions_by_rva.get(rva)
            inspection = inspections.get(rva)
            if function is None or inspection is None:
                continue
            candidate = _candidate_for_hook(
                image, function, spec, inspection, references.get(spec.name, ())
            )
            if candidate is not None:
                candidates.append(candidate)
        candidates.sort(key=lambda item: (-int(item["score"]), int(item["rva"])))
        confidence = candidates[0]["confidence"] if candidates else "none"
        hook_evidence: List[str] = []
        for candidate in candidates:
            hook_evidence.extend(candidate["evidence"])
        hooks[spec.name] = {
            "hash": spec.hash_hex,
            "hash_decimal": int(spec.hash_hex, 16),
            "legacy_offsets": list(spec.legacy_offsets),
            "legacy_offset_status": [
                _legacy_offset_status(image, offset) for offset in spec.legacy_offsets
            ],
            "confidence": confidence,
            "evidence": list(dict.fromkeys(hook_evidence)),
            "candidates": candidates,
        }

    version = dict(image.version)
    segments = [
        {
            "name": segment.name,
            "vm_address": f"0x{segment.vm_address:X}",
            "vm_size": segment.vm_size,
            "file_offset": image.slice_offset + segment.file_offset,
            "file_size": segment.file_size,
        }
        for segment in image.segments
    ]
    report: Dict[str, object] = {
        "format": "red4ext-gog-audit/v1",
        "binary": binary_name,
        "architecture": image.architecture,
        "uuid": image.uuid,
        "binary_uuid": image.uuid,
        "version": version,
        "version_metadata": version,
        "text": {
            "segment": image.text_segment.name,
            "section": image.text_section.name,
            "vm_address": f"0x{image.text_segment.vm_address:X}",
            "rva": image.text_rva,
            "size": image.text_section.size,
        },
        "segments": segments,
        "function_starts": function_starts,
        "invalid_function_starts": list(image.invalid_function_starts),
        "hooks": hooks,
        "required_hooks": [spec.name for spec in HOOK_SPECS],
    }
    return report


def analyze_binary(path: Path) -> Dict[str, object]:
    with path.open("rb") as stream:
        return analyze_bytes(stream.read(), str(path))


def _write_json_atomically(output: Path, payload: Dict[str, object]) -> None:
    output_parent = output.parent
    if not output_parent.exists():
        raise AuditError(f"JSON output directory does not exist: {output_parent}")
    temporary_path: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=output_parent,
            prefix=f".{output.name}.",
            suffix=".tmp",
            delete=False,
        ) as stream:
            temporary_path = stream.name
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, output)
        temporary_path = None
    finally:
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="installed arm64 Mach-O executable")
    parser.add_argument(
        "--json",
        required=True,
        type=Path,
        dest="output",
        help="explicit output path for the JSON audit report",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _argument_parser().parse_args(argv)
    try:
        report = analyze_binary(args.binary)
        _write_json_atomically(args.output, report)
    except (AuditError, OSError, ValueError, struct.error) as error:
        print(f"red4ext_gog_audit: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
