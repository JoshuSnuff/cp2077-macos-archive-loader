# Consolidate new resources into one deterministic loose archive

Date: 2026-09-05
Status: Approved design, not yet implemented
Depends on: `2026-09-05-archive-patcher-parity-design.md` (requires `PatchPlan`
and parsed dependency tables)

## Problem

Resources a mod adds that do not exist in any official archive cannot be patched
into one, so they are delivered as loose `basegame_99_*.archive` files. The
current implementation, `installLooseArchive`, copies the **entire mod archive**
under a sanitized name.

Three consequences:

**Dead weight.** A whole-mod copy carries every record, but only the new ones can
ever be read from it — a probe on 2026-09-05 established that a loose archive
cannot override a resource owned by an official archive, at any sort position.
Across the 33 enabled mods there are 56,754 records: 36,456 new and 20,298
overrides. So roughly 36% of the records in the loose archives are the only ones
doing anything, and the override payloads are copied to disk to be ignored.

**Nondeterministic naming.** Names derive from a lowercased, regex-sanitized mod
filename, with a `_2`, `_3` suffix appended on collision. Two mods whose names
sanitize identically get order-dependent filenames, so the set of files on disk
depends on injection order.

**One file per contributing mod.** Load order among loose archives is then
governed by those sanitized names, an ordering nobody chose.

The distribution is lopsided: `#Change_Vs_native_Language-French.archive` alone
supplies 36,296 of the 36,456 new records.

## Goals

- One loose archive per run, with a fixed name.
- It contains exactly the resources the plan marks as new, and nothing else.
- Conflicts among new resources resolve by the same first-wins rule as overrides.

## Non-goals

- Changing how overrides work — that is the parity spec's concern.
- Splitting output between `content/` and `ep1/`. All new resources continue to
  go to `content/`, which is where the current code puts them and where
  new-content mods are confirmed working. Changing this would need its own probe.
- Compressing or re-encoding payloads. Segments are copied verbatim.

## Design

### Output

A single archive at
`$CP2077_GAME_DIR/archive/Mac/content/basegame_99_cp2077_runtime.archive`.

The `basegame_99_` prefix is retained deliberately: `restore_archives.sh` and
`restore_pristine()` in `inject_archives.sh` both sweep `basegame_99_*`, so
cleanup keeps working untouched. With exactly one loose archive, ordering among
loose archives stops existing as a question.

Contents: for every hash in `PatchPlan.newResources`, the winning mod's record and
its segment payloads. The plan already resolves winners by ASCII mod order, so a
hash added by two mods takes the first mod's copy and the loser is reported.

### An RDAR writer is new capability

The patcher today only ever appends to an existing archive and rewrites its
index. Emitting a fresh archive requires a writer:

1. **Header, 52 bytes.** Only three fields are understood: `indexPosition` at
   offset 8, `indexSize` at 16, `fileSize` at 32. The remaining bytes are copied
   verbatim from a template — the header of the mod archive contributing the most
   records — and the three known fields overwritten. Fabricating bytes whose
   meaning we have not established is how silent corruption gets introduced.

2. **Payload.** Segments appended in record order, each copied byte-for-byte from
   its source mod. Segment table entries record the new offsets with
   `compressedSize` and `size` carried over unchanged.

3. **Index**, at a 4096-aligned offset: a 28-byte header, then the record table
   sorted by `nameHash`, then the segment table, then the dependency table.
   Records are written whole from their source, with only `segmentsStart`/`End`
   and `dependenciesStart`/`End` rewritten to index the new tables — the same
   source-is-the-base rule the parity spec establishes for overrides.

4. **Index header fields**: offset 0 = `8`, offset 4 = `indexSize - 8`, offset 8 =
   CRC-64 over `index[16...]`, offset 16 = record count, offset 20 = segment
   count, offset 24 = dependency count.

5. **Alignment.** Index position and total file size are padded to 4096, matching
   what `verify` already checks and what the existing append path does.

Dependencies of new records are carried into the new dependency table. This is
only possible once the parity work lands: today `unsupportedDependencyInsert`
rejects inserting any record that has dependencies.

### Replacing the copy path

`installLooseArchive(_ sourceURL:)` — which copies one mod and returns its
destination — is replaced by a single call that takes the whole plan and emits
one archive. Because it is now driven by the plan rather than by a per-mod loop,
it runs once per injection rather than once per contributing mod, and the
`_2`/`_3` collision suffixes disappear along with the sanitized names.

### Verification

`verify` gains checks for the consolidated archive:

- Every hash in `PatchPlan.newResources` is present exactly once.
- No hash present in it is owned by any official archive — that record would be
  inert, and its presence means the planner and writer disagree.
- Record count, segment count, and dependency count in the index header match the
  actual table sizes.
- Every segment's `offset + compressedSize` lies within the file.
- Index CRC matches; index position and file size are 4096-aligned.

## Testing

The writer is the risk, so it is tested before it is trusted.

1. **Round-trip.** Parse an existing mod archive and re-emit it from the parsed
   structures using the same writer. The result must be semantically identical:
   same records with same field values, same segment payload bytes, valid CRC.
   This exercises the writer against known-good data where any deviation is
   unambiguous.
2. **Single-mod equivalence.** For a mod that is entirely new resources, the
   consolidated archive should carry the same record set as today's whole-mod
   copy, minus nothing.
3. **Multi-mod merge.** Two mods contributing new resources produce one archive
   with the union of their records, sorted by hash.
4. **New-resource conflict.** Two mods adding the same new hash: first mod by
   ASCII order wins, loser reported, hash present exactly once.
5. **Dependency carriage.** A new record with a non-empty dependency list retains
   the same dependency hashes, in order, in the output.
6. **End-to-end.** Full inject over the 33 enabled mods yields exactly one
   `basegame_99_*` file; `verify` passes; `restore_archives.sh` removes it and
   returns all 57 archives to pristine sizes.
7. **In-game smoke test.** Confirm new-content mods — hairstyles, Jinguji
   clothing, nails — still appear. This is the one defect class that *is* visible
   on screen, unlike the parity work's.

## Risks

- **Writing an archive from scratch is riskier than copying one.** A malformed
  index that still passes CRC would load wrongly rather than fail loudly.
  Mitigated by the round-trip test, and by the header-template approach avoiding
  invented bytes.
- **Unknown header fields may carry per-archive meaning.** Copying them from a
  contributing mod is a guess, if a better-founded one than zeroing them. If new
  resources fail to load, this is the first thing to suspect.
- **The French localization mod dominates**, at 36,296 of 36,456 new records. Any
  writer bug will surface there first and most visibly, which makes it a useful
  canary but also means a regression is not subtle.
- **Regression in new-content delivery** is user-visible in a way the parity work
  is not. The in-game smoke test is not optional here.
