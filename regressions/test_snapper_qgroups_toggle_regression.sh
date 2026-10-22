#!/usr/bin/env bash
# Static regression smoke test for the Btrfs qgroups (quota groups) management
# wired into the Snapper Manager (dashboard + CLI + API + installer/uninstaller).
#
# Why this test exists:
# Btrfs qgroups make snapper cleanup/list slow and can hang btrfs-cleaner (the
# qgroup data also frequently goes inconsistent, requiring a slow rescan). The
# helper now disables qgroups by default on install, exposes a live state tile
# + Enable/Disable toggle in the dashboard Snapper Manager, and provides
# `snapper qgroup-status|qgroup-enable|qgroup-disable` CLI subcommands. The
# installer records the pre-install state so --uninstall-zypper can restore it.
#
# This regression guards (static, no runtime needed):
#  1. The BTRFS_QGROUPS_ENABLED schema key (bool, default false, requires snapper).
#  2. The bash helpers + qgroup-status|qgroup-enable|qgroup-disable CLI subcommands.
#  3. The installer default-off function + pre-install state capture.
#  4. The uninstaller pre-install restore + state-file removal.
#  5. The dashboard API: /api/snapper/qgroups endpoint, qgroups capability, and
#     qgroup-enable/qgroup-disable (phrase QGROUPS) + qgroup-status action mapping.
#  6. The WebUI tile IDs + znhQgroupRefreshUI + capability-gating selectors.
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
Usage: ./test_snapper_qgroups_toggle_regression.sh [path/to/UNI-auto.sh]

Static regression for the Btrfs qgroups Snapper Manager toggle. Asserts the
schema key, bash helpers + CLI subcommands, installer default-off + pre-install
state capture, uninstaller restore + removal, dashboard API endpoint + action
mapping, and WebUI tile/JS wiring are all present.
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

# --- 1) Schema key (default OFF, requires snapper) ---
require_contains \
    '"BTRFS_QGROUPS_ENABLED": {"type": "bool", "default": "false", "requires": {"snapper": true}}' \
    "Schema key BTRFS_QGROUPS_ENABLED missing (bool, default false, requires snapper)"

# --- 2) Bash helpers + CLI subcommands ---
require_contains '__znh_btrfs_qgroup_supported()' "Missing __znh_btrfs_qgroup_supported helper"
require_contains '__znh_btrfs_qgroup_snapper_val()' "Missing __znh_btrfs_qgroup_snapper_val helper"
require_contains '__znh_btrfs_qgroup_set_snapper()' "Missing __znh_btrfs_qgroup_set_snapper helper"
require_contains '__znh_btrfs_qgroup_status()' "Missing __znh_btrfs_qgroup_status helper"
require_contains '__znh_btrfs_qgroup_enable()' "Missing __znh_btrfs_qgroup_enable helper"
require_contains '__znh_btrfs_qgroup_disable()' "Missing __znh_btrfs_qgroup_disable helper"
require_contains 'btrfs quota enable /' "qgroup enable does not run 'btrfs quota enable /'"
require_contains 'btrfs quota disable /' "qgroup disable does not run 'btrfs quota disable /'"
require_contains 'qgroup-status)' "Missing 'qgroup-status)' CLI dispatch case"
require_contains 'qgroup-enable)' "Missing 'qgroup-enable)' CLI dispatch case"
require_contains 'qgroup-disable)' "Missing 'qgroup-disable)' CLI dispatch case"
require_contains 'snapper qgroup-status' "snapper --help does not mention qgroup subcommands"

# --- 3) Installer default-off + pre-install state capture ---
require_contains '__znh_snapper_qgroup_install_default' "Missing __znh_snapper_qgroup_install_default installer function"
require_contains 'qgroups-preinstall.state' "Installer does not record qgroups-preinstall.state"
require_contains 'pre_state=' "Installer pre-install state file does not write pre_state="

# --- 4) Uninstaller pre-install restore + state-file removal ---
require_contains 'Restoring pre-install Btrfs qgroups state' "Uninstaller missing qgroup pre-install restore log line"
require_extended_grep 'btrfs quota enable /' "Uninstaller does not re-enable qgroups when restoring pre-install state"

# --- 5) Dashboard API: endpoint, capability, action mapping ---
require_contains 'if path == "/api/snapper/qgroups":' "Missing GET /api/snapper/qgroups endpoint"
require_contains '"qgroups_supported":' "/api/snapper/capabilities payload missing qgroups_supported"
require_contains '"btrfs_qgroups":' "_compute_system_capabilities missing btrfs_qgroups field"
require_contains '"qgroup-enable": "QGROUPS"' "Confirm phrase map missing qgroup-enable -> QGROUPS"
require_contains '"qgroup-disable": "QGROUPS"' "Confirm phrase map missing qgroup-disable -> QGROUPS"
require_contains '"qgroup-status"' "/api/snapper/run + /api/snapper/start missing qgroup-status action mapping"

# --- 6) WebUI tile IDs + JS wiring + capability gating ---
require_contains 'id="snapper-qgroup-box"' "WebUI missing snapper-qgroup-box stat-box"
require_contains 'id="snapper-qgroup-val"' "WebUI missing snapper-qgroup-val status element"
require_contains 'id="snapper-qgroup-enable-btn"' "WebUI missing snapper-qgroup-enable-btn button"
require_contains 'id="snapper-qgroup-disable-btn"' "WebUI missing snapper-qgroup-disable-btn button"
require_contains 'Why is this OFF by default?' "WebUI missing the 'Why is this OFF by default?' explanation"
require_contains 'function znhQgroupRefreshUI()' "Missing znhQgroupRefreshUI() JS function"
require_contains "snapperRun('qgroup-enable'" "WebUI Enable button not wired to snapperRun('qgroup-enable')"
require_contains "snapperRun('qgroup-disable'" "WebUI Disable button not wired to snapperRun('qgroup-disable')"
require_contains "'#snapper-qgroup-enable-btn'" "Capability gating selectors missing #snapper-qgroup-enable-btn"

# --- 7) bash -n syntax check on the host script ---
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

echo "PASS: Btrfs qgroups Snapper Manager toggle wiring intact"
