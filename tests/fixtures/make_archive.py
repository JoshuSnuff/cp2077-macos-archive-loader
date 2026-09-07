#!/usr/bin/env python3
"""Writes a minimal but structurally valid RDAR archive.

Mirrors writeTestArchive in
patcher/Tests/CP2077ArchiveCoreTests/TestArchiveBuilder.swift:
a 52-byte header, one single-segment record per argument, a 4096-aligned index,
and a 4096-aligned file size.

usage: make_archive.py OUT.archive HASH:PAYLOAD [HASH:PAYLOAD ...]
       HASH is hexadecimal.
"""
import struct
import sys

CRC64_POLY = 0xC96C5795D7870F42
TABLE = []
for index in range(256):
    crc = index
    for _ in range(8):
        crc = (crc >> 1) ^ CRC64_POLY if crc & 1 else crc >> 1
    TABLE.append(crc)


def crc64(data):
    crc = 0xFFFFFFFFFFFFFFFF
    for byte in data:
        crc = (crc >> 8) ^ TABLE[(crc ^ byte) & 0xFF]
    return crc ^ 0xFFFFFFFFFFFFFFFF


def align_up(value, alignment):
    return ((value + alignment - 1) // alignment) * alignment


def main(argv):
    out = argv[1]
    records = []
    for spec in argv[2:]:
        name, _, payload = spec.partition(":")
        records.append((int(name, 16), payload.encode()))

    body = bytearray(52)
    placements = []
    for _, payload in records:
        placements.append((len(body), len(payload)))
        body += payload

    index_position = align_up(len(body), 4096)
    body += bytes(index_position - len(body))

    index = bytearray(28 + len(records) * 56 + len(records) * 16)
    struct.pack_into("<I", index, 0, 8)
    struct.pack_into("<I", index, 4, len(index) - 8)
    struct.pack_into("<I", index, 16, len(records))
    struct.pack_into("<I", index, 20, len(records))
    struct.pack_into("<I", index, 24, 0)

    records_offset = 28
    segments_offset = records_offset + len(records) * 56
    for i, (name_hash, _) in enumerate(records):
        offset = records_offset + i * 56
        struct.pack_into("<Q", index, offset, name_hash)
        struct.pack_into("<Q", index, offset + 8, 0)
        struct.pack_into("<I", index, offset + 16, 0)
        struct.pack_into("<I", index, offset + 20, i)
        struct.pack_into("<I", index, offset + 24, i + 1)
        struct.pack_into("<I", index, offset + 28, 0)
        struct.pack_into("<I", index, offset + 32, 0)
        index[offset + 36:offset + 56] = bytes(20)

        segment_offset = segments_offset + i * 16
        struct.pack_into("<Q", index, segment_offset, placements[i][0])
        struct.pack_into("<I", index, segment_offset + 8, placements[i][1])
        struct.pack_into("<I", index, segment_offset + 12, placements[i][1])

    struct.pack_into("<Q", index, 8, crc64(bytes(index[16:])))

    body += index
    file_size = align_up(len(body), 4096)
    body += bytes(file_size - len(body))

    body[0:4] = b"RDAR"
    struct.pack_into("<Q", body, 8, index_position)
    struct.pack_into("<I", body, 16, len(index))
    struct.pack_into("<Q", body, 32, file_size)

    with open(out, "wb") as handle:
        handle.write(bytes(body))


if __name__ == "__main__":
    main(sys.argv)
