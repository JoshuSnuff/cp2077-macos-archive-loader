#!/usr/bin/env bash
# Assembles the current read-only preflight release. It writes only beneath the
# repository build directory and never touches a game installation.
set -euo pipefail

SCRIPT_REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_DIR="${ARCHIVE_LOADER_REPOSITORY_DIR:-$SCRIPT_REPOSITORY_DIR}"
VERSION=""
REPLACE_EXISTING=0

usage() {
    cat <<EOF
Usage: $(basename "$0") --version VERSION [--replace-existing]

Assemble build/archive-loader-VERSION-macos-arm64.zip with the archive-loader
runtime payload.

By default, an existing current ZIP/evidence pair is reused and any stale or
incomplete output is refused. --replace-existing moves stale output into a
timestamped build quarantine before assembling a replacement.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --version requires a value" >&2
                exit 2
            fi
            VERSION="$2"
            shift 2
            ;;
        --replace-existing)
            REPLACE_EXISTING=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "ERROR: --version is required" >&2
    usage >&2
    exit 2
fi
case "$VERSION" in
    *[!A-Za-z0-9._-]*)
        echo "ERROR: version may contain only letters, digits, dots, underscores, and hyphens" >&2
        exit 2
        ;;
esac

PACKAGE_ROOT="${ARCHIVE_LOADER_PACKAGE_ROOT:-$REPOSITORY_DIR}"
BUILD_DIR="${ARCHIVE_LOADER_BUILD_DIR:-$REPOSITORY_DIR/build}"
OUTPUT_ZIP="$BUILD_DIR/archive-loader-$VERSION-macos-arm64.zip"
MANIFEST="${ARCHIVE_LOADER_MANIFEST:-$PACKAGE_ROOT/compatibility/manifest.json}"
MANIFEST_CONTRACT="$SCRIPT_REPOSITORY_DIR/release/manifest_contract.sh"
EVIDENCE_DIR="${ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR:-$REPOSITORY_DIR/release/evidence}"
PROVENANCE_CONTRACT="$SCRIPT_REPOSITORY_DIR/release/provenance_contract.sh"
PREFLIGHT_CONTRACT="$SCRIPT_REPOSITORY_DIR/release/preflight.sh"
PROVENANCE="${ARCHIVE_LOADER_PROVENANCE:-$EVIDENCE_DIR/provenance.json}"
TARGET_EVIDENCE="${ARCHIVE_LOADER_TARGET_EVIDENCE:-$EVIDENCE_DIR/target-evidence.json}"
PREFLIGHT="${ARCHIVE_LOADER_PREFLIGHT:-$EVIDENCE_DIR/preflight.json}"
OUTPUT_EVIDENCE="$EVIDENCE_DIR/release-output.json"

# Task 5 readiness state is collected below before any ZIP or quarantine
# mutation. The report is deliberately separate from release-output.json.
READINESS_REPORT="${ARCHIVE_LOADER_READINESS_REPORT:-$EVIDENCE_DIR/readiness.json}"
READINESS_DIAGNOSTICS_DIR="${ARCHIVE_LOADER_READINESS_DIAGNOSTICS_DIR:-$(dirname "$READINESS_REPORT")/readiness}"
READINESS_STATE_DIR="$(mktemp -d /private/tmp/archive-loader-readiness-state.XXXXXX)"
READINESS_REASONS_FILE="$READINESS_STATE_DIR/reasons"
: > "$READINESS_REASONS_FILE"
REPORT_WRITTEN=0
ASSEMBLY_COMPLETE=0
STAGING_ROOT=""
EVIDENCE_STAGING_DIR=""
LOCK_DIR=""
LOCK_HELD=0
QUARANTINE_DIR=""
QUARANTINE_STATUS="not_run"
QUARANTINE_RECOVERY_STATUS="not_needed"
ASSEMBLY_STATUS="not_run"
ZIP_STATUS="not_run"
PREFLIGHT_BLOCKED=0
ARCHIVE_LOADER_ALLOW_SYNTHETIC="${ARCHIVE_LOADER_ALLOW_SYNTHETIC:-0}"
mkdir -p "$READINESS_DIAGNOSTICS_DIR"

MANIFEST_STATUS="unresolved"
PACKAGE_STATUS="unresolved"
PROVENANCE_STATUS="unresolved"
TARGET_STATUS="unresolved"
PREFLIGHT_STATUS="unresolved"
IDENTITY_STATUS="unresolved"
BINARY_STATUS="unresolved"
IDENTITY_JSON=""

add_readiness_reason() {
    printf '%s\n' "$1" >> "$READINESS_REASONS_FILE"
}

run_captured() {
    local stdout_path="$1"
    local stderr_path="$2"
    shift 2
    if "$@" >"$stdout_path" 2>"$stderr_path"; then
        return 0
    else
        local command_status=$?
        return "$command_status"
    fi
}

write_readiness_report() {
    local status="$1"
    [ "$REPORT_WRITTEN" -eq 0 ] || return 0
    if env \
        READINESS_REPORT="$READINESS_REPORT" READINESS_STATUS="$status" \
        READINESS_VERSION="$VERSION" READINESS_ASSEMBLER="$SCRIPT_REPOSITORY_DIR/release/assemble.sh" \
        READINESS_MANIFEST="$MANIFEST" READINESS_PACKAGE_ROOT="$PACKAGE_ROOT" \
        READINESS_PROVENANCE="$PROVENANCE" READINESS_TARGET="$TARGET_EVIDENCE" \
        READINESS_PREFLIGHT="$PREFLIGHT" READINESS_OUTPUT_ZIP="$OUTPUT_ZIP" \
        READINESS_OUTPUT_EVIDENCE="$OUTPUT_EVIDENCE" READINESS_DIAGNOSTICS="$READINESS_DIAGNOSTICS_DIR" \
        READINESS_REASONS="$READINESS_REASONS_FILE" \
        READINESS_CHECKS="$MANIFEST_STATUS,$PACKAGE_STATUS,$PROVENANCE_STATUS,$TARGET_STATUS,$PREFLIGHT_STATUS,$IDENTITY_STATUS,$BINARY_STATUS,$QUARANTINE_STATUS,$ASSEMBLY_STATUS,$ZIP_STATUS" \
        READINESS_ASSEMBLY_COMPLETE="$ASSEMBLY_COMPLETE" READINESS_QUARANTINE="$QUARANTINE_DIR" \
        READINESS_QUARANTINE_RECOVERY="$QUARANTINE_RECOVERY_STATUS" \
        READINESS_ALLOW_SYNTHETIC="$ARCHIVE_LOADER_ALLOW_SYNTHETIC" READINESS_REPLACE_EXISTING="$REPLACE_EXISTING" \
        python3 <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess

def load(path):
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None

def resolved(path):
    return str(pathlib.Path(path).resolve())

report_path = pathlib.Path(os.environ["READINESS_REPORT"])
manifest_path = resolved(os.environ["READINESS_MANIFEST"])
package_root = resolved(os.environ["READINESS_PACKAGE_ROOT"])
provenance_path = resolved(os.environ["READINESS_PROVENANCE"])
target_path = resolved(os.environ["READINESS_TARGET"])
preflight_path = resolved(os.environ["READINESS_PREFLIGHT"])
output_zip = resolved(os.environ["READINESS_OUTPUT_ZIP"])
output_evidence = resolved(os.environ["READINESS_OUTPUT_EVIDENCE"])
diagnostics = resolved(os.environ["READINESS_DIAGNOSTICS"])
reasons = [line.strip() for line in pathlib.Path(os.environ["READINESS_REASONS"]).read_text(encoding="utf-8").splitlines() if line.strip()]
manifest = load(manifest_path)
provenance = load(provenance_path)
preflight = load(preflight_path)
status = os.environ["READINESS_STATUS"]
if status == "ready" and (os.environ["READINESS_ALLOW_SYNTHETIC"] == "1" or any(
    isinstance(item, dict) and item.get("synthetic") is True for item in (provenance, preflight)
)):
    status = "blocked"
    reasons.append("synthetic fixture evidence is not production evidence")

paths = [manifest_path, package_root, provenance_path, target_path, preflight_path, output_zip, output_evidence, resolved(os.environ["READINESS_REPORT"])]
evidence_paths = list(dict.fromkeys(paths))
statuses = os.environ["READINESS_CHECKS"].split(",")
names = ["manifest", "staged-package", "provenance", "target-identity", "native-preflight", "pre-assembly-identity", "loader", "quarantine", "assembly", "final-zip"]
checks = [{"id": name, "status": check_status} for name, check_status in zip(names, statuses)]
release_dir = pathlib.Path(os.environ["READINESS_ASSEMBLER"]).parent
manifest_contract = str(release_dir / "manifest_contract.sh")
provenance_contract = str(release_dir / "provenance_contract.sh")
preflight_contract = str(release_dir / "preflight.sh")
binary = str(pathlib.Path(package_root) / "archive-loader/bin/archive-loader")
commands = [
    {"id": "manifest-validation", "argv": [manifest_contract, "validate", manifest_path], "result": statuses[0]},
    {"id": "package-validation", "argv": [manifest_contract, "validate", manifest_path, package_root], "result": statuses[1]},
    {"id": "provenance-validation", "argv": [provenance_contract, "validate", provenance_path, manifest_path, package_root, target_path], "result": statuses[2]},
    {"id": "preflight-validation", "argv": [preflight_contract, "validate", preflight_path] + (["--allow-synthetic"] if os.environ["READINESS_ALLOW_SYNTHETIC"] == "1" else []), "result": statuses[4]},
    {"id": "pre-assembly-identity", "argv": [provenance_contract, "identity", provenance_path, manifest_path, package_root, preflight_path], "result": statuses[5]},
    {"id": "loader-version", "argv": [binary, "--version"], "result": statuses[6]},
    {"id": "loader-restrict", "argv": ["otool", "-l", binary], "result": statuses[6]},
]
if isinstance(preflight, dict):
    for entry in preflight.get("commands", []):
        if isinstance(entry, dict):
            commands.append({"id": "native:" + str(entry.get("id", "unknown")), "argv": entry.get("argv", []), "result": entry.get("result", "unresolved")})
            evidence_paths.extend(path for path in (entry.get("stdoutPath"), entry.get("stderrPath")) if path)
assembly_argv = [os.environ["READINESS_ASSEMBLER"], "--version", os.environ["READINESS_VERSION"]]
if os.environ["READINESS_REPLACE_EXISTING"] == "1":
    assembly_argv.append("--replace-existing")
commands.append({"id": "assembly", "argv": assembly_argv, "result": statuses[8]})
for name in ("manifest-validation", "package-validation", "provenance-validation", "preflight-validation", "identity", "loader-version", "loader-restrict"):
    evidence_paths.extend(str(pathlib.Path(diagnostics) / f"{name}.{suffix}") for suffix in ("stdout", "stderr"))

package_files = []
if isinstance(manifest, dict):
    for entry in manifest.get("managedFiles", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("packagePath"), str):
            continue
        package_path = entry["packagePath"]
        file_path = pathlib.Path(package_root) / package_path
        actual_hash = None
        masked_hash = None
        declared_hash = entry.get("sha256")
        actual_mode = None
        expected_mode = "0755" if package_path in {"archive-loader/bin/archive-loader", "archive-loader/setup.command"} else "0644"
        if file_path.is_file() and not file_path.is_symlink():
            actual_hash = hashlib.sha256(file_path.read_bytes()).hexdigest()
            actual_mode = format(file_path.stat().st_mode & 0o777, "04o")
        is_manifest_self = package_path == "archive-loader/compatibility/manifest.json"
        if is_manifest_self and actual_hash:
            try:
                masked_hash = subprocess.check_output(
                    [manifest_contract, "file-hash", manifest_path, str(file_path), package_path, entry.get("gamePath", "")],
                    text=True,
                    stderr=subprocess.DEVNULL,
                ).strip()
            except (OSError, subprocess.CalledProcessError):
                masked_hash = None
            hash_matches = masked_hash == declared_hash
            hash_comparison = "masked-manifest-self-hash"
        else:
            hash_matches = actual_hash == declared_hash if actual_hash else False
            hash_comparison = "ordinary-bytes"
        file_status = "unresolved" if actual_hash is None else ("passed" if hash_matches and actual_mode == expected_mode else "failed")
        package_files.append({
            "actualSha256": actual_hash,
            "actualMode": actual_mode,
            "declaredSha256": declared_hash,
            "expectedSha256": entry.get("sha256"),
            "expectedMode": expected_mode,
            "hashComparison": hash_comparison,
            "maskedSha256": masked_hash,
            "packagePath": package_path,
            "path": str(file_path),
            "status": file_status,
        })
        evidence_paths.append(str(file_path))

final_zip = None
if os.environ["READINESS_ASSEMBLY_COMPLETE"] == "1":
    output = load(output_evidence)
    if isinstance(output, dict):
        final_zip = {"path": output_zip, "sha256": output.get("zipSha256"), "listing": output.get("zipListing", []), "evidencePath": output_evidence}
    else:
        try:
            listing = subprocess.check_output(["unzip", "-Z1", output_zip], text=True).splitlines()
            final_zip = {"path": output_zip, "sha256": hashlib.sha256(pathlib.Path(output_zip).read_bytes()).hexdigest(), "listing": [item for item in listing if not item.endswith("/")], "evidencePath": output_evidence}
        except (OSError, subprocess.CalledProcessError):
            reasons.append("final ZIP evidence could not be read")

quarantine_path = os.environ["READINESS_QUARANTINE"]
quarantine = {
    "status": statuses[7],
    "recoveryStatus": os.environ["READINESS_QUARANTINE_RECOVERY"],
    "path": resolved(quarantine_path) if quarantine_path else None,
    "artifacts": [],
}
if quarantine["path"]:
    quarantine_root = pathlib.Path(quarantine["path"])
    evidence_paths.append(quarantine["path"])
    for original_path, quarantine_name in ((output_zip, pathlib.Path(output_zip).name), (output_evidence, "release-output.json")):
        original = pathlib.Path(original_path)
        destination = quarantine_root / quarantine_name
        if destination.is_file():
            artifact_hash = hashlib.sha256(destination.read_bytes()).hexdigest()
            move_result = "moved"
        elif original.is_file():
            artifact_hash = hashlib.sha256(original.read_bytes()).hexdigest()
            move_result = "failed"
        else:
            continue
        quarantine["artifacts"].append({
            "originalPath": str(original),
            "quarantinePath": str(destination),
            "sha256": artifact_hash,
            "moveResult": move_result,
        })
        evidence_paths.extend((str(original), str(destination)))
evidence_paths = list(dict.fromkeys(evidence_paths))
report = {
    "checks": checks,
    "commands": commands,
    "evidencePaths": evidence_paths,
    "finalZip": final_zip,
    "packageFiles": package_files,
    "productionCompatible": status == "ready",
    "quarantine": quarantine,
    "reasons": reasons,
    "releaseId": "archive-loader-" + os.environ["READINESS_VERSION"] + "-macos-arm64",
    "schema": "archive-loader-release-readiness/v1",
    "status": status,
}
report_path.parent.mkdir(parents=True, exist_ok=True)
temporary_path = report_path.with_name("." + report_path.name + ".tmp")
temporary_path.write_text(json.dumps(report, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
temporary_path.replace(report_path)
PY
    then
        REPORT_WRITTEN=1
        return 0
    fi
    return 1
}

cleanup_on_exit() {
    local exit_status=$?
    if [ "$REPORT_WRITTEN" -eq 0 ]; then
        add_readiness_reason "assembly stopped before a final ZIP was recorded"
        if [ "$PREFLIGHT_BLOCKED" -eq 1 ]; then
            write_readiness_report "blocked" || true
        else
            write_readiness_report "unresolved" || true
        fi
    fi
    if [ -n "$STAGING_ROOT" ] && [ -e "$STAGING_ROOT" ]; then
        rm -rf "$STAGING_ROOT" || true
    fi
    if [ -n "$EVIDENCE_STAGING_DIR" ] && [ -e "$EVIDENCE_STAGING_DIR" ]; then
        rm -rf "$EVIDENCE_STAGING_DIR" || true
    fi
    if [ "$LOCK_HELD" -eq 1 ] && [ -n "$LOCK_DIR" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    rm -rf "$READINESS_STATE_DIR" || true
    trap - EXIT
    exit "$exit_status"
}
trap cleanup_on_exit EXIT

BINARY="$PACKAGE_ROOT/archive-loader/bin/archive-loader"
MANIFEST_STDOUT="$READINESS_DIAGNOSTICS_DIR/manifest-validation.stdout"
MANIFEST_STDERR="$READINESS_DIAGNOSTICS_DIR/manifest-validation.stderr"
PACKAGE_STDOUT="$READINESS_DIAGNOSTICS_DIR/package-validation.stdout"
PACKAGE_STDERR="$READINESS_DIAGNOSTICS_DIR/package-validation.stderr"
PROVENANCE_STDOUT="$READINESS_DIAGNOSTICS_DIR/provenance-validation.stdout"
PROVENANCE_STDERR="$READINESS_DIAGNOSTICS_DIR/provenance-validation.stderr"
PREFLIGHT_STDOUT="$READINESS_DIAGNOSTICS_DIR/preflight-validation.stdout"
PREFLIGHT_STDERR="$READINESS_DIAGNOSTICS_DIR/preflight-validation.stderr"
IDENTITY_STDOUT="$READINESS_DIAGNOSTICS_DIR/identity.stdout"
IDENTITY_STDERR="$READINESS_DIAGNOSTICS_DIR/identity.stderr"

if [ ! -x "$MANIFEST_CONTRACT" ]; then
    add_readiness_reason "manifest contract is unavailable: $MANIFEST_CONTRACT"
elif [ ! -f "$MANIFEST" ]; then
    add_readiness_reason "manifest is missing: $MANIFEST"
elif run_captured "$MANIFEST_STDOUT" "$MANIFEST_STDERR" "$MANIFEST_CONTRACT" validate "$MANIFEST"; then
    MANIFEST_STATUS="passed"
else
    MANIFEST_STATUS="failed"
    add_readiness_reason "manifest validation failed; see $MANIFEST_STDERR"
fi

if [ "$MANIFEST_STATUS" = "passed" ] && run_captured "$PACKAGE_STDOUT" "$PACKAGE_STDERR" "$MANIFEST_CONTRACT" validate "$MANIFEST" "$PACKAGE_ROOT"; then
    PACKAGE_STATUS="passed"
else
    add_readiness_reason "staged package validation failed; see $PACKAGE_STDERR"
fi

if [ ! -f "$PROVENANCE" ]; then
    add_readiness_reason "provenance is missing: $PROVENANCE"
elif [ ! -f "$TARGET_EVIDENCE" ]; then
    add_readiness_reason "target evidence is missing: $TARGET_EVIDENCE"
elif run_captured "$PROVENANCE_STDOUT" "$PROVENANCE_STDERR" "$PROVENANCE_CONTRACT" validate "$PROVENANCE" "$MANIFEST" "$PACKAGE_ROOT" "$TARGET_EVIDENCE"; then
    PROVENANCE_STATUS="passed"
    TARGET_STATUS="passed"
else
    PROVENANCE_STATUS="failed"
    TARGET_STATUS="failed"
    add_readiness_reason "provenance or target identity validation failed; see $PROVENANCE_STDERR"
fi

PREFLIGHT_ARGUMENTS=(validate "$PREFLIGHT")
[ "$ARCHIVE_LOADER_ALLOW_SYNTHETIC" = "1" ] && PREFLIGHT_ARGUMENTS+=(--allow-synthetic)
if [ ! -f "$PREFLIGHT" ]; then
    add_readiness_reason "native preflight evidence is missing: $PREFLIGHT"
elif run_captured "$PREFLIGHT_STDOUT" "$PREFLIGHT_STDERR" "$PREFLIGHT_CONTRACT" "${PREFLIGHT_ARGUMENTS[@]}"; then
    PREFLIGHT_STATUS="passed"
    preflight_results="$(python3 - "$PREFLIGHT" <<'PY'
import json
import pathlib
import sys
document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for entry in document.get("commands", []):
    if entry.get("result") != "passed":
        print(f"{entry.get('result', 'unresolved')}\t{entry.get('id', 'unknown')}")
PY
)"
    while IFS=$'\t' read -r command_result command_id; do
        [ -n "$command_result" ] || continue
        case "$command_result" in
            blocked_toolchain_linker)
                PREFLIGHT_STATUS="blocked"
                PREFLIGHT_BLOCKED=1
                add_readiness_reason "native preflight is blocked by arm64e.x1 in: $command_id"
                ;;
            *)
                if [ "$PREFLIGHT_STATUS" != "blocked" ]; then
                    PREFLIGHT_STATUS="failed"
                fi
                add_readiness_reason "native preflight command did not pass: $command_id ($command_result)"
                ;;
        esac
    done <<< "$preflight_results"
else
    PREFLIGHT_STATUS="failed"
    add_readiness_reason "native preflight validation failed; see $PREFLIGHT_STDERR"
fi

if [ -f "$PROVENANCE" ] && [ -f "$MANIFEST" ] && [ -d "$PACKAGE_ROOT" ] && [ -f "$PREFLIGHT" ] && run_captured "$IDENTITY_STDOUT" "$IDENTITY_STDERR" "$PROVENANCE_CONTRACT" identity "$PROVENANCE" "$MANIFEST" "$PACKAGE_ROOT" "$PREFLIGHT"; then
    IDENTITY_STATUS="passed"
    IDENTITY_JSON="$(cat "$IDENTITY_STDOUT")"
else
    add_readiness_reason "pre-assembly identity was not calculated or failed; see $IDENTITY_STDERR"
fi

if [ ! -x "$BINARY" ]; then
    add_readiness_reason "missing executable in package root: $BINARY"
else
    BINARY_STDOUT="$READINESS_DIAGNOSTICS_DIR/loader-version.stdout"
    BINARY_STDERR="$READINESS_DIAGNOSTICS_DIR/loader-version.stderr"
    RESTRICT_STDOUT="$READINESS_DIAGNOSTICS_DIR/loader-restrict.stdout"
    RESTRICT_STDERR="$READINESS_DIAGNOSTICS_DIR/loader-restrict.stderr"
    if ! run_captured "$BINARY_STDOUT" "$BINARY_STDERR" "$BINARY" --version; then
        BINARY_STATUS="failed"
        add_readiness_reason "loader --version command failed; see $BINARY_STDERR"
    elif [ "$(tr -d '\n' < "$BINARY_STDOUT")" != "archive-loader $VERSION" ]; then
        BINARY_STATUS="failed"
        add_readiness_reason "loader version does not match requested release; see $BINARY_STDOUT"
    elif command -v otool >/dev/null 2>&1 && run_captured "$RESTRICT_STDOUT" "$RESTRICT_STDERR" otool -l "$BINARY" && grep -q "__RESTRICT" "$RESTRICT_STDOUT"; then
        BINARY_STATUS="passed"
    else
        BINARY_STATUS="failed"
        add_readiness_reason "loader __RESTRICT verification failed; see $RESTRICT_STDERR"
    fi
fi

PRECHECK_FAILURE=0
for check_status in "$MANIFEST_STATUS" "$PACKAGE_STATUS" "$PROVENANCE_STATUS" "$TARGET_STATUS" "$PREFLIGHT_STATUS" "$IDENTITY_STATUS" "$BINARY_STATUS"; do
    [ "$check_status" = "passed" ] || PRECHECK_FAILURE=1
done
if [ "$PRECHECK_FAILURE" -ne 0 ]; then
    if [ "$PREFLIGHT_BLOCKED" -eq 1 ]; then
        write_readiness_report "blocked" || true
    else
        write_readiness_report "unresolved" || true
    fi
    exit 1
fi

if [ ! -x "$BINARY" ]; then
    echo "ERROR: missing executable in package root: $BINARY" >&2
    exit 1
fi

# --version is hand-typed here but compiled into the binary, and once the
# directory leaves this machine nothing else records which build it holds. A
# mislabelled release is indistinguishable from a correct one, so refuse rather
# than name the payload after a version it does not report.
BINARY_VERSION="$("$BINARY" --version)"
if [ "$BINARY_VERSION" != "archive-loader $VERSION" ]; then
    echo "ERROR: --version $VERSION disagrees with the binary, which reports: $BINARY_VERSION" >&2
    echo "  rebuild bin/archive-loader, or pass the version it was built with" >&2
    exit 1
fi

# The __RESTRICT segment is what stops an ambient DYLD_INSERT_LIBRARIES from
# injecting RED4ext into the wrapper. Shipping without it is silent.
if ! otool -l "$BINARY" | grep -q "__RESTRICT"; then
    echo "ERROR: $BINARY has no __RESTRICT segment; do not ship it" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
LOCK_DIR="$BUILD_DIR/.archive-loader-$VERSION.publish.lock"
if ! mkdir "$LOCK_DIR"; then
    add_readiness_reason "release publication lock is already held: $LOCK_DIR"
    echo "ERROR: release publication is already in progress: $LOCK_DIR" >&2
    exit 1
fi
LOCK_HELD=1

CURRENT_PAIR=0
if [ -f "$OUTPUT_ZIP" ] && [ -f "$OUTPUT_EVIDENCE" ]; then
    if python3 - "$OUTPUT_ZIP" "$OUTPUT_EVIDENCE" "$IDENTITY_JSON" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

zip_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
expected_identity = json.loads(sys.argv[3])

try:
    output = json.loads(output_path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(output, dict) or set(output) != {"identity", "releaseId", "schema", "zipListing", "zipSha256"}:
    raise SystemExit(1)
if output.get("schema") != "archive-loader-release-output/v1" or output.get("identity") != expected_identity:
    raise SystemExit(1)
if output.get("releaseId") != zip_path.stem:
    raise SystemExit(1)
if output.get("zipSha256") != hashlib.sha256(zip_path.read_bytes()).hexdigest():
    raise SystemExit(1)
try:
    listing = subprocess.check_output(["unzip", "-Z1", str(zip_path)], text=True).splitlines()
except subprocess.CalledProcessError:
    raise SystemExit(1)
listing = [entry for entry in listing if not entry.endswith("/")]
if output.get("zipListing") != listing:
    raise SystemExit(1)
PY
    then
        CURRENT_PAIR=1
    fi
fi

if [ "$CURRENT_PAIR" -eq 1 ]; then
    ASSEMBLY_STATUS="reused"
    ZIP_STATUS="passed"
    ASSEMBLY_COMPLETE=1
    write_readiness_report "ready"
    echo "$OUTPUT_ZIP"
    exit 0
fi

if [ -e "$OUTPUT_ZIP" ] || [ -e "$OUTPUT_EVIDENCE" ]; then
    if [ "$REPLACE_EXISTING" -ne 1 ]; then
        QUARANTINE_STATUS="refused"
        add_readiness_reason "stale or incomplete release output exists and quarantine was not requested"
        echo "ERROR: stale or incomplete release output exists; use --replace-existing to quarantine it" >&2
        exit 1
    fi

    QUARANTINE_BASE="$BUILD_DIR/quarantine"
    QUARANTINE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    QUARANTINE_DIR="$QUARANTINE_BASE/$QUARANTINE_STAMP"
    mkdir -p "$QUARANTINE_BASE" || {
        QUARANTINE_STATUS="failed"
        add_readiness_reason "release quarantine directory could not be created: $QUARANTINE_BASE"
        echo "ERROR: cannot create release quarantine: $QUARANTINE_BASE" >&2
        exit 1
    }
    suffix=0
    while [ -e "$QUARANTINE_DIR" ]; do
        suffix=$((suffix + 1))
        QUARANTINE_DIR="$QUARANTINE_BASE/$QUARANTINE_STAMP-$suffix"
    done
    mkdir "$QUARANTINE_DIR" || {
        QUARANTINE_STATUS="failed"
        add_readiness_reason "release quarantine directory could not be created: $QUARANTINE_DIR"
        echo "ERROR: cannot create release quarantine: $QUARANTINE_DIR" >&2
        exit 1
    }
    QUARANTINE_STATUS="passed"

    moved_zip=0
    if [ -e "$OUTPUT_ZIP" ]; then
        if ! mv "$OUTPUT_ZIP" "$QUARANTINE_DIR/$(basename "$OUTPUT_ZIP")"; then
            QUARANTINE_STATUS="failed"
            add_readiness_reason "existing ZIP could not be quarantined: $OUTPUT_ZIP"
            rmdir "$QUARANTINE_DIR" 2>/dev/null || true
            echo "ERROR: could not quarantine existing ZIP" >&2
            exit 1
        fi
        moved_zip=1
    fi
    if [ -e "$OUTPUT_EVIDENCE" ]; then
        if ! mv "$OUTPUT_EVIDENCE" "$QUARANTINE_DIR/release-output.json"; then
            QUARANTINE_STATUS="failed"
            add_readiness_reason "existing release evidence could not be quarantined: $OUTPUT_EVIDENCE"
            if [ "$moved_zip" -eq 1 ]; then
                if mv "$QUARANTINE_DIR/$(basename "$OUTPUT_ZIP")" "$OUTPUT_ZIP" 2>/dev/null \
                    && [ -e "$OUTPUT_ZIP" ] \
                    && [ ! -e "$QUARANTINE_DIR/$(basename "$OUTPUT_ZIP")" ]; then
                    QUARANTINE_RECOVERY_STATUS="rolled_back"
                    add_readiness_reason "quarantine rollback restored the original ZIP after the evidence move failed"
                else
                    QUARANTINE_RECOVERY_STATUS="rollback_failed"
                    add_readiness_reason "quarantine rollback failed; the original ZIP remains in quarantine: $QUARANTINE_DIR/$(basename "$OUTPUT_ZIP")"
                fi
            fi
            if [ "$QUARANTINE_RECOVERY_STATUS" != "rollback_failed" ]; then
                rmdir "$QUARANTINE_DIR" 2>/dev/null || true
            fi
            echo "ERROR: could not quarantine existing release evidence" >&2
            exit 1
        fi
    fi
fi

STAGING_ROOT="$(mktemp -d "$BUILD_DIR/.archive-loader-release.XXXXXX")"

PAYLOAD="$STAGING_ROOT"
# Only immutable program files ship. baselines/, pristine, state/, and logs/
# are created at first run, so no extraction can destroy a user's baseline or
# mod collection.
while IFS=$'\t' read -r package_path game_path expected_hash; do
    source="$PACKAGE_ROOT/$package_path"
    [ -f "$source" ] || { echo "ERROR: missing package source: $source" >&2; exit 1; }
    actual_hash="$("$MANIFEST_CONTRACT" file-hash "$MANIFEST" "$source" "$package_path" "$game_path")"
    [ "$actual_hash" = "$expected_hash" ] || {
        echo "ERROR: package hash mismatch for $package_path" >&2
        exit 1
    }
    destination="$STAGING_ROOT/$package_path"
    mkdir -p "$(dirname "$destination")"
    cp "$source" "$destination"
    case "$package_path" in
        archive-loader/bin/archive-loader|archive-loader/setup.command)
            chmod 0755 "$destination"
            ;;
        *)
            chmod 0644 "$destination"
            ;;
    esac
done < <("$MANIFEST_CONTRACT" records "$MANIFEST")

"$MANIFEST_CONTRACT" validate "$MANIFEST" "$STAGING_ROOT" >/dev/null
while IFS=$'\t' read -r package_path game_path expected_hash; do
    staged_file="$STAGING_ROOT/$package_path"
    staged_hash="$("$MANIFEST_CONTRACT" file-hash "$MANIFEST" "$staged_file" "$package_path" "$game_path")"
    [ "$staged_hash" = "$expected_hash" ] || {
        echo "ERROR: staged package hash mismatch for $package_path" >&2
        exit 1
    }
    expected_mode=644
    case "$package_path" in
        archive-loader/bin/archive-loader|archive-loader/setup.command) expected_mode=755 ;;
    esac
    actual_mode="$(stat -f '%Lp' "$staged_file")"
    [ "$actual_mode" = "$expected_mode" ] || {
        echo "ERROR: staged package mode mismatch for $package_path: $actual_mode" >&2
        exit 1
    }
done < <("$MANIFEST_CONTRACT" records "$MANIFEST")

PRIVATE_ZIP="$STAGING_ROOT/archive-loader-$VERSION-macos-arm64.zip"
( cd "$STAGING_ROOT" && zip -qry "$PRIVATE_ZIP" archive-loader )

ZIP_VERIFY_ROOT="$STAGING_ROOT/.zip-verify"
mkdir "$ZIP_VERIFY_ROOT"
unzip -q "$PRIVATE_ZIP" -d "$ZIP_VERIFY_ROOT"
"$MANIFEST_CONTRACT" validate "$MANIFEST" "$ZIP_VERIFY_ROOT" >/dev/null
while IFS=$'\t' read -r package_path game_path expected_hash; do
    verified_file="$ZIP_VERIFY_ROOT/$package_path"
    verified_hash="$("$MANIFEST_CONTRACT" file-hash "$MANIFEST" "$verified_file" "$package_path" "$game_path")"
    [ "$verified_hash" = "$expected_hash" ] || {
        echo "ERROR: private ZIP hash mismatch for $package_path" >&2
        exit 1
    }
    expected_mode=644
    case "$package_path" in
        archive-loader/bin/archive-loader|archive-loader/setup.command) expected_mode=755 ;;
    esac
    actual_mode="$(stat -f '%Lp' "$verified_file")"
    [ "$actual_mode" = "$expected_mode" ] || {
        echo "ERROR: private ZIP mode mismatch for $package_path: $actual_mode" >&2
        exit 1
    }
done < <("$MANIFEST_CONTRACT" records "$MANIFEST")

mkdir -p "$EVIDENCE_DIR"
EVIDENCE_STAGING_DIR="$(mktemp -d "$EVIDENCE_DIR/.release-output.XXXXXX")"
PRIVATE_EVIDENCE="$EVIDENCE_STAGING_DIR/release-output.json"

python3 - "$PRIVATE_ZIP" "$PRIVATE_EVIDENCE" "$IDENTITY_JSON" <<'PY'
import hashlib, json, pathlib, subprocess, sys
zip_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
identity = json.loads(sys.argv[3])
output_path.parent.mkdir(parents=True, exist_ok=True)
listing = subprocess.check_output(["unzip", "-Z1", str(zip_path)], text=True).splitlines()
files = [x for x in listing if not x.endswith("/")]
output = {
    "identity": identity,
    "schema": "archive-loader-release-output/v1",
    "releaseId": zip_path.stem,
    "zipSha256": hashlib.sha256(zip_path.read_bytes()).hexdigest(),
    "zipListing": files,
}
with output_path.open("x", encoding="utf-8") as stream:
    stream.write(json.dumps(output, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
PY

if ! ln "$PRIVATE_ZIP" "$OUTPUT_ZIP"; then
    add_readiness_reason "release ZIP appeared after precheck and was not overwritten: $OUTPUT_ZIP"
    echo "ERROR: release ZIP already exists at publication time: $OUTPUT_ZIP" >&2
    exit 1
fi
if ! ln "$PRIVATE_EVIDENCE" "$OUTPUT_EVIDENCE"; then
    add_readiness_reason "release output evidence appeared after precheck and was not overwritten: $OUTPUT_EVIDENCE"
    if [ "$OUTPUT_ZIP" -ef "$PRIVATE_ZIP" ]; then
        rm -f "$OUTPUT_ZIP"
    fi
    echo "ERROR: release output evidence already exists at publication time: $OUTPUT_EVIDENCE" >&2
    exit 1
fi

ASSEMBLY_STATUS="assembled"
ZIP_STATUS="passed"
ASSEMBLY_COMPLETE=1
write_readiness_report "ready"

echo "$OUTPUT_ZIP"
