#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$REPOSITORY_DIR/release/preflight.sh"
WORK_DIR="$(mktemp -d /private/tmp/archive-loader-preflight-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

if [ ! -x "$PREFLIGHT" ]; then
    fail "missing preflight wrapper: $PREFLIGHT"
fi

MANIFEST="$WORK_DIR/commands.json"
CAPTURE_DIR="$WORK_DIR/captures"
PREFLIGHT_JSON="$WORK_DIR/preflight.json"

python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "commands": [
                {"id": "success", "argv": ["python3", "-c", "print('success output')"]},
                {
                    "id": "ordinary-failure",
                    "argv": ["python3", "-c", "import sys; print('ordinary failure', file=sys.stderr); sys.exit(7)"],
                },
                {
                    "id": "linker-failure",
                    "argv": ["python3", "-c", "import sys; print('ld: unsupported arm64e.x1 relocation', file=sys.stderr)"],
                },
            ],
            "schema": "archive-loader-preflight-manifest/v1",
            "synthetic": True,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

PRODUCTION_MANIFEST="$WORK_DIR/production-no-evidence.json"
PRODUCTION_JSON="$WORK_DIR/production-no-evidence-preflight.json"
python3 - "$PRODUCTION_MANIFEST" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "commands": [{"id": "success", "argv": ["python3", "-c", "print('success output')"]}],
            "schema": "archive-loader-preflight-manifest/v1",
            "synthetic": False,
        }
    )
    + "\n",
    encoding="utf-8",
)
PY
if "$PREFLIGHT" run --manifest "$PRODUCTION_MANIFEST" --output "$PRODUCTION_JSON" >/dev/null 2>&1; then
    fail "production preflight accepted success without native evidence"
fi
[ ! -e "$PRODUCTION_JSON" ] || fail "rejected production preflight wrote output"

SYNTHETIC_JSON="$WORK_DIR/synthetic-preflight.json"
if "$PREFLIGHT" run --manifest "$MANIFEST" --output "$SYNTHETIC_JSON" >/dev/null 2>&1; then
    fail "synthetic evidence-free mode did not require explicit opt-in"
fi
[ ! -e "$SYNTHETIC_JSON" ] || fail "rejected synthetic preflight wrote output"

set +e
"$PREFLIGHT" run \
    --manifest "$MANIFEST" \
    --output "$PREFLIGHT_JSON" \
    --capture-dir "$CAPTURE_DIR" \
    --allow-synthetic \
    >"$WORK_DIR/preflight.stdout" 2>"$WORK_DIR/preflight.stderr"
run_status=$?
set -e
[ "$run_status" -ne 0 ] || fail "preflight accepted failed native commands"
[ -f "$PREFLIGHT_JSON" ] || fail "preflight did not write canonical JSON"
"$PREFLIGHT" validate "$PREFLIGHT_JSON" --allow-synthetic >/dev/null || fail "valid synthetic classification was rejected"

python3 - "$PREFLIGHT_JSON" <<'PY'
import json
import pathlib
import sys

preflight_path = pathlib.Path(sys.argv[1])
document = json.loads(preflight_path.read_text(encoding="utf-8"))
if document.get("schema") != "archive-loader-preflight/v1":
    raise SystemExit("ERROR: preflight schema is missing")
if document.get("synthetic") is not True:
    raise SystemExit("ERROR: synthetic preflight marker is missing")
for key in ("host", "toolchain", "commands", "nativeEvidence"):
    if key not in document:
        raise SystemExit(f"ERROR: preflight field is missing: {key}")

commands = {entry["id"]: entry for entry in document["commands"]}
expected = {
    "success": (0, "passed"),
    "ordinary-failure": (7, "failed"),
    "linker-failure": (0, "blocked_toolchain_linker"),
}
if set(commands) != set(expected):
    raise SystemExit("ERROR: preflight command IDs differ")
for command_id, (exit_status, result) in expected.items():
    entry = commands[command_id]
    if entry["exitStatus"] != exit_status or entry["result"] != result:
        raise SystemExit(f"ERROR: wrong result for {command_id}: {entry}")
    if not entry["argv"] or not entry["stdoutPath"] or not entry["stderrPath"]:
        raise SystemExit(f"ERROR: incomplete capture record for {command_id}")
    stdout_path = pathlib.Path(entry["stdoutPath"])
    stderr_path = pathlib.Path(entry["stderrPath"])
    if not stdout_path.is_file() or not stderr_path.is_file():
        raise SystemExit(f"ERROR: missing captured output for {command_id}")
    if command_id == "linker-failure" and entry["result"] == "passed":
        raise SystemExit("ERROR: arm64e.x1 linker failure was reported as passed")

if not document["host"].get("architecture"):
    raise SystemExit("ERROR: host architecture was not captured")
if "macosVersion" not in document["host"]:
    raise SystemExit("ERROR: macOS metadata field is missing")
for key in ("swiftVersion", "xcodeVersion", "sdkVersion"):
    if key not in document["toolchain"]:
        raise SystemExit(f"ERROR: toolchain metadata field is missing: {key}")

canonical = json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
if preflight_path.read_text(encoding="utf-8") != canonical:
    raise SystemExit("ERROR: preflight JSON is not canonically serialized")
PY

NATIVE_MANIFEST="$WORK_DIR/native-manifest.json"
NATIVE_JSON="$WORK_DIR/native-preflight.json"
NATIVE_CAPTURE_DIR="$WORK_DIR/native-captures"
NATIVE_PACKAGE_ROOT="$WORK_DIR/package root"
NATIVE_TOOL_ROOT="$WORK_DIR/synthetic-tools"
python3 - "$NATIVE_MANIFEST" "$NATIVE_CAPTURE_DIR" "$NATIVE_PACKAGE_ROOT" "$NATIVE_TOOL_ROOT" <<'PY'
import hashlib
import json
import pathlib
import plistlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
capture_dir = pathlib.Path(sys.argv[2])
package_root = pathlib.Path(sys.argv[3]).resolve()
tool_root = pathlib.Path(sys.argv[4]).resolve()
capture_dir.mkdir()
tool_root.mkdir()
empty_hash = hashlib.sha256(b"{}").hexdigest()


def command(command_id, argv, stdout=b"", stderr=b"", exit_status=0):
    stdout_path = capture_dir / f"{command_id}.stdout"
    stderr_path = capture_dir / f"{command_id}.stderr"
    if isinstance(stdout, str):
        stdout = stdout.encode("utf-8")
    if isinstance(stderr, str):
        stderr = stderr.encode("utf-8")
    stdout_path.write_bytes(stdout)
    stderr_path.write_bytes(stderr)
    return {
        "capturedOutput": {
            "exitStatus": exit_status,
            "stderrPath": str(stderr_path),
            "stdoutPath": str(stdout_path),
        },
        "argv": argv,
        "id": command_id,
    }


paths = [
    "archive-loader/bin/archive-loader",
    "archive-loader/red4ext/RED4ext.dylib",
    "archive-loader/red4ext/FridaGadget.dylib",
]
artifact_paths = {}
for index, path in enumerate(paths):
    artifact_path = package_root / path
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_path.write_bytes(f"synthetic native artifact {index}\n".encode("utf-8"))
    artifact_paths[path] = artifact_path

native_tools = {}
for name in ("codesign", "lipo", "otool"):
    tool_path = tool_root / name
    tool_path.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
    tool_path.chmod(0o755)
    native_tools[name] = str(tool_path)

commands = []
evidence = []
for path in paths:
    artifact_path = artifact_paths[path]
    prefix = path.replace("/", "-").replace(".", "-")
    lipo_id = f"{prefix}-lipo"
    codesign_id = f"{prefix}-codesign"
    signing_id = f"{prefix}-signing"
    commands.append(command(lipo_id, [native_tools["lipo"], "-archs", str(artifact_path)], "arm64\n"))
    commands.append(command(codesign_id, [native_tools["codesign"], "--verify", "--strict", str(artifact_path)]))
    commands.append(
        command(
            signing_id,
            [native_tools["codesign"], "--display", "--verbose=4", "--entitlements", ":-", str(artifact_path)],
            plistlib.dumps({}, fmt=plistlib.FMT_XML),
            "CodeDirectory v=20500 size=123 flags=0x2(adhoc) hashes=1+0 location=embedded\n"
            "Signature=adhoc\n"
            "TeamIdentifier=SYNTHETIC\n",
        )
    )
    item = {
        "architectureCommand": lipo_id,
        "architectures": ["arm64"],
        "artifactSha256": hashlib.sha256(artifact_path.read_bytes()).hexdigest(),
        "codeSigningIdentity": "adhoc",
        "entitlements": {},
        "entitlementsSha256": empty_hash,
        "flags": ["adhoc"],
        "path": path,
        "signingCommand": signing_id,
        "signatureType": "adhoc",
        "teamIdentifier": "SYNTHETIC",
        "verificationCommand": codesign_id,
    }
    if path == "archive-loader/bin/archive-loader":
        restrict_id = f"{prefix}-otool"
        commands.append(command(restrict_id, [native_tools["otool"], "-l", str(artifact_path)], "segname __RESTRICT\n"))
        item["restrictCommand"] = restrict_id
    evidence.append(item)

manifest = {
    "commands": commands,
    "nativeEvidence": evidence,
    "nativeTools": native_tools,
    "packageRoot": str(package_root),
    "schema": "archive-loader-preflight-manifest/v1",
    "synthetic": True,
}
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

"$PREFLIGHT" run \
    --manifest "$NATIVE_MANIFEST" \
    --output "$NATIVE_JSON" \
    --allow-synthetic \
    >/dev/null || fail "valid native evidence was rejected"
"$PREFLIGHT" validate "$NATIVE_JSON" --allow-synthetic >/dev/null || fail "valid native preflight was rejected"

python3 - "$NATIVE_JSON" <<'PY'
import json
import pathlib
import sys

preflight_path = pathlib.Path(sys.argv[1])
preflight = json.loads(preflight_path.read_text(encoding="utf-8"))
canonical = json.dumps(preflight, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
if preflight_path.read_text(encoding="utf-8") != canonical:
    raise SystemExit("ERROR: native preflight JSON is not canonical")
if len(preflight["nativeEvidence"]) != 3:
    raise SystemExit("ERROR: native evidence does not cover exactly three payloads")
if not pathlib.Path(preflight["packageRoot"]).is_absolute():
    raise SystemExit("ERROR: native package root is not absolute")
if set(preflight["nativeTools"]) != {"codesign", "lipo", "otool"}:
    raise SystemExit("ERROR: native tool paths were not recorded")
for entry in preflight["commands"]:
    if entry["captureMode"] != "external":
        raise SystemExit("ERROR: synthetic captured command did not record external capture mode")
    if pathlib.Path(entry["argv"][0]).name == "codesign" and entry["argv"][1:3] == ["--verify", "--strict"]:
        if pathlib.Path(entry["stdoutPath"]).read_bytes() or pathlib.Path(entry["stderrPath"]).read_bytes():
            raise SystemExit("ERROR: silent codesign success was not preserved")
PY

python3 - "$NATIVE_MANIFEST" "$WORK_DIR" "$PREFLIGHT" "$NATIVE_JSON" <<'PY'
import copy
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys

manifest_path = pathlib.Path(sys.argv[1])
output_dir = pathlib.Path(sys.argv[2])
preflight = sys.argv[3]
preflight_record_path = pathlib.Path(sys.argv[4])
document = json.loads(manifest_path.read_text(encoding="utf-8"))


def expect_reject(name, change):
    mutated = copy.deepcopy(document)
    change(mutated)
    manifest = output_dir / f"native-{name}.json"
    output = output_dir / f"native-{name}-preflight.json"
    manifest.write_text(json.dumps(mutated) + "\n", encoding="utf-8")
    result = subprocess.run(
        [preflight, "run", "--manifest", str(manifest), "--output", str(output), "--allow-synthetic"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        raise SystemExit(f"ERROR: invalid native evidence accepted: {name}")
    if output.exists():
        raise SystemExit(f"ERROR: rejected native evidence wrote output: {name}")


def command_by_id(value, command_id):
    return next(entry for entry in value["commands"] if entry["id"] == command_id)


def artifact_path(value, package_path):
    return pathlib.Path(value["packageRoot"]) / package_path


expect_reject(
    "mismatched-target",
    lambda value: command_by_id(value, "archive-loader-bin-archive-loader-lipo").update(
        {"argv": [value["nativeTools"]["lipo"], "-archs", str(artifact_path(value, "archive-loader/red4ext/RED4ext.dylib"))]}
    ),
)
expect_reject(
    "comment-decoy-target",
    lambda value: command_by_id(value, "archive-loader-bin-archive-loader-otool").update(
        {
            "argv": [
                value["nativeTools"]["otool"],
                "-l",
                str(artifact_path(value, "archive-loader/red4ext/RED4ext.dylib")),
                "#",
                str(artifact_path(value, "archive-loader/bin/archive-loader")),
            ]
        }
    ),
)
expect_reject(
    "extra-target-operand",
    lambda value: command_by_id(value, "archive-loader-bin-archive-loader-lipo")["argv"].append("decoy"),
)
expect_reject(
    "hash-only-target",
    lambda value: command_by_id(value, "archive-loader-bin-archive-loader-codesign").update(
        {"argv": [value["nativeTools"]["codesign"], "--verify", "--strict", "a" * 64]}
    ),
)
expect_reject(
    "signing-command-decoy-target",
    lambda value: command_by_id(value, "archive-loader-bin-archive-loader-signing").update(
        {
            "argv": [
                value["nativeTools"]["codesign"],
                "--display",
                "--verbose=4",
                "--entitlements",
                ":-",
                str(artifact_path(value, "archive-loader/red4ext/RED4ext.dylib")),
                "#",
                str(artifact_path(value, "archive-loader/bin/archive-loader")),
            ]
        }
    ),
)
expect_reject(
    "nonzero-native-command",
    lambda value: command_by_id(value, "archive-loader-bin-archive-loader-lipo")["capturedOutput"].update({"exitStatus": 2}),
)
for tool_name, command_id in {
    "codesign": "archive-loader-bin-archive-loader-codesign",
    "lipo": "archive-loader-bin-archive-loader-lipo",
    "otool": "archive-loader-bin-archive-loader-otool",
}.items():
    expect_reject(
        f"alternate-{tool_name}-executable",
        lambda value, command_id=command_id, tool_name=tool_name: command_by_id(value, command_id)["argv"].__setitem__(
            0, str(output_dir / "alternate" / tool_name)
        ),
    )

untrusted_marker = output_dir / "untrusted-codesign-ran"
untrusted_tool = output_dir / "alternate-live" / "codesign"
untrusted_tool.parent.mkdir()
untrusted_tool.write_text(f"#!/bin/sh\n: > '{untrusted_marker}'\nexit 0\n", encoding="utf-8")
untrusted_tool.chmod(0o755)


def select_untrusted_live_tool(value):
    command = command_by_id(value, "archive-loader-bin-archive-loader-codesign")
    command.pop("capturedOutput")
    command["argv"][0] = str(untrusted_tool)


expect_reject("untrusted-live-codesign", select_untrusted_live_tool)
if untrusted_marker.exists():
    raise SystemExit("ERROR: rejected alternate codesign executable was run")

expect_reject(
    "artifact-digest-mismatch",
    lambda value: value["nativeEvidence"][0].update({"artifactSha256": "0" * 64}),
)

loader_path = artifact_path(document, "archive-loader/bin/archive-loader")
loader_bytes = loader_path.read_bytes()
loader_path.write_bytes(loader_bytes + b"tampered")
try:
    expect_reject("tampered-artifact-bytes", lambda value: None)
finally:
    loader_path.write_bytes(loader_bytes)

expect_reject(
    "partial-evidence",
    lambda value: value["nativeEvidence"].pop(),
)
expect_reject(
    "signing-identity-mismatch",
    lambda value: value["nativeEvidence"][0].update({"codeSigningIdentity": "FORGED"}),
)
expect_reject(
    "team-identifier-mismatch",
    lambda value: value["nativeEvidence"][0].update({"teamIdentifier": "FORGED"}),
)
expect_reject(
    "signature-type-mismatch",
    lambda value: value["nativeEvidence"][0].update({"signatureType": "cms"}),
)
expect_reject(
    "flags-mismatch",
    lambda value: value["nativeEvidence"][0].update({"flags": ["runtime"]}),
)
forged_entitlements = {"com.apple.security.cs.disable-library-validation": True}
forged_entitlements_hash = hashlib.sha256(
    json.dumps(forged_entitlements, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
expect_reject(
    "entitlements-mismatch",
    lambda value: value["nativeEvidence"][0].update(
        {"entitlements": forged_entitlements, "entitlementsSha256": forged_entitlements_hash}
    ),
)

nonempty_entitlements = output_dir / "synthetic-nonempty-entitlements.plist"
nonempty_entitlements.write_bytes(
    plistlib.dumps({"com.apple.security.cs.disable-library-validation": True}, fmt=plistlib.FMT_XML)
)
expect_reject(
    "dylib-actual-entitlements-nonempty",
    lambda value: command_by_id(value, "archive-loader-red4ext-RED4ext-dylib-signing")["capturedOutput"].update(
        {"stdoutPath": str(nonempty_entitlements)}
    ),
)

production_capture = copy.deepcopy(document)
production_capture["synthetic"] = False
production_capture["nativeTools"] = {
    "codesign": "/usr/bin/codesign",
    "lipo": "/usr/bin/lipo",
    "otool": "/usr/bin/otool",
}
for entry in production_capture["commands"]:
    entry["argv"][0] = production_capture["nativeTools"][pathlib.Path(entry["argv"][0]).name]
production_manifest = output_dir / "native-unbound-production-capture.json"
production_output = output_dir / "native-unbound-production-capture-preflight.json"
production_manifest.write_text(json.dumps(production_capture) + "\n", encoding="utf-8")
production_result = subprocess.run(
    [preflight, "run", "--manifest", str(production_manifest), "--output", str(production_output)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
if production_result.returncode == 0:
    raise SystemExit("ERROR: production accepted externally captured native output")
if production_output.exists():
    raise SystemExit("ERROR: rejected production capture wrote output")

unpinned_record = json.loads(preflight_record_path.read_text(encoding="utf-8"))
unpinned_record["synthetic"] = False
for entry in unpinned_record["commands"]:
    entry["captureMode"] = "executed"
unpinned_path = output_dir / "native-unpinned-production-record.json"
unpinned_path.write_text(json.dumps(unpinned_record) + "\n", encoding="utf-8")
unpinned_result = subprocess.run(
    [preflight, "validate", str(unpinned_path)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
if unpinned_result.returncode == 0:
    raise SystemExit("ERROR: production accepted alternate tools named codesign/lipo/otool")

production_record = copy.deepcopy(unpinned_record)
production_record["synthetic"] = False
production_record["nativeTools"] = {
    "codesign": "/usr/bin/codesign",
    "lipo": "/usr/bin/lipo",
    "otool": "/usr/bin/otool",
}
for entry in production_record["commands"]:
    entry["captureMode"] = "executed"
    tool_name = pathlib.Path(entry["argv"][0]).name
    entry["argv"][0] = production_record["nativeTools"][tool_name]

missing_swift_path = output_dir / "production-missing-swift-evidence.json"
missing_swift_path.write_text(json.dumps(production_record) + "\n", encoding="utf-8")
missing_swift_result = subprocess.run(
    [preflight, "validate", str(missing_swift_path)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
if missing_swift_result.returncode == 0:
    raise SystemExit("ERROR: production preflight accepted native inspection without Swift build/test evidence")

for command_id, argv in (
    ("swift-release-build", ["swift", "build", "-c", "release", "--package-path", "patcher"]),
    ("swift-package-tests", ["swift", "test", "--package-path", "patcher"]),
):
    stdout_path = output_dir / f"{command_id}.stdout"
    stderr_path = output_dir / f"{command_id}.stderr"
    stdout_path.write_bytes(b"")
    stderr_path.write_bytes(b"")
    production_record["commands"].append(
        {
            "argv": argv,
            "captureMode": "executed",
            "exitStatus": 0,
            "id": command_id,
            "result": "passed",
            "stderrPath": str(stderr_path.resolve()),
            "stdoutPath": str(stdout_path.resolve()),
        }
    )

complete_production_path = output_dir / "production-with-swift-evidence.json"
complete_production_path.write_text(json.dumps(production_record) + "\n", encoding="utf-8")
complete_production_result = subprocess.run(
    [preflight, "validate", str(complete_production_path)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
if complete_production_result.returncode != 0:
    raise SystemExit("ERROR: production preflight rejected complete Swift build/test evidence")
PY

echo "release preflight test passed"
