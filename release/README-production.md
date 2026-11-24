# Production release workflow

This is the operator checklist for a real archive-loader release. It is
separate from the synthetic fixture workflow used by the shell tests.

## Inputs and evidence

Acquire every payload from an immutable HTTPS URL or a full commit identity.
The production package must contain all manifest-declared files, including the
loader, `RED4ext.dylib`, and `FridaGadget.dylib`. Capture the target identity
from the same real game installation: arm64 architecture, Cyberpunk version,
bundle version, GOG build ID, executable UUID, and executable SHA-256.

For native files, complete signing before calculating extracted or manifest
hashes. Then capture and retain the native command output:

- `lipo -archs`
- `codesign --verify --strict`
- `codesign --display --verbose=4 --entitlements :-`
- `otool -l` for the loader, including `__RESTRICT`

The two Red4ext dylibs must record empty entitlements. The staged bytes, native
artifact digests, provenance hashes, and manifest hashes must all agree.

## Production commands

Use a fresh temporary package root, evidence directory, and build directory.
The source map below is illustrative; replace every placeholder with a real
file. These explicit overrides keep release inputs and evidence out of the
repository defaults.

```bash
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

./release/prepare_inputs.sh \
    --manifest "$ARCHIVE_LOADER_MANIFEST" \
    --output-root "$PACKAGE_ROOT" \
    --provenance "$ARCHIVE_LOADER_PROVENANCE" \
    --source archive-loader/bin/archive-loader=/path/to/signed-loader \
    --source archive-loader/setup.command=/path/to/setup.command \
    --production

./release/preflight.sh run \
    --manifest /path/to/preflight-manifest.json \
    --output "$ARCHIVE_LOADER_PREFLIGHT" \
    --capture-dir "$EVIDENCE_DIR/preflight-captures"

./release/assemble.sh --version VERSION
```

The assembler validates the manifest, staged package, provenance, target
identity, native preflight, and the pre-assembly identity before creating or
reusing output. It writes `$EVIDENCE_DIR/readiness.json` only after those
checks; after successful assembly the report also contains the final ZIP path,
SHA-256, and exact file listing. `release-output.json` remains the separate
pre-assembly identity/output record and is not hashed into readiness.

Do not use `--allow-unverified` in this workflow. That explicit test-only
override is available only to assemble a tested package while production
provenance, target, or native-preflight evidence is still missing or invalid:

```bash
./release/assemble.sh --version VERSION --allow-unverified
```

It keeps manifest, package, loader-version, and `__RESTRICT` checks strict and
never fabricates the missing evidence. It emits a warning and writes a report
with `status: "unverified"`, `allowUnverified: true`,
`productionCompatible: false`, and reasons for every missing or failed check.
If the pre-assembly identity is unavailable, its `release-output.json` value is
a labeled identity bound to the current manifest and package tuple, without
inventing production evidence. Do not distribute that ZIP or treat its report
as production readiness; rerun the normal command after all real evidence is collected.

The report is `ready` only when real production inputs and all required native
checks pass. Missing payload, provenance, target, signing evidence, archive
hashes, or final ZIP evidence is `unresolved` or `blocked`, never `ready`.
`blocked_toolchain_linker` and the `arm64e.x1` diagnostic remain blocked and
must be rerun after the toolchain is fixed.

## Fixtures and quarantine

Synthetic evidence is test-only. It must be explicitly marked, invoked with
`ARCHIVE_LOADER_ALLOW_SYNTHETIC=1`, and kept under
`tests/fixtures/release-inputs/synthetic/`; it is never copied into
`$EVIDENCE_DIR/` and never receives production-ready status.

Assembly does not overwrite stale output by default. With explicit
`--replace-existing`, an existing ZIP and/or `release-output.json` is moved to
a unique UTC directory under `build/quarantine/`. The readiness report retains
the quarantine action and path. If the move fails, the original artifact is
left in place and assembly stops.

## Final verification

Before distribution, inspect the readiness report and run the contracts again:

```bash
jq '{status, productionCompatible, reasons, evidencePaths, finalZip, quarantine}' \
    "$EVIDENCE_DIR/readiness.json"
./release/preflight.sh validate "$ARCHIVE_LOADER_PREFLIGHT"
./release/manifest_contract.sh validate "$ARCHIVE_LOADER_MANIFEST" \
    "$PACKAGE_ROOT"
./release/provenance_contract.sh validate \
    "$ARCHIVE_LOADER_PROVENANCE" "$ARCHIVE_LOADER_MANIFEST" \
    "$PACKAGE_ROOT" "$ARCHIVE_LOADER_TARGET_EVIDENCE"
unzip -Z1 "$BUILD_DIR/archive-loader-VERSION-macos-arm64.zip"
shasum -a 256 "$BUILD_DIR/archive-loader-VERSION-macos-arm64.zip"
```

Do not distribute a production ZIP while the report is `blocked` or
`unresolved`. No production ZIP is valid until every real payload and every
required provenance, target, signing, linker, archive-hash, and final ZIP
evidence record exists.
