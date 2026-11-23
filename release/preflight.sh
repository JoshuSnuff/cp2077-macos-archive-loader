#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  preflight.sh run --manifest MANIFEST --output PREFLIGHT_JSON [--capture-dir DIR] [--allow-synthetic]
  preflight.sh validate PREFLIGHT_JSON [--allow-synthetic]
EOF
}

if [ "$#" -lt 1 ]; then
    usage
    exit 2
fi

COMMAND="$1"
shift
MANIFEST=""
OUTPUT=""
CAPTURE_DIR=""
PREFLIGHT_JSON=""
ALLOW_SYNTHETIC=0

case "$COMMAND" in
    run)
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --manifest)
                    [ "$#" -ge 2 ] || { echo "ERROR: --manifest requires a value" >&2; exit 2; }
                    MANIFEST="$2"
                    shift 2
                    ;;
                --output)
                    [ "$#" -ge 2 ] || { echo "ERROR: --output requires a value" >&2; exit 2; }
                    OUTPUT="$2"
                    shift 2
                    ;;
                --capture-dir)
                    [ "$#" -ge 2 ] || { echo "ERROR: --capture-dir requires a value" >&2; exit 2; }
                    CAPTURE_DIR="$2"
                    shift 2
                    ;;
                --allow-synthetic)
                    ALLOW_SYNTHETIC=1
                    shift
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                *)
                    echo "ERROR: unknown option: $1" >&2
                    usage
                    exit 2
                    ;;
            esac
        done
        [ -n "$MANIFEST" ] || { echo "ERROR: --manifest is required" >&2; exit 2; }
        [ -n "$OUTPUT" ] || { echo "ERROR: --output is required" >&2; exit 2; }
        [ -n "$CAPTURE_DIR" ] || CAPTURE_DIR="$(dirname "$OUTPUT")/preflight-captures"
        ;;
    validate)
        [ "$#" -ge 1 ] || { echo "ERROR: validate requires PREFLIGHT_JSON" >&2; usage; exit 2; }
        PREFLIGHT_JSON="$1"
        shift
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --allow-synthetic)
                    ALLOW_SYNTHETIC=1
                    shift
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                *)
                    echo "ERROR: unknown option: $1" >&2
                    usage
                    exit 2
                    ;;
            esac
        done
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        echo "ERROR: unknown command: $COMMAND" >&2
        usage
        exit 2
        ;;
esac

python3 - "$COMMAND" "$MANIFEST" "$OUTPUT" "$CAPTURE_DIR" "$ALLOW_SYNTHETIC" "$PREFLIGHT_JSON" <<'PY'
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import re
import shutil
import subprocess
import sys

mode = sys.argv[1]
manifest_path = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
output_path = pathlib.Path(sys.argv[3]).resolve() if sys.argv[3] else None
capture_dir = pathlib.Path(sys.argv[4]).resolve() if sys.argv[4] else None
allow_synthetic = sys.argv[5] == "1"
preflight_path = pathlib.Path(sys.argv[6]).resolve() if sys.argv[6] else None

NATIVE_PATHS = {
    "archive-loader/bin/archive-loader",
    "archive-loader/red4ext/RED4ext.dylib",
    "archive-loader/red4ext/FridaGadget.dylib",
}
TRUSTED_NATIVE_TOOLS = {
    "codesign": "/usr/bin/codesign",
    "lipo": "/usr/bin/lipo",
    "otool": "/usr/bin/otool",
}
REQUIRED_PRODUCTION_COMMANDS = {
    "Swift release build": ["swift", "build", "-c", "release", "--package-path", "patcher"],
    "Swift package tests": ["swift", "test", "--package-path", "patcher"],
}


class PreflightError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PreflightError(message)


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PreflightError(f"invalid JSON: {path}") from error


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def resolve_capture_path(path_value, base_path):
    require(isinstance(path_value, str) and path_value, "captured output path is invalid")
    path = pathlib.Path(path_value)
    return (base_path / path).resolve() if not path.is_absolute() else path.resolve()


def read_tool_version(arguments):
    if shutil.which(arguments[0]) is None:
        return None
    try:
        completed = subprocess.run(arguments, check=False, capture_output=True, text=True)
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    value = (completed.stdout + completed.stderr).strip()
    return value or None


def host_metadata():
    return {
        "architecture": platform.machine() or None,
        "macosVersion": read_tool_version(["sw_vers", "-productVersion"]),
    }


def toolchain_metadata():
    return {
        "sdkVersion": read_tool_version(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        "swiftVersion": read_tool_version(["swift", "--version"]),
        "xcodeVersion": read_tool_version(["xcodebuild", "-version"]),
    }


def validate_argv(argv, message):
    require(isinstance(argv, list) and argv, message)
    require(all(isinstance(argument, str) for argument in argv), message)
    require(argv[0], message)
    return argv


def command_result(argv, stdout_path, stderr_path, exit_status):
    diagnostic = stdout_path.read_bytes() + b"\n" + stderr_path.read_bytes()
    if b"arm64e.x1" in diagnostic:
        result = "blocked_toolchain_linker"
    elif exit_status == 0:
        result = "passed"
    else:
        result = "failed"
    return {
        "argv": argv,
        "exitStatus": exit_status,
        "id": None,
        "result": result,
        "stderrPath": str(stderr_path),
        "stdoutPath": str(stdout_path),
    }


def capture_command(entry, index, base_path, synthetic):
    require(isinstance(entry, dict), f"command entry {index} is invalid")
    argv = validate_argv(entry.get("argv"), f"command argv is missing or invalid: {index}")
    command_id = entry.get("id", entry.get("name", f"command-{index + 1}"))
    require(isinstance(command_id, str) and re.fullmatch(r"[A-Za-z0-9._-]+", command_id), f"command ID is invalid: {command_id}")

    captured = entry.get("capturedOutput", entry.get("captured"))
    if captured is None and {"stdoutPath", "stderrPath", "exitStatus"} <= set(entry):
        captured = {
            "stdoutPath": entry["stdoutPath"],
            "stderrPath": entry["stderrPath"],
            "exitStatus": entry["exitStatus"],
        }

    if captured is not None:
        require(synthetic, f"captured output is allowed only for explicit synthetic preflight: {command_id}")
        require(isinstance(captured, dict), f"captured output is invalid: {command_id}")
        stdout_path = resolve_capture_path(captured.get("stdoutPath"), base_path)
        stderr_path = resolve_capture_path(captured.get("stderrPath"), base_path)
        exit_status = captured.get("exitStatus")
        require(isinstance(exit_status, int) and not isinstance(exit_status, bool), f"captured exit status is invalid: {command_id}")
        require(stdout_path.is_file() and stderr_path.is_file(), f"captured output is missing: {command_id}")
        capture_mode = "external"
    else:
        safe_id = re.sub(r"[^A-Za-z0-9._-]", "_", command_id)
        stdout_path = capture_dir / f"{safe_id}.stdout"
        stderr_path = capture_dir / f"{safe_id}.stderr"
        capture_dir.mkdir(parents=True, exist_ok=True)
        try:
            with stdout_path.open("wb") as stdout_file, stderr_path.open("wb") as stderr_file:
                completed = subprocess.run(
                    argv,
                    check=False,
                    stdout=stdout_file,
                    stderr=stderr_file,
                )
        except OSError as error:
            raise PreflightError(f"could not run command {command_id}: {error}") from error
        exit_status = completed.returncode
        capture_mode = "executed"

    record = command_result(argv, stdout_path, stderr_path, exit_status)
    record["captureMode"] = capture_mode
    record["id"] = command_id
    return record


def validate_command_records(commands, synthetic):
    require(isinstance(commands, list) and commands, "preflight commands are missing")
    by_id = {}
    for index, entry in enumerate(commands):
        require(isinstance(entry, dict), f"preflight command {index} is invalid")
        require(set(entry) == {"argv", "captureMode", "exitStatus", "id", "result", "stderrPath", "stdoutPath"}, f"preflight command {index} fields are invalid")
        command_id = entry["id"]
        require(isinstance(command_id, str) and command_id not in by_id, f"preflight command ID is invalid: {command_id}")
        validate_argv(entry["argv"], f"preflight command argv is missing or invalid: {command_id}")
        require(isinstance(entry["exitStatus"], int) and not isinstance(entry["exitStatus"], bool), f"preflight exit status is invalid: {command_id}")
        require(entry["result"] in {"passed", "failed", "blocked_toolchain_linker"}, f"preflight result is invalid: {command_id}")
        require(entry["captureMode"] in {"executed", "external"}, f"preflight capture mode is invalid: {command_id}")
        require(synthetic or entry["captureMode"] == "executed", f"production preflight cannot use external captures: {command_id}")
        stdout_path = pathlib.Path(entry["stdoutPath"])
        stderr_path = pathlib.Path(entry["stderrPath"])
        require(stdout_path.is_absolute() and stderr_path.is_absolute(), f"preflight output paths must be absolute: {command_id}")
        require(stdout_path.is_file() and stderr_path.is_file() and stdout_path != stderr_path, f"preflight output files are missing: {command_id}")
        diagnostic = stdout_path.read_bytes() + b"\n" + stderr_path.read_bytes()
        expected_result = "blocked_toolchain_linker" if b"arm64e.x1" in diagnostic else ("passed" if entry["exitStatus"] == 0 else "failed")
        require(entry["result"] == expected_result, f"preflight result does not match captured command: {command_id}")
        by_id[command_id] = entry
    return by_id


def validate_production_command_plan(commands, synthetic):
    if synthetic:
        return
    command_argv = [entry["argv"] for entry in commands.values()]
    for description, required_argv in REQUIRED_PRODUCTION_COMMANDS.items():
        require(
            command_argv.count(required_argv) == 1,
            f"production preflight requires exactly one {description} command: {' '.join(required_argv)}",
        )


def command_output(command):
    return (
        pathlib.Path(command["stdoutPath"]).read_bytes(),
        pathlib.Path(command["stderrPath"]).read_bytes(),
    )


def require_exact_native_argv(command_id, command, executable, arguments, artifact_path, native_tools):
    argv = command["argv"]
    require(argv[0] == native_tools[executable], f"native command executable is invalid: {command_id}")
    require(argv[1:] == [*arguments, str(artifact_path)], f"native command target is not exactly {artifact_path}: {command_id}")


def parse_signing_evidence(command_id, command):
    stdout, stderr = command_output(command)
    metadata = stderr.decode("utf-8", errors="replace")

    signature_match = re.search(r"^Signature=(.+)$", metadata, re.MULTILINE)
    require(signature_match is not None, f"codesign signature metadata is missing: {command_id}")
    signature_value = signature_match.group(1).strip()
    if signature_value == "adhoc":
        signature_type = "adhoc"
        signing_identity = "adhoc"
    else:
        signature_type = "cms"
        authority_match = re.search(r"^Authority=(.+)$", metadata, re.MULTILINE)
        require(authority_match is not None, f"codesign authority metadata is missing: {command_id}")
        signing_identity = authority_match.group(1).strip()

    team_match = re.search(r"^TeamIdentifier=(.+)$", metadata, re.MULTILINE)
    require(team_match is not None and team_match.group(1).strip(), f"codesign team metadata is missing: {command_id}")

    flags_match = re.search(r"^CodeDirectory\b.*\bflags=0x[0-9a-fA-F]+(?:\(([^)]*)\))?", metadata, re.MULTILINE)
    require(flags_match is not None, f"codesign flags metadata is missing: {command_id}")
    flags_text = flags_match.group(1)
    flags = [] if flags_text in (None, "", "none") else [value for value in re.split(r"[,.\s]+", flags_text) if value]

    try:
        entitlements = plistlib.loads(stdout)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise PreflightError(f"codesign entitlements output is invalid: {command_id}") from error
    require(isinstance(entitlements, dict), f"codesign entitlements are not a dictionary: {command_id}")
    return {
        "codeSigningIdentity": signing_identity,
        "entitlements": entitlements,
        "flags": flags,
        "signatureType": signature_type,
        "teamIdentifier": team_match.group(1).strip(),
    }


def validate_native_check(command_id, expected_kind, evidence, commands, artifact_path, native_tools):
    require(isinstance(command_id, str) and command_id in commands, f"native command reference is missing: {command_id}")
    command = commands[command_id]
    require(command["exitStatus"] == 0 and command["result"] == "passed", f"native command did not pass: {command_id}")

    if expected_kind == "architecture":
        require_exact_native_argv(command_id, command, "lipo", ["-archs"], artifact_path, native_tools)
        stdout, stderr = command_output(command)
        diagnostic = stdout + stderr
        require(re.search(rb"(?:^|\s)arm64(?:\s|$)", diagnostic), f"native architecture output lacks arm64: {command_id}")
    elif expected_kind == "verification":
        require_exact_native_argv(command_id, command, "codesign", ["--verify", "--strict"], artifact_path, native_tools)
    elif expected_kind == "signing":
        require_exact_native_argv(
            command_id,
            command,
            "codesign",
            ["--display", "--verbose=4", "--entitlements", ":-"],
            artifact_path,
            native_tools,
        )
        return parse_signing_evidence(command_id, command)
    elif expected_kind == "restrict":
        require_exact_native_argv(command_id, command, "otool", ["-l"], artifact_path, native_tools)
        stdout, stderr = command_output(command)
        diagnostic = stdout + stderr
        require(b"__RESTRICT" in diagnostic, f"native restrict output is missing: {command_id}")
    else:
        raise PreflightError(f"unknown native check: {expected_kind}")


def validate_native_tools(native_tools, synthetic, has_native_evidence):
    if not has_native_evidence:
        require(native_tools == {}, "nativeTools must be empty without native evidence")
        return
    require(isinstance(native_tools, dict) and set(native_tools) == set(TRUSTED_NATIVE_TOOLS), "nativeTools fields are invalid")
    for name, path_value in native_tools.items():
        require(isinstance(path_value, str) and pathlib.Path(path_value).is_absolute(), f"native tool path is invalid: {name}")
        tool_path = pathlib.Path(path_value)
        require(tool_path.resolve() == tool_path and tool_path.is_file() and os.access(tool_path, os.X_OK), f"native tool is not a canonical executable file: {name}")
    if not synthetic:
        require(native_tools == TRUSTED_NATIVE_TOOLS, "production native tools must use pinned macOS system paths")


def resolve_artifact(package_root, package_path):
    artifact_path = (package_root / package_path).resolve()
    try:
        artifact_path.relative_to(package_root)
    except ValueError as error:
        raise PreflightError(f"native artifact escapes package root: {package_path}") from error
    require(artifact_path.is_file(), f"native artifact is missing: {package_path}")
    return artifact_path


def validate_manifest_native_bindings(native_evidence, manifest_commands, package_root, native_tools):
    commands = {}
    for index, entry in enumerate(manifest_commands):
        command_id = entry.get("id", entry.get("name", f"command-{index + 1}"))
        commands[command_id] = entry

    binding_fields = {
        "architectureCommand": ("lipo", ["-archs"]),
        "signingCommand": ("codesign", ["--display", "--verbose=4", "--entitlements", ":-"]),
        "verificationCommand": ("codesign", ["--verify", "--strict"]),
    }
    for evidence in native_evidence:
        require(isinstance(evidence, dict), "native evidence entry is invalid")
        package_path = evidence.get("path")
        require(package_path in NATIVE_PATHS, f"native evidence path is invalid: {package_path}")
        artifact_path = resolve_artifact(package_root, package_path)
        artifact_hash = evidence.get("artifactSha256")
        require(isinstance(artifact_hash, str) and artifact_hash.lower() == hashlib.sha256(artifact_path.read_bytes()).hexdigest(), f"native artifact digest mismatch: {package_path}")
        fields = dict(binding_fields)
        if package_path == "archive-loader/bin/archive-loader":
            fields["restrictCommand"] = ("otool", ["-l"])
        for field, (tool_name, arguments) in fields.items():
            command_id = evidence.get(field)
            require(isinstance(command_id, str) and command_id in commands, f"native command reference is missing: {command_id}")
            command = commands[command_id]
            argv = validate_argv(command.get("argv"), f"command argv is missing or invalid: {command_id}")
            require_exact_native_argv(command_id, {"argv": argv}, tool_name, arguments, artifact_path, native_tools)


def validate_native_evidence(native_evidence, commands, synthetic, package_root, native_tools):
    require(isinstance(native_evidence, list), "nativeEvidence must be an array")
    if not synthetic or native_evidence:
        require(len(native_evidence) == len(NATIVE_PATHS), "native evidence must cover exactly loader and both dylibs")
    if not native_evidence:
        require(synthetic, "native evidence is required for production preflight")
        require(package_root is None, "packageRoot must be null without native evidence")
        validate_native_tools(native_tools, synthetic, False)
        return

    require(isinstance(package_root, str) and pathlib.Path(package_root).is_absolute(), "packageRoot is required for native evidence")
    package_root_path = pathlib.Path(package_root)
    require(package_root_path.resolve() == package_root_path and package_root_path.is_dir(), "packageRoot must be a canonical directory")
    validate_native_tools(native_tools, synthetic, True)

    seen_paths = set()
    for index, evidence in enumerate(native_evidence):
        require(isinstance(evidence, dict), f"native evidence {index} is invalid")
        package_path = evidence.get("path")
        require(package_path in NATIVE_PATHS, f"native evidence path is invalid: {package_path}")
        require(package_path not in seen_paths, f"duplicate native evidence path: {package_path}")
        seen_paths.add(package_path)
        required_fields = {
            "architectureCommand",
            "architectures",
            "artifactSha256",
            "codeSigningIdentity",
            "entitlements",
            "entitlementsSha256",
            "flags",
            "path",
            "signingCommand",
            "signatureType",
            "teamIdentifier",
            "verificationCommand",
        }
        if package_path == "archive-loader/bin/archive-loader":
            required_fields.add("restrictCommand")
        require(set(evidence) == required_fields, f"native evidence fields are invalid: {package_path}")
        require(isinstance(evidence["architectures"], list) and "arm64" in evidence["architectures"], f"native arm64 evidence is missing: {package_path}")
        require(isinstance(evidence["artifactSha256"], str) and re.fullmatch(r"[0-9a-fA-F]{64}", evidence["artifactSha256"]), f"native artifact digest is invalid: {package_path}")
        artifact_path = resolve_artifact(package_root_path, package_path)
        actual_artifact_hash = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
        require(evidence["artifactSha256"].lower() == actual_artifact_hash, f"native artifact digest mismatch: {package_path}")
        require(isinstance(evidence["codeSigningIdentity"], str) and evidence["codeSigningIdentity"], f"native signing identity is missing: {package_path}")
        require(isinstance(evidence["teamIdentifier"], str) and evidence["teamIdentifier"], f"native team identifier is missing: {package_path}")
        require(isinstance(evidence["signatureType"], str) and evidence["signatureType"], f"native signature type is missing: {package_path}")
        require(isinstance(evidence["flags"], list) and all(isinstance(flag, str) for flag in evidence["flags"]), f"native signing flags are invalid: {package_path}")
        require(isinstance(evidence["entitlements"], dict), f"native entitlements are invalid: {package_path}")
        expected_entitlement_hash = hashlib.sha256(canonical_json(evidence["entitlements"]).encode("utf-8")).hexdigest()
        require(evidence["entitlementsSha256"] == expected_entitlement_hash, f"native entitlement digest mismatch: {package_path}")

        validate_native_check(evidence["architectureCommand"], "architecture", evidence, commands, artifact_path, native_tools)
        validate_native_check(evidence["verificationCommand"], "verification", evidence, commands, artifact_path, native_tools)
        actual_signing = validate_native_check(evidence["signingCommand"], "signing", evidence, commands, artifact_path, native_tools)
        for field in ("codeSigningIdentity", "teamIdentifier", "signatureType", "flags", "entitlements"):
            require(evidence[field] == actual_signing[field], f"native {field} does not match codesign output: {package_path}")
        if package_path.endswith(("red4ext/RED4ext.dylib", "red4ext/FridaGadget.dylib")):
            require(evidence["entitlements"] == {}, f"dylib entitlements must be empty: {package_path}")
        if package_path == "archive-loader/bin/archive-loader":
            validate_native_check(evidence["restrictCommand"], "restrict", evidence, commands, artifact_path, native_tools)

    require(seen_paths == NATIVE_PATHS, "native evidence paths are incomplete")


def validate_document(document, permit_synthetic):
    require(isinstance(document, dict), "preflight root must be an object")
    required_top_level = {"commands", "host", "nativeEvidence", "nativeTools", "packageRoot", "schema", "synthetic", "toolchain"}
    require(set(document) == required_top_level, "preflight top-level fields are invalid")
    require(document["schema"] == "archive-loader-preflight/v1", "unsupported preflight schema")
    synthetic = document["synthetic"]
    require(isinstance(synthetic, bool), "preflight synthetic marker is invalid")
    if synthetic:
        require(permit_synthetic, "synthetic preflight requires explicit --allow-synthetic")
    host = document["host"]
    require(isinstance(host, dict) and set(host) == {"architecture", "macosVersion"}, "preflight host metadata is invalid")
    require(isinstance(host["architecture"], str) and host["architecture"], "preflight host architecture is missing")
    require(host["macosVersion"] is None or isinstance(host["macosVersion"], str), "preflight macOS version is invalid")
    toolchain = document["toolchain"]
    require(isinstance(toolchain, dict) and set(toolchain) == {"sdkVersion", "swiftVersion", "xcodeVersion"}, "preflight toolchain metadata is invalid")
    require(all(value is None or isinstance(value, str) for value in toolchain.values()), "preflight toolchain version is invalid")
    commands = validate_command_records(document["commands"], synthetic)
    validate_production_command_plan(commands, synthetic)
    validate_native_evidence(
        document["nativeEvidence"],
        commands,
        synthetic,
        document["packageRoot"],
        document["nativeTools"],
    )


def write_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(canonical_json(document) + "\n", encoding="utf-8")


try:
    if mode == "run":
        manifest = load_json(manifest_path)
        require(isinstance(manifest, dict), "command manifest must be an object")
        require(manifest.get("schema") == "archive-loader-preflight-manifest/v1", "unsupported command manifest schema")
        synthetic = manifest.get("synthetic", False)
        require(isinstance(synthetic, bool), "command manifest synthetic marker is invalid")
        if synthetic:
            require(allow_synthetic, "synthetic preflight requires explicit --allow-synthetic")
        else:
            require(not allow_synthetic, "--allow-synthetic requires a synthetic manifest")
        manifest_commands = manifest.get("commands")
        require(isinstance(manifest_commands, list) and manifest_commands, "command manifest commands are missing")
        command_ids = []
        for index, entry in enumerate(manifest_commands):
            require(isinstance(entry, dict), f"command entry {index} is invalid")
            command_id = entry.get("id", entry.get("name", f"command-{index + 1}"))
            require(isinstance(command_id, str) and command_id not in command_ids, f"command ID is invalid: {command_id}")
            command_ids.append(command_id)
        native_evidence = manifest.get("nativeEvidence", [])
        has_native_evidence = isinstance(native_evidence, list) and bool(native_evidence)
        package_root_value = manifest.get("packageRoot")
        if has_native_evidence:
            require(isinstance(package_root_value, str) and package_root_value, "packageRoot is required for native evidence")
            unresolved_root = pathlib.Path(package_root_value)
            package_root = (manifest_path.parent / unresolved_root).resolve() if not unresolved_root.is_absolute() else unresolved_root.resolve()
            package_root_value = str(package_root)
        else:
            require(package_root_value is None, "packageRoot must be omitted without native evidence")
        native_tools = manifest.get("nativeTools", {})
        validate_native_tools(native_tools, synthetic, has_native_evidence)
        if has_native_evidence:
            validate_manifest_native_bindings(native_evidence, manifest_commands, package_root, native_tools)
        if not synthetic:
            for index, entry in enumerate(manifest_commands):
                has_capture = entry.get("capturedOutput", entry.get("captured")) is not None
                has_legacy_capture = {"stdoutPath", "stderrPath", "exitStatus"} <= set(entry)
                require(not has_capture and not has_legacy_capture, f"production command cannot use external capture: {index}")
        records = [capture_command(entry, index, manifest_path.parent, synthetic) for index, entry in enumerate(manifest_commands)]
        document = {
            "commands": records,
            "host": host_metadata(),
            "nativeEvidence": native_evidence,
            "nativeTools": native_tools,
            "packageRoot": package_root_value,
            "schema": "archive-loader-preflight/v1",
            "synthetic": synthetic,
            "toolchain": toolchain_metadata(),
        }
        validate_document(document, allow_synthetic)
        write_json(output_path, document)
        if any(entry["result"] != "passed" for entry in records):
            sys.exit(1)
    elif mode == "validate":
        document = load_json(preflight_path)
        validate_document(document, allow_synthetic)
        print("preflight contract valid")
    else:
        raise PreflightError(f"unknown command: {mode}")
except PreflightError as error:
    print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)
PY
