#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="$REPOSITORY_DIR/docs/superpowers/patches/2026-11-24-always-first-equip-dual-wield.patch"
SOURCE_FILE="${1:-/Users/ivk/Games/Heroic/Cyberpunk 2077/r6/scripts/alwaysFirstEquip.reds}"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

[ -f "$PATCH_FILE" ] || fail "missing patch artifact: $PATCH_FILE"
[ -f "$SOURCE_FILE" ] || fail "missing REDscript source: $SOURCE_FILE"

[ "$(grep -c '^--- ' "$PATCH_FILE")" -eq 1 ] \
    || fail "patch must name exactly one source file"
[ "$(grep -c '^+++ ' "$PATCH_FILE")" -eq 1 ] \
    || fail "patch must name exactly one destination file"
grep -Fq -- '--- r6/scripts/alwaysFirstEquip.reds' "$PATCH_FILE" \
    || fail "patch does not target r6/scripts/alwaysFirstEquip.reds"
grep -Fq -- '+++ r6/scripts/alwaysFirstEquip.reds' "$PATCH_FILE" \
    || fail "patch does not produce r6/scripts/alwaysFirstEquip.reds"

added_request_fields="$({
    sed -n '/^+++/!s/^+//p' "$PATCH_FILE" \
        | grep -E 'weaRequest\.(requestType|requestSlot|dualWieldLoadoutEdit)[[:space:]]*=' \
        || true
})"
[ -z "$added_request_fields" ] \
    || fail "patch rewrites native equipment request fields: $added_request_fields"

added_request_conversion="$({
    sed -n '/^+++/!s/^+//p' "$PATCH_FILE" \
        | grep -E 'EquipmentManipulationRequestType\.(Equip|DualEquip)' \
        || true
})"
[ -z "$added_request_conversion" ] \
    || fail "patch invents an Equip/DualEquip request conversion: $added_request_conversion"

WORK_DIR="$(mktemp -d /private/tmp/always-first-equip-dual-wield-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/r6/scripts"
ORIGINAL_SOURCE="$WORK_DIR/r6/scripts/alwaysFirstEquip.original.reds"
PATCHED_SOURCE="$WORK_DIR/r6/scripts/alwaysFirstEquip.reds"
EXPECTED_SOURCE="$WORK_DIR/r6/scripts/alwaysFirstEquip.expected.reds"

# Normalize the live file's CRLF endings in the temporary copies so the
# expected-source comparison is about REDscript content, not line endings.
sed 's/\r$//' "$SOURCE_FILE" > "$ORIGINAL_SOURCE"
cp "$ORIGINAL_SOURCE" "$PATCHED_SOURCE"

(cd "$WORK_DIR" && patch -p0 -N -l -s < "$PATCH_FILE") \
    || fail "patch did not apply cleanly to a copied live source"

awk '
    /^@replaceMethod\(EquipmentSystemPlayerData\)$/ {
        if (annotation_pending) {
            exit 2
        }
        annotation_pending = 1
        next
    }
    annotation_pending {
        if (index($0, "private final func RequestEquipmentStateMachine(") != 1) {
            exit 2
        }
        annotation_pending = 0
        in_target = 1
        found = 1
        next
    }
    in_target {
        if ($0 == "}") {
            in_target = 0
            closed = 1
            drop_separator = 1
        }
        next
    }
    drop_separator && $0 == "" {
        drop_separator = 0
        next
    }
    { print }
    END {
        if (!found || !closed || annotation_pending || in_target) {
            exit 2
        }
    }
' "$ORIGINAL_SOURCE" > "$EXPECTED_SOURCE" \
    || fail "could not derive expected source without the target method"

if ! cmp -s "$EXPECTED_SOURCE" "$PATCHED_SOURCE"; then
    diff -u "$EXPECTED_SOURCE" "$PATCHED_SOURCE" >&2 || true
    fail "patched source differs beyond removal of the target method block"
fi

if grep -Fq 'func RequestEquipmentStateMachine(' "$PATCHED_SOURCE"; then
    fail "RequestEquipmentStateMachine replacement remains after patch"
fi
if grep -Fq '@replaceMethod(EquipmentSystemPlayerData)' "$PATCHED_SOURCE"; then
    fail "EquipmentSystemPlayerData replacement ownership remains after patch"
fi
grep -Fq '@replaceMethod(EquipmentBaseTransition)' "$PATCHED_SOURCE" \
    || fail "patch removed an unrelated EquipmentBaseTransition replacement"
grep -Fq 'func HandleWeaponEquip(' "$PATCHED_SOURCE" \
    || fail "patch removed unrelated first-equip behavior"

echo "always first equip dual-wield static patch test passed"
