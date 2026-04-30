#!/usr/bin/env bash
# Static regression smoke test for the cross-distro Snapper-relevance gate
# in the embedded Python notifier (zypper-notify-updater.py).
#
# Why this test exists:
# Older builds of `check_snapshots()` unconditionally invoked `snapper
# list-configs` and surfaced "Snapper not installed" whenever the binary was
# missing. That is misleading on cross-distro hosts (Fedora/Ubuntu/Arch) where
# Snapper is not the default snapshot tool — Snapper is btrfs-tied in
# practice. The new helpers `_root_filesystem_type()` and
# `_snapper_is_relevant()` short-circuit `check_snapshots()` with `(True, "")`
# on systems where Snapper is not relevant, so the existing
# `if snapshot_msg:` guard at the call site silently suppresses the warning
# on those hosts. Tumbleweed/Leap btrfs hosts where Snapper is meaningful
# keep the original card unchanged.
#
# This regression guards (static, no runtime needed):
#  1. `_root_filesystem_type()` is defined and uses findmnt + /proc/mounts
#     fallback for the FSTYPE detection.
#  2. `_snapper_is_relevant()` is defined and gates relevance on
#     `fstype == "btrfs"` plus the `SYSTEM_PKG_MANAGER == "zypper"` fallback
#     for ambiguous detection.
#  3. `check_snapshots()` calls `_snapper_is_relevant()` early and
#     short-circuits with `(True, "")` when it returns False, so the caller
#     suppresses the "Snapper not installed" line on non-btrfs hosts.
#  4. The Python notifier still imports `shutil` (relied on by
#     `_root_filesystem_type` for `shutil.which("findmnt")`).
#
# Format: prints `FAIL SUMMARY (N)` and exits 1 on failure; otherwise PASS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_notifier_snapper_relevance_regression.sh [path/to/UNI-auto.sh]

Static regression for the cross-distro Snapper-relevance gate in the embedded
notifier `check_snapshots()`. Asserts the new helpers exist and that the
gate routes correctly so non-btrfs hosts no longer see a misleading
"Snapper not installed" warning in the Updates Ready notification.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ ! -f "${TARGET_FILE}" ]; then
    echo "FAIL SUMMARY (1)" >&2
    echo " - Target file not found: ${TARGET_FILE}" >&2
    exit 1
fi

FAILURES=()

record_failure() {
    FAILURES+=("$1")
}

require_contains() {
    local needle="$1" label="$2"
    if ! grep -Fq -- "${needle}" "${TARGET_FILE}"; then
        record_failure "${label} (missing: ${needle})"
    fi
}

require_extended_grep() {
    local pattern="$1" label="$2"
    if ! grep -Eq -- "${pattern}" "${TARGET_FILE}"; then
        record_failure "${label} (missing pattern: ${pattern})"
    fi
}

# --- 1) Root-filesystem detection helper exists and uses findmnt ---
require_contains \
    'def _root_filesystem_type() -> str:' \
    "Missing helper _root_filesystem_type (root FS detection for Snapper relevance)"
require_contains \
    'shutil.which("findmnt")' \
    "_root_filesystem_type does not probe for findmnt before invoking it"
require_contains \
    '"findmnt", "-n", "-o", "FSTYPE", "/"' \
    "_root_filesystem_type does not invoke findmnt with the expected argv (findmnt -n -o FSTYPE /)"
require_contains \
    'open("/proc/mounts", "r", encoding="utf-8")' \
    "_root_filesystem_type is missing the /proc/mounts fallback path"

# --- 2) Snapper-relevance helper exists and gates by btrfs root + zypper PM ---
require_contains \
    'def _snapper_is_relevant() -> bool:' \
    "Missing helper _snapper_is_relevant (cross-distro Snapper gate)"
require_contains \
    'fstype = _root_filesystem_type()' \
    "_snapper_is_relevant does not read root filesystem via _root_filesystem_type"
require_contains \
    'return SYSTEM_PKG_MANAGER == "zypper"' \
    "_snapper_is_relevant is missing the zypper-PM fallback when FS detection failed"
require_contains \
    'return fstype == "btrfs"' \
    "_snapper_is_relevant does not treat btrfs root as the canonical relevance signal"

# --- 3) check_snapshots short-circuits with (True, "") on non-relevant hosts ---
require_contains \
    'def check_snapshots() -> tuple[bool, str]:' \
    "check_snapshots() definition missing (cross-distro gate is wired into this function)"
require_contains \
    'if not _snapper_is_relevant():' \
    "check_snapshots() does not call _snapper_is_relevant() for the cross-distro short-circuit"
require_contains \
    'return True, ""' \
    "check_snapshots() does not short-circuit with (True, \"\") so the 'Snapper not installed' warning is still surfaced on non-btrfs hosts"
require_extended_grep \
    'Snapper relevance check: skipped \(pm=' \
    "check_snapshots() short-circuit is missing the debug log line documenting the skip"

# --- 4) shutil import still present (used by _root_filesystem_type) ---
require_extended_grep \
    '^import shutil$' \
    "Notifier no longer imports shutil (required by _root_filesystem_type for shutil.which)"

# --- 5) bash -n syntax check on the host script ---
if ! bash -n "${TARGET_FILE}" 2>/dev/null; then
    record_failure "bash -n syntax check failed for ${TARGET_FILE}"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: notifier Snapper-relevance cross-distro gate intact"
