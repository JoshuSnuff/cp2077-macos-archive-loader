#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$REPOSITORY_DIR/release/provenance_contract.sh"
MANIFEST_CONTRACT="$REPOSITORY_DIR/release/manifest_contract.sh"
FIXTURE_HELPER="$REPOSITORY_DIR/tests/fixtures/release-inputs/synthetic/create_fixture.sh"
WORK_DIR="$(mktemp -d /private/tmp/archive-loader-provenance-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

FIXTURE_ROOT="$WORK_DIR/synthetic fixture"
"$FIXTURE_HELPER" "$FIXTURE_ROOT" "0.1.3"

python3 - "$REPOSITORY_DIR" "$CONTRACT" "$MANIFEST_CONTRACT" "$FIXTURE_ROOT" "$WORK_DIR" <<'PY'
import copy
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

repository = pathlib.Path(sys.argv[1])
contract = pathlib.Path(sys.argv[2])
manifest_contract = pathlib.Path(sys.argv[3])
fixture_root = pathlib.Path(sys.argv[4])
work_dir = pathlib.Path(sys.argv[5])
package_root = fixture_root / "package"
manifest_path = package_root / "archive-loader/compatibility/manifest.json"
provenance_path = work_dir / "provenance.json"
target_evidence_path = work_dir / "target-evidence.json"
preflight_path = work_dir / "preflight.json"
template_path = repository / "tests/fixtures/release-inputs/synthetic/provenance-template.json"


def fail(message):
    raise SystemExit(f"ERROR: {message}")


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def digest(path):
    return digest_bytes(path.read_bytes())


def render(document, indent=2, sort_keys=True):
    return (json.dumps(document, indent=indent, sort_keys=sort_keys, ensure_ascii=False) + "\n").encode()


def canonical(document):
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


if not contract.is_file():
    fail(f"missing provenance contract: {contract}")
if not template_path.is_file():
    fail(f"missing synthetic provenance template: {template_path}")
if not json.loads(template_path.read_text(encoding="utf-8")).get("synthetic"):
    fail("synthetic provenance template is not explicitly marked")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
native_paths = {
    "archive-loader/bin/archive-loader",
    "archive-loader/red4ext/RED4ext.dylib",
    "archive-loader/red4ext/FridaGadget.dylib",
}
declared = {entry["packagePath"] for entry in manifest["managedFiles"]}
for package_path in sorted(native_paths - declared):
    file_path = package_root / package_path
    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_path.write_bytes(("SYNTHETIC-NATIVE-BYTES-" + package_path).encode())
    manifest["managedFiles"].append({
        "gamePath": package_path.removeprefix("archive-loader/"),
        "packagePath": package_path,
        "sha256": digest(file_path),
    })

self_entry = next(
    entry for entry in manifest["managedFiles"]
    if entry["packagePath"] == entry["gamePath"] == "archive-loader/compatibility/manifest.json"
)
self_entry["sha256"] = "0" * 64
masked = render(manifest)
needle = b'"sha256": "' + b"0" * 64 + b'"'
if masked.count(needle) != 1:
    fail("could not locate synthetic manifest self-entry")
start = masked.index(needle) + len(b'"sha256": "')
self_entry["sha256"] = digest_bytes(masked[:start] + b"0" * 64 + masked[start + 64:])
manifest_path.write_bytes(render(manifest))
original_manifest_bytes = manifest_path.read_bytes()

target = manifest["target"]
target_identity = {
    "architecture": target["architecture"],
    "bundleVersion": target["bundleVersion"],
    "distribution": target["distribution"],
    "executableSha256": target["executable"]["sha256"],
    "executableUUID": target["executable"]["uuid"],
    "game": target["game"],
    "gogBuildId": target["gogBuildId"],
    "metadataPaths": {
        "architecture": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
        "bundleVersion": "Cyberpunk2077.app/Contents/Info.plist",
        "executableSha256": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
        "executableUUID": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
        "gogBuildId": "Contents/Resources/goggame-1423049311.info",
        "version": "Cyberpunk2077.app/Contents/Info.plist",
    },
    "platform": target["platform"],
    "version": target["version"],
}

inputs = []
for entry in manifest["managedFiles"]:
    package_path = entry["packagePath"]
    source_path = package_root / package_path
    native = package_path in native_paths
    native_evidence = None
    if native:
        native_evidence = {
            "architectures": ["arm64"],
            "codeSigningIdentity": "SYNTHETIC-ADHOC",
            "entitlements": {},
            "entitlementsSha256": digest_bytes(canonical({})),
            "flags": ["adhoc"],
            "restrictSegment": package_path == "archive-loader/bin/archive-loader",
            "signatureType": "adhoc",
            "teamIdentifier": "SYNTHETIC",
            "verification": {
                "command": "codesign --verify --strict SYNTHETIC",
                "output": "SYNTHETIC verification output",
                "status": "passed",
            },
        }
    inputs.append({
        "archiveListing": [package_path],
        "archiveSha256": "a" * 64,
        "extractedFilename": pathlib.Path(package_path).name,
        "extractedSha256": digest(source_path),
        "extractionTool": {"name": "synthetic-fixture-generator", "version": "1"},
        "manifestSha256": entry["sha256"],
        "mode": "0755" if package_path in {
            "archive-loader/bin/archive-loader",
            "archive-loader/setup.command",
        } else "0644",
        "nativeEvidence": native_evidence,
        "nativeMachO": native,
        "originalFilename": pathlib.Path(package_path).name + ".synthetic.tar.gz",
        "packagePath": package_path,
        "source": {
            "immutable": True,
            "kind": "archive",
            "retrievedAt": "2026-11-22T00:00:00Z",
            "url": "https://example.invalid/SYNTHETIC-NOT-PRODUCTION/commit/" + "1" * 40,
        },
    })

base_provenance = {
    "inputs": inputs,
    "relatedPaths": {
        "externalPullStaging": "SYNTHETIC-NOT-USED",
        "recoveryRecord": "SYNTHETIC-NOT-USED",
        "snapshot": "SYNTHETIC-NOT-USED",
    },
    "releaseId": "archive-loader-0.1.3-macos-arm64-SYNTHETIC",
    "schema": "archive-loader-release-provenance/v1",
    "synthetic": True,
    "targetIdentity": target_identity,
}
base_target_evidence = {"synthetic": True, "targetIdentity": target_identity}
preflight = {
    "commands": [{"command": "SYNTHETIC-NOT-PRODUCTION", "result": "passed"}],
    "schema": "archive-loader-preflight/v1",
}
provenance_path.write_bytes(render(base_provenance))
base_provenance_bytes = provenance_path.read_bytes()
target_evidence_path.write_bytes(render(base_target_evidence))
preflight_path.write_bytes(render(preflight))


def reset():
    provenance_path.write_bytes(base_provenance_bytes)
    target_evidence_path.write_bytes(render(base_target_evidence))


def invoke(command, *args, synthetic=True):
    environment = os.environ.copy()
    environment["ARCHIVE_LOADER_ALLOW_SYNTHETIC"] = "1" if synthetic else "0"
    result = subprocess.run(
        ["bash", str(command), *map(str, args)],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result


def validate(synthetic=True):
    return invoke(contract, "validate", provenance_path, manifest_path, package_root, target_evidence_path, synthetic=synthetic)


def expect_accept(label):
    result = validate()
    if result.returncode != 0:
        fail(f"{label} was rejected: {result.stderr.strip()}")


def expect_reject(label):
    result = validate()
    if result.returncode == 0:
        fail(f"{label} was accepted")


def mutate(mutator):
    document = json.loads(provenance_path.read_text(encoding="utf-8"))
    mutator(document)
    provenance_path.write_bytes(render(document))


expect_accept("complete synthetic provenance")
if validate(synthetic=False).returncode == 0:
    fail("production validation accepted synthetic provenance")

reset()
mutate(lambda document: document["inputs"].pop())
expect_reject("incomplete input coverage")
reset()
mutate(lambda document: document["inputs"].append(copy.deepcopy(document["inputs"][0])))
expect_reject("duplicate input coverage")

reset()
def use_commit(document):
    source = document["inputs"][0]["source"]
    source.pop("url")
    source["commit"] = "2" * 40
use_commit_document = use_commit
mutate(use_commit_document)
expect_accept("immutable commit source")
reset()
mutate(lambda document: document["inputs"][0]["source"].update({"commit": "2" * 40}))
expect_reject("source with URL and commit")
reset()
mutate(lambda document: document["inputs"][0]["source"].pop("url"))
expect_reject("source without URL or commit")

reset()
def standalone(document):
    item = document["inputs"][0]
    item["source"]["kind"] = "standalone"
    item["archiveSha256"] = None
mutate(standalone)
expect_accept("standalone source")
reset()
mutate(lambda document: document["inputs"][0].update({"archiveSha256": None}))
expect_reject("archive source without archive hash")
reset()
def duplicate_extracted_hash(document):
    item = document["inputs"][0]
    item["source"]["kind"] = "standalone"
    item["archiveSha256"] = item["extractedSha256"]
mutate(duplicate_extracted_hash)
expect_reject("standalone source with archive hash")

# Ordinary package bytes must agree with both provenance hashes and the manifest.
reset()
runtime_path = package_root / "archive-loader/red4ext/runtime.txt"
runtime_bytes = runtime_path.read_bytes()
runtime_path.write_bytes(b"SYNTHETIC-DRIFTED-PACKAGE-BYTES\n")
drifted_hash = digest(runtime_path)
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/red4ext/runtime.txt").update({"extractedSha256": drifted_hash}))
expect_reject("ordinary extracted versus manifest hash disagreement")
runtime_path.write_bytes(runtime_bytes)

reset()
mutate(lambda document: document["inputs"][0].update({"mode": "0644"}))
expect_reject("wrong file mode")
reset()
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/bin/archive-loader")["nativeEvidence"].pop("signatureType"))
expect_reject("missing native signing field")
reset()
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/bin/archive-loader")["nativeEvidence"]["verification"].update({"status": "failed"}))
expect_reject("failed native verification")
reset()
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/bin/archive-loader")["nativeEvidence"]["verification"].update({"command": "echo codesign --verify --strict SYNTHETIC"}))
expect_reject("non-codesign native verification command")
reset()
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/bin/archive-loader")["nativeEvidence"]["verification"].update({"command": "codesign --verify SYNTHETIC"}))
expect_reject("native verification without strict mode")
reset()
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/bin/archive-loader")["nativeEvidence"].update({"entitlements": {"SYNTHETIC": True}}))
expect_reject("native entitlement digest mismatch")
reset()
def contradictory_raw_entitlements(document):
    evidence = next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/red4ext/FridaGadget.dylib")["nativeEvidence"]
    evidence["entitlementsRaw"] = '{"SYNTHETIC":true}'
    evidence["entitlementsSha256"] = digest_bytes(evidence["entitlementsRaw"].encode())
mutate(contradictory_raw_entitlements)
expect_reject("contradictory raw and structured dylib entitlements")
reset()
def boolean_integer_entitlements(document):
    evidence = next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/bin/archive-loader")["nativeEvidence"]
    evidence["entitlements"] = {"SYNTHETIC": 1}
    evidence["entitlementsRaw"] = '{"SYNTHETIC":true}'
    evidence["entitlementsSha256"] = digest_bytes(evidence["entitlementsRaw"].encode())
mutate(boolean_integer_entitlements)
expect_reject("boolean versus integer entitlements")
reset()
def integer_float_entitlements(document):
    evidence = next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/bin/archive-loader")["nativeEvidence"]
    evidence["entitlements"] = {"SYNTHETIC": 1.0}
    evidence["entitlementsRaw"] = '{"SYNTHETIC":1}'
    evidence["entitlementsSha256"] = digest_bytes(evidence["entitlementsRaw"].encode())
mutate(integer_float_entitlements)
expect_reject("integer versus float entitlements")
reset()
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/red4ext/FridaGadget.dylib")["nativeEvidence"].update({"entitlements": {"SYNTHETIC": True}}))
expect_reject("non-empty dylib entitlements")
reset()
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/red4ext/FridaGadget.dylib").update({"nativeMachO": False, "nativeEvidence": None}))
expect_reject("required dylib without native evidence")

reset()
mutate(lambda document: document["targetIdentity"].update({"executableUUID": "9" * 36}))
expect_reject("target identity mismatch")
reset()
target_evidence = copy.deepcopy(base_target_evidence)
target_evidence["targetIdentity"]["gogBuildId"] = "SYNTHETIC-MISMATCH"
target_evidence_path.write_bytes(render(target_evidence))
expect_reject("target evidence mismatch")

reset()
self_hash = next(
    entry["sha256"] for entry in manifest["managedFiles"]
    if entry["packagePath"] == entry["gamePath"] == "archive-loader/compatibility/manifest.json"
)
mutate(lambda document: next(item for item in document["inputs"] if item["packagePath"] == "archive-loader/compatibility/manifest.json").update({"extractedSha256": self_hash}))
expect_reject("manifest self-entry ordinary versus masked hash")

reset()
extra = package_root / "archive-loader/undeclared.txt"
extra.write_text("SYNTHETIC-UNDECLARED\n", encoding="utf-8")
if invoke(manifest_contract, "validate", manifest_path, package_root).returncode == 0:
    fail("manifest validation accepted an undeclared package file")
extra.unlink()
missing = package_root / "archive-loader/red4ext/absent.txt"
held = work_dir / "absent.txt"
missing.rename(held)
if invoke(manifest_contract, "validate", manifest_path, package_root).returncode == 0:
    fail("manifest validation accepted a missing declared package file")
held.rename(missing)
expect_accept("restored exact package root")

identity_one = work_dir / "identity-one.json"
identity_two = work_dir / "identity-two.json"
first = invoke(contract, "identity", provenance_path, manifest_path, package_root, preflight_path)
if first.returncode != 0:
    fail(f"identity command failed: {first.stderr.strip()}")
identity_one.write_text(first.stdout, encoding="utf-8")
provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
provenance_path.write_bytes(render(provenance, indent=4, sort_keys=False))
second = invoke(contract, "identity", provenance_path, manifest_path, package_root, preflight_path)
if second.returncode != 0:
    fail(f"identity command failed after formatting change: {second.stderr.strip()}")
identity_two.write_text(second.stdout, encoding="utf-8")
if identity_one.read_bytes() != identity_two.read_bytes():
    fail("identity changed with provenance formatting")

identity = json.loads(identity_one.read_text(encoding="utf-8"))
canonical = lambda document: json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
expected_provenance = digest_bytes(canonical(provenance))
expected_preflight = digest_bytes(canonical(preflight))
expected_tuples = sorted((item["packagePath"], item["manifestSha256"], item["mode"]) for item in base_provenance["inputs"])
expected_package = digest_bytes(canonical(expected_tuples))
if identity.get("provenanceSha256") != expected_provenance:
    fail("identity provenance hash is not canonical")
if identity.get("preflightSha256") != expected_preflight:
    fail("identity preflight hash is not canonical")
if identity.get("packageTupleSha256") != expected_package:
    fail("identity package tuple hash is not canonical")
if identity.get("manifestSha256") != digest(manifest_path):
    fail("identity ordinary manifest hash is wrong")
for field in ("manifestSha256", "manifestSelfSha256", "packageTupleSha256", "provenanceSha256", "preflightSha256"):
    if not isinstance(identity.get(field), str) or len(identity[field]) != 64:
        fail(f"identity field is missing or malformed: {field}")

# The self-entry range must be located from parsed JSON bytes, not one exact spacing pattern.
compact_manifest = copy.deepcopy(manifest)
compact_self_entry = next(
    entry for entry in compact_manifest["managedFiles"]
    if entry["packagePath"] == entry["gamePath"] == "archive-loader/compatibility/manifest.json"
)
compact_self_entry["sha256"] = "0" * 64
compact_bytes = (json.dumps(compact_manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
compact_match = re.search(rb'"sha256"\s*:\s*"0{64}"', compact_bytes)
if compact_match is None:
    fail("could not locate compact synthetic manifest self-entry")
compact_start = compact_match.start() + compact_match.group(0).index(b'"0') + 1
compact_self_entry["sha256"] = digest_bytes(compact_bytes[:compact_start] + b"0" * 64 + compact_bytes[compact_start + 64:])
compact_bytes = (json.dumps(compact_manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
manifest_path.write_bytes(compact_bytes)
compact_provenance = copy.deepcopy(base_provenance)
compact_manifest_hash = digest(manifest_path)
for item in compact_provenance["inputs"]:
    if item["packagePath"] == "archive-loader/compatibility/manifest.json":
        item["extractedSha256"] = compact_manifest_hash
        item["manifestSha256"] = compact_self_entry["sha256"]
provenance_path.write_bytes(render(compact_provenance))
expect_accept("compact manifest self-hash")

print("release provenance test passed")
PY
