# Release assembly

`assemble.sh` builds the distributable zip from `payload/` and `bin/archive-loader`:

    ./release/assemble.sh --version 0.1.0

It refuses when `--version` disagrees with what the binary reports, so a hand-typed
version cannot ship under the wrong name, and when the binary is missing its
`__RESTRICT` segment — without that, an ambient `DYLD_INSERT_LIBRARIES` injects the
wrapper instead of reaching the game.

Only immutable program files go in the zip. Baselines, state, mods, and logs are
created at first run inside the game directory, so extracting an update over an
existing install cannot destroy them.

## Input staging

`prepare_inputs.sh` creates a fresh package root from an explicit source map. It
validates the authoritative manifest before copying, copies only declared paths,
applies `0755` to `archive-loader/bin/archive-loader` and
`archive-loader/setup.command`, applies `0644` to every other managed file,
verifies the staged hashes, and runs the provenance contract against the
completed root.

The provenance validator expects `target-evidence.json` beside the supplied
provenance file. Production staging requires `--production`; synthetic fixtures
require the explicit `--allow-synthetic` flag and remain under
`tests/fixtures/release-inputs/synthetic/`. The staging command never writes
fixture inputs to `release/evidence/`.

Example shape:

    ./release/prepare_inputs.sh \
        --manifest /path/to/manifest.json \
        --output-root /private/tmp/archive-loader-package \
        --provenance /path/to/evidence/provenance.json \
        --source archive-loader/bin/archive-loader=/path/to/loader \
        --source archive-loader/setup.command=/path/to/setup.command \
        --production

Every manifest `packagePath` must have exactly one `--source` mapping. Existing
output roots are rejected so stale or undeclared files cannot be silently
retained. The complete temporary staging root is published with macOS's
atomic, no-replace directory rename; staged files are never moved through the
claimed output root. The temporary staging root is the only cleanup target;
after an output root is claimed, failures leave that root intact rather than
recursively deleting a path that may have been replaced by another process.

## Native preflight

`preflight.sh` records native command results without suppressing failures:

    ./release/preflight.sh run \
        --manifest /path/to/preflight-manifest.json \
        --output /path/to/preflight.json \
        --capture-dir /path/to/captures

The command manifest uses schema `archive-loader-preflight-manifest/v1` and a
`commands` array. Each command has an `id` and an `argv` string array. Commands
are executed directly without a shell, and the generated record preserves the
same structured argv.
Captured output may be supplied instead with `capturedOutput` containing
`stdoutPath`, `stderrPath`, and `exitStatus`. The generated
`archive-loader-preflight/v1` record contains the host architecture, nullable
macOS/Swift/Xcode/SDK metadata, each command's exit status, and separate
stdout/stderr paths. Each record also identifies its capture mode as `executed`
or `external`. External captures are accepted only for an explicitly opted-in
synthetic manifest; production preflight executes commands itself and rejects
external captures. `preflight.sh validate PREFLIGHT_JSON` rechecks the captured
diagnostics and record fields.

An exit status other than zero is `failed`. The literal unsupported linker
diagnostic `arm64e.x1` is always `blocked_toolchain_linker`, including when it
appears in a command that otherwise exits zero; it is never `passed`.

Production preflight requires native evidence for exactly the loader,
`red4ext/RED4ext.dylib`, and `red4ext/FridaGadget.dylib`. Each evidence item
references captured command records for `lipo -archs`,
`codesign --verify --strict`, and `codesign --display --verbose=4 --entitlements
:-`; the loader also references `otool -l`. The manifest declares an absolute
`packageRoot`; every evidence path is resolved beneath that root, its actual
bytes must match `artifactSha256`, and every native command must target that
same resolved file as its sole artifact operand. Comments, extra operands,
package-relative targets, paths outside the package root, and digest-only
bindings are rejected. Codesign verification output may be empty when
verification succeeds.

Native manifests also declare and generated records preserve a `nativeTools`
map for `codesign`, `lipo`, and `otool`. Production accepts only the canonical,
executable macOS system paths `/usr/bin/codesign`, `/usr/bin/lipo`, and
`/usr/bin/otool`; a different executable with the same basename is rejected
before it can run. Synthetic captured fixtures may declare executable temporary
stubs, but only under explicit `synthetic: true` plus `--allow-synthetic`, and
their command paths must exactly match those recorded stubs.

The display command's captured metadata and entitlement plist are parsed and
must match the recorded signing identity, Team ID, signature type, flags, and
entitlements. The contract also requires arm64 evidence, the entitlement
digest, loader `__RESTRICT`, and empty actual and recorded entitlements on both
dylibs. No signing authority or Team ID value is pinned.

Evidence-free fixtures require both a synthetic manifest marker and the
explicit `--allow-synthetic` flag. Production mode rejects that path. The
wrapper binds synthetic captures to real temporary fixture files, their hashes,
and explicitly declared stub tools. Production evidence must come from the real
package root and live pinned native commands. Synthetic manifests and their
generated preflight records are explicitly marked `synthetic: true`; those test
values are not production evidence and must remain under `tests/fixtures/`.

## Release assembly and stale output

`assemble.sh` consumes a staged package root plus `provenance.json`,
`target-evidence.json`, and `preflight.json` from the release evidence
directory. Before creating, moving, or reusing output, it runs the provenance
contract against the complete package and target evidence, validates the
preflight contract, and requires every recorded preflight command to have
passed. Production assembly therefore requires real payload, target, signing,
game metadata, and native command evidence; fixture values are accepted only
with `ARCHIVE_LOADER_ALLOW_SYNTHETIC=1` and remain test-only.

    ./release/assemble.sh --version VERSION

The resulting `release-output.json` records the exact ZIP listing and ZIP hash,
plus a canonical input identity: ordinary manifest hash, masked manifest
self-hash, sorted package-tuple hash, canonical provenance hash, canonical
preflight hash, manifest schema, and loader version. An existing ZIP is reused
only when both it and `release-output.json` exactly match that identity, hash,
and listing. A filename match alone is never considered current.

The default remains no-overwrite: stale, malformed, or one-sided output stops
assembly without changing it. An operator may explicitly request recoverable
replacement:

    ./release/assemble.sh --version VERSION --replace-existing

This moves every existing target artifact into a unique UTC-timestamped
directory beneath `build/quarantine/` before creating the replacement. It does
not delete or overwrite the old artifacts. If the quarantine directory or move
cannot be completed, assembly stops; a successfully moved ZIP is rolled back
when moving its paired evidence fails.

## Production readiness

Production inputs are acquired from the real release environment. Record an
immutable URL or full commit for every external input, retrieve the 13 payload
files, and capture the target identity from the same Cyberpunk installation:
architecture, game version, bundle version, GOG build ID, executable UUID, and
the executable SHA-256. Do not copy synthetic values into `release/evidence/`.

For native payloads, sign first and hash second. Capture `codesign --verify
--strict`, `codesign --display --verbose=4 --entitlements :-`, `lipo -archs`,
and the loader `otool -l` output after signing; the recorded hashes and
entitlements must describe those final bytes. The target evidence, provenance,
and preflight records must all refer to the same staged package root.

The production sequence is:

    PACKAGE_ROOT=/private/tmp/archive-loader-package
    EVIDENCE_DIR=/private/tmp/archive-loader-release-evidence
    BUILD_DIR=/private/tmp/archive-loader-build
    export ARCHIVE_LOADER_PACKAGE_ROOT="$PACKAGE_ROOT"
    export ARCHIVE_LOADER_MANIFEST=/path/to/manifest.json
    export ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$EVIDENCE_DIR"
    export ARCHIVE_LOADER_PROVENANCE="$EVIDENCE_DIR/provenance.json"
    export ARCHIVE_LOADER_TARGET_EVIDENCE="$EVIDENCE_DIR/target-evidence.json"
    export ARCHIVE_LOADER_PREFLIGHT="$EVIDENCE_DIR/preflight.json"
    export ARCHIVE_LOADER_BUILD_DIR="$BUILD_DIR"
    mkdir -p "$EVIDENCE_DIR" "$BUILD_DIR"
    ./release/prepare_inputs.sh --manifest "$ARCHIVE_LOADER_MANIFEST" \
        --output-root "$PACKAGE_ROOT" \
        --provenance "$ARCHIVE_LOADER_PROVENANCE" \
        --source PACKAGE_PATH=/path/to/real-file --production
    ./release/preflight.sh run --manifest /path/to/preflight-manifest.json \
        --output "$ARCHIVE_LOADER_PREFLIGHT" \
        --capture-dir "$EVIDENCE_DIR/preflight-captures"
    ./release/assemble.sh --version VERSION
    ./release/preflight.sh validate "$ARCHIVE_LOADER_PREFLIGHT"
    ./release/manifest_contract.sh validate "$ARCHIVE_LOADER_MANIFEST" "$PACKAGE_ROOT"
    ./release/provenance_contract.sh validate "$ARCHIVE_LOADER_PROVENANCE" \
        "$ARCHIVE_LOADER_MANIFEST" "$PACKAGE_ROOT" "$ARCHIVE_LOADER_TARGET_EVIDENCE"
    unzip -Z1 "$BUILD_DIR/archive-loader-VERSION-macos-arm64.zip"
    shasum -a 256 "$BUILD_DIR/archive-loader-VERSION-macos-arm64.zip"

`assemble.sh` writes `$ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR/readiness.json`
separately from the pre-assembly `release-output.json` identity. The readiness report records
`ready`, `blocked`, or `unresolved`, its evidence paths, exact command argv,
quarantine action, and final ZIP hash/listing when assembly completed. The
preflight JSON used in the input identity is never folded into the readiness
report hash, so the report cannot create a circular identity.

Missing payloads, provenance, target identity, signing evidence, archive hashes,
or native evidence produce `blocked` or `unresolved`; they can never produce
`ready`. A `blocked_toolchain_linker` result, including an `arm64e.x1`
diagnostic, remains blocked. Synthetic fixtures require
`ARCHIVE_LOADER_ALLOW_SYNTHETIC=1`, stay under
`tests/fixtures/release-inputs/synthetic/`, and are explicitly blocked from
production-ready status.

No production ZIP is valid until every real payload and every required target,
provenance, signing, native preflight, archive-hash, and final ZIP check exists.
