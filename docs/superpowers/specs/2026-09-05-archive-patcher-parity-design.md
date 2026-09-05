# Archive patcher parity: correct record transplant and plan-based verification

Date: 2026-09-05
Status: Approved design, not yet implemented

## Problem

`cp2077-patcher` rewrites the game's official Mac archives in place to make mod
resources win. When it replaces a record it keeps the **stock** record's 56 index
bytes and overwrites only three things: `segmentsStart`, `segmentsEnd`, and the
SHA-1. Everything else in the record still describes the stock resource while the
payload is the mod's.

Measured across the 33 archives in `enabled/`:

| Condition | Records |
|---|---|
| Records overriding a stock resource | 20,298 |
| Overrides whose inline-buffer count differs from stock | 336 |
| Overrides whose mod record carries dependencies (dropped) | 23 |
| Overrides that keep stock dependencies the mod does not declare | 220 |
| Overrides whose timestamp differs from stock | 20,298 |
| Overrides whose hash exists in more than one stock archive | 75 |

Three further defects compound this:

1. **Conflict priority is inverted.** Mods are patched sequentially, so the last
   mod to touch a hash wins. Windows resolves ASCII order with the *first*
   archive winning. Currently latent: the only 2 cross-mod overlaps have
   identical payload SHA-1s.
2. **Only one owner of a duplicated hash is patched.** `resolveOwners` takes the
   lexicographically first stock archive per hash and ignores the rest, without
   establishing that the depot reads that copy.
3. **Verification cannot detect any of this.** `verify` checks index CRC, index
   alignment, and file-size alignment. All of the above pass.

No in-game symptom has been observed. These are latent correctness defects.

## Constraints established by experiment

Two probe launches settled the platform's loading rules. Both used a pure-override
mod (`Sasha_UI.archive`, 26 override records, 0 new records) installed as a single
loose archive in `archive/Mac/content/`, with every official archive left pristine:

| Probe filename | Sorts | Override applied? |
|---|---|---|
| `0_probe_sasha.archive` | before all official archives | No |
| `basegame_99_probe_sasha.archive` | after all official archives | No |

New-content mods (hairstyles, clothing) delivered through `basegame_99_*` loose
archives **do** load and work.

**Conclusion:** on macOS a loose archive can contribute new resources but can
never override a resource that already exists in an official archive, at any sort
position. Rewriting official archives in place is therefore the only mechanism
available for overrides, and the existing architecture is justified.

This also means Windows parity is a matter of matching the observable *outcome*,
not the mechanism. Windows' "first archive wins" must be reproduced by choosing a
single winner before writing, because the write mechanism itself is last-wins.

## Non-goals

- **ArchiveXL, TweakXL, CET, native plugins.** RED4ext's own hooking is dead on
  this install: all 7 function hashes it needs are absent from
  `cyberpunk2077_addresses.json`, every `DetourAttach` fails, and
  `red4ext/plugins/` is empty. `.archive.xl` sidecars remain unsupported.
- **Consolidating loose archives** (audit #5). Whole-mod copies under
  `basegame_99_*` waste space, and their override records are inert, but nothing
  is incorrect. Deferred.
- **Transactional backups and pruning** (audit #7). Deferred.
- Changing the pristine-restore model in the shell scripts.

## Design

### The plan is the shared artifact

A `PatchPlan` is computed before any file is modified, and is consumed by both
`patch` and `verify`. Patching without a plan is what allowed each defect above;
verifying without one is why none were caught.

```
PatchPlan
  winners:      [hash: WinningRecord]      // one mod record per hash
  officialWork: [archiveURL: [hash]]       // every stock owner of every winner
  newResources: [hash]                     // absent from all official archives

WinningRecord
  hash:        UInt64
  modArchive:  URL                          // which mod won
  record:      RDARRecord                   // the source record, verbatim
  dependencies:[UInt64]                     // resolved from the mod's dep table
```

Construction:

1. Read every official archive once; build `hash -> [owning archive URLs]`.
2. Walk mods in ASCII filename order, matching `sort -z` in `inject_archives.sh`.
   For each record, if the hash is unclaimed, claim it. **First mod wins**; later
   mods are recorded as losers and reported, never applied. This reproduces
   Windows semantics under a last-wins write mechanism.
3. Partition claimed hashes: those with at least one official owner become
   `officialWork` entries for **every** owner; those with none become
   `newResources`.

Patching every owner sidesteps the unresolved question of which copy the depot
reads. Whichever it picks now carries mod data. This costs more archive writes
(75 records across the current mod set) and needs no further experiment.

The planner performs no writes and needs no game install beyond readable
archives, so it is unit-testable in isolation.

### Patching is grouped by target archive

Today `patchHybrid` runs per mod, and each mod patches each official archive it
touches, so an official archive is opened, backed up, and rewritten once per
*(mod, archive)* pair. That is why a 33-mod run produced 678 backup directories.

Under the plan, work is grouped by target archive: each official archive is
backed up and rewritten **once per run**, applying the winning records from every
mod that targets it. This is a consequence of planning first, not a separate
feature, and it drops backup directories from hundreds to at most one per
modified archive. It does not replace audit #7, which remains deferred — backups
are still per-archive rather than one manifest per run.

This requires changing `patch(source:targetURL:requests:)`, which assumes a
single source archive. Each request must instead carry its own source archive and
file handle, since records applied to one target now originate from several mods.

### Record transplant: source is the base

For a replaced record, write the **source record's 56 bytes verbatim**, then fix
up only the fields that are necessarily archive-local:

| Bytes | Field | Action |
|---|---|---|
| 0–7 | `nameHash` | from source (identical by definition) |
| 8–15 | `timestamp` | from source |
| 16–19 | `numInlineBufferSegments` | from source |
| 20–23 | `segmentsStart` | rewritten: index into target segment table |
| 24–27 | `segmentsEnd` | rewritten: index into target segment table |
| 28–31 | `dependenciesStart` | rewritten: index into target dependency table |
| 32–35 | `dependenciesEnd` | rewritten: index into target dependency table |
| 36–55 | `sha1` | from source |

Inverting the default is the substance of this change. The current code takes the
target record as the base and overwrites named fields, which is exactly how both
`numInlineBufferSegments` and `timestamp` were missed. With the source as the
base there is no list of fields to forget: only the two range pairs, which are
meaningless outside their own archive, are computed.

Records that already have identical duplicates within the target archive continue
to receive the same treatment at every offset where the hash appears.

### Dependency table

Verified empirically across all 57 pristine archives:

- Entries are 8 bytes, a `UInt64` resource hash. `7118/7210` entries in
  `basegame_1_engine.archive` resolve to records present in the install.
- Each record owns a contiguous, unshared slice; ranges are never deduplicated
  between records.
- `max(dependenciesEnd) == dependencyCount` exactly; the table is last in the
  index, after the segment table.

`RDARArchive` gains a parsed `dependencies: [UInt64]` alongside `records` and
`segments`, replacing today's treatment of the region as opaque bytes.

Because the table is last and slices are unshared, appending is safe: the winning
record's dependency hashes are appended to the target's table and the record's
range points at the appended slice. Existing ranges are untouched. Stale stock
dependencies stop being inherited (220 records), and mod dependencies stop being
dropped (23 records).

This also removes `unsupportedDependencyInsert`, the error that currently rejects
inserting any record carrying dependencies.

### Index header

The index header must account for appended dependency bytes. Confirmed layout:

| Offset | Field | Currently updated? |
|---|---|---|
| 0 | header size (`8`) | n/a |
| 4 | `indexSize - 8` | yes — must also add dependency bytes |
| 8 | CRC-64 over `index[16...]` | yes |
| 16 | `fileEntryCount` | yes |
| 20 | `fileSegmentCount` | yes |
| 24 | `dependencyCount` | **no — must be added** |

`dependencyCount` at offset 24 is never written by the current code. Appending
dependencies without updating it produces an index whose CRC is valid and whose
dependency count is wrong, which is worse than today's behaviour. The buffer
allocation for the rebuilt index must likewise include the new dependency bytes.

### Verification

`verify` recomputes the plan and compares the bytes on disk against it, replacing
the current CRC-and-alignment-only check. Per patched record:

- `nameHash`, `timestamp`, `numInlineBufferSegments`, `sha1` equal the planned
  source record.
- The resolved dependency hashes equal the planned dependency list, in order.
- `segmentsStart <= segmentsEnd <= fileSegmentCount`.
- `dependenciesStart <= dependenciesEnd <= dependencyCount`.
- Each referenced segment's `offset + compressedSize` lies within the file.
- Segment count matches the source record's.

Archive-level checks retained: index CRC, index-position alignment, file-size
alignment. Added: header counts agree with the actual table sizes, and every
record the plan designates a winner is present in every owning archive.

Output distinguishes "matches plan", "differs from plan", and "unpatched stock
record", so a partial or crashed run is legible rather than a wall of `OK`.

### Repository layout

The Swift package moves from `~/Downloads/cp2077-mac-archive-patcher-f619246` to
`/Users/ivk/Games/Heroic/CP2077 Archive Patcher`, a sibling of the runtime and the
game. It keeps its own git history, including the uncommitted `patch-hashes`
command currently in the working tree.

The runtime repo's README gains a section naming that path, the build command,
and the fact that `cp2077-patcher` here is a build artifact of it. The shipped
binary is presently byte-identical (SHA-256 `9a9b718e…`) to that tree's **debug**
build; builds after this change should be `-c release`.

## Testing

No test suite exists beyond `HashTests.swift`, and in-game observation cannot
detect these defects — that is why verification is in scope.

1. **Planner unit tests** (pure, no install): first-wins resolution with a
   synthetic conflict; multi-owner hashes yielding work for every owner;
   new-versus-override partitioning.
2. **Dependency round-trip tests**: parse and re-serialize a real archive's
   dependency table byte-for-byte; append a slice and confirm existing ranges and
   `dependencyCount` stay consistent.
3. **Transplant assertion**: for a patched record, all six source-owned fields
   equal the source's, byte for byte.
4. **End-to-end**: full inject over the 33 enabled mods, then `verify`. Expect
   every planned record to report "matches plan", including the 336 inline-buffer
   and 243 dependency cases that motivated this work.
5. **Regression guard**: `restore_archives.sh` returns all 57 archives to sizes
   matching `pristine/`, as the probe runs already confirmed.
6. **In-game smoke test**: one launch to confirm no visible regression. Not a
   correctness check — the defects are invisible on screen.

## Risks

- **Larger archive growth.** Patching every owner of a duplicated hash writes
  more archives. Bounded: 75 records in the current set. Disk headroom is ~24 GiB
  and backups are clone-shared and swept by `restore_archives.sh`.
- **Appending dependencies is new write territory.** A wrong `dependencyCount` or
  buffer size corrupts the index. Mitigated by round-trip tests before any
  append, and by verify checking counts against actual table sizes.
- **First-wins changes which mod applies** where two mods overlap. Currently 2
  hashes with identical SHA-1s, so no observable change now; the losing mod will
  be reported rather than silently applied.
- **Debug-to-release build switch** could surface latent undefined behaviour.
  Verify the release binary against the same install before adopting it.

## Deferred

- Loose-archive consolidation (audit #5)
- Transactional backup manifest and pruning (audit #7)
- `.archive.xl` / ArchiveXL support (audit #8) — blocked on RED4ext hooking
- Building a real Mac address database to revive RED4ext native hooks
