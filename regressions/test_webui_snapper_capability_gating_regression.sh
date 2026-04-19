#!/usr/bin/env bash
# RUNNER_NEEDS_TARGET=0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_webui_snapper_capability_gating_regression.sh [path/to/UNI-auto.sh]

Focused static regression for Snapper/Ghost WebUI capability gating:
  - backend exposes /api/snapper/capabilities contract
  - dashboard markup includes capability banners and scrub section id hooks
  - frontend has capability refresh/apply functions and startup/resume wiring
EOF
}

FAILURES=()

record_failure() {
    local msg="$1"
    FAILURES+=("${msg}")
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if ! grep -Fq -- "${needle}" <<< "${haystack}"; then
        record_failure "${label} (missing: ${needle})"
    fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ ! -f "${TARGET_FILE}" ]; then
    record_failure "Target file not found: ${TARGET_FILE}"
fi

source_text=""
if [ -f "${TARGET_FILE}" ]; then
    source_text="$(cat -- "${TARGET_FILE}")"
fi

assert_contains "${source_text}" "if path == \"/api/snapper/capabilities\":" "missing Snapper capability API endpoint"
assert_contains "${source_text}" "\"snapper_supported\": bool(snapper_supported)," "capability payload missing snapper_supported"
assert_contains "${source_text}" "\"ghost_scrub_supported\": bool(ghost_supported)," "capability payload missing ghost_scrub_supported"
assert_contains "${source_text}" "\"systemd_boot_detected\": bool(systemd_boot_detected)," "capability payload missing systemd_boot_detected"
assert_contains "${source_text}" "\"grub_detected\": bool(grub_detected)," "capability payload missing grub_detected"

assert_contains "${source_text}" "id=\"snapper-capability-banner\"" "missing snapper capability banner markup"
assert_contains "${source_text}" "id=\"scrub-capability-banner\"" "missing scrub capability banner markup"
assert_contains "${source_text}" "id=\"scrub-ghost-section\"" "missing scrub section hook id"
assert_contains "${source_text}" ".znh-cap-disabled {" "missing disabled gray-out style"

assert_contains "${source_text}" "function znhSnapperApplyCapabilities(caps) {" "missing frontend capability apply function"
assert_contains "${source_text}" "function znhSnapperCapabilityRefresh() {" "missing frontend capability refresh function"
assert_contains "${source_text}" "_api('/api/snapper/capabilities', { method: 'GET' })" "missing frontend call to capability endpoint"
assert_contains "${source_text}" "typeof znhSnapperCapabilityRefresh" "missing capability refresh wiring checks"
assert_contains "${source_text}" "znhSnapperCapabilityRefresh();" "missing startup capability refresh call"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: Snapper/Ghost capability gating regression checks passed"
