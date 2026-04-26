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
Usage: ./test_webui_settings_capability_gating_regression.sh [path/to/UNI-auto.sh]

Focused static regression for the adaptive (capability-aware) Settings drawer:
  - Dashboard schema tags platform-specific keys with `requires` blocks
    (zypper-only / RPM-based / Snapper+Btrfs / BLS / kernel purge)
  - Backend exposes /api/system/capabilities reusing _compute_system_capabilities
  - Embedded Python validator (_validate) is capability-aware and preserves
    existing values when the host does not satisfy a key's requirements
  - Frontend renderer applies _capabilityLockReason + znh-capability-locked
    class to grey out unsupported rows and shows a single banner near the top
  - _collectSettingsPatch skips capability-locked rows so save/autosave never
    rewrites unsupported settings on apt/dnf/pacman or non-Btrfs hosts
  - settingsLoad fetches /api/system/capabilities and stores it for the renderer
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
    echo "FAIL SUMMARY (1)" >&2
    echo " - Target file not found: ${TARGET_FILE}" >&2
    exit 1
fi

source_text="$(cat -- "${TARGET_FILE}")"

# Schema `requires` tags: zypper-only options.
assert_contains "${source_text}" "\"ZYPPER_TURBO_TUNER_ENABLED\": {\"type\": \"bool\", \"default\": \"false\", \"requires\": {\"pm\": [\"zypper\"]}}" "schema missing zypper requires for ZYPPER_TURBO_TUNER_ENABLED"
assert_contains "${source_text}" "\"ROCKET_WIZARD_USE_XMLOUT\": {\"type\": \"bool\", \"default\": \"true\", \"requires\": {\"pm\": [\"zypper\"]}}" "schema missing zypper requires for ROCKET_WIZARD_USE_XMLOUT"
assert_contains "${source_text}" "\"ROCKET_WIZARD_ALLOW_VENDOR_CHANGE\": {\"type\": \"bool\", \"default\": \"false\", \"requires\": {\"pm\": [\"zypper\"]}}" "schema missing zypper requires for ROCKET_WIZARD_ALLOW_VENDOR_CHANGE"
assert_contains "${source_text}" "\"ROCKET_WIZARD_FORCE_RESOLUTION\": {\"type\": \"bool\", \"default\": \"false\", \"requires\": {\"pm\": [\"zypper\"]}}" "schema missing zypper requires for ROCKET_WIZARD_FORCE_RESOLUTION"

# Schema `requires` tags: rpm-based, snapper, ghost-scrub, kernel-purge gates.
assert_contains "${source_text}" "\"AUTO_DUPLICATE_RPM_MODE\":" "schema missing AUTO_DUPLICATE_RPM_MODE entry"
assert_contains "${source_text}" "\"requires\": {\"rpm_based\": true}" "schema missing rpm_based requires gate (e.g. AUTO_DUPLICATE_RPM_MODE)"
assert_contains "${source_text}" "\"SNAP_RETENTION_OPTIMIZER_ENABLED\":" "schema missing SNAP_RETENTION_OPTIMIZER_ENABLED entry"
assert_contains "${source_text}" "\"requires\": {\"snapper\": true}" "schema missing snapper requires gate (e.g. SNAP_RETENTION_*)"
assert_contains "${source_text}" "\"BOOT_ENTRY_CLEANUP_MODE\":" "schema missing BOOT_ENTRY_CLEANUP_MODE entry"
assert_contains "${source_text}" "\"requires\": {\"ghost_scrub\": true}" "schema missing ghost_scrub requires gate (e.g. BOOT_ENTRY_CLEANUP_*/SCRUB_GHOST_*)"
assert_contains "${source_text}" "\"KERNEL_PURGE_ENABLED\":" "schema missing KERNEL_PURGE_ENABLED entry"
assert_contains "${source_text}" "\"requires\": {\"kernel_purge\": true}" "schema missing kernel_purge requires gate (e.g. KERNEL_PURGE_*/KERNEL_FAMILY_PURGE_*)"

# Backend: capability-aware validator + capabilities probe.
assert_contains "${source_text}" "def _capability_satisfied(meta: dict, caps: dict) -> bool:" "missing _capability_satisfied helper in embedded validator"
assert_contains "${source_text}" "def _validate(cfg: dict, caps: dict | None = None) -> tuple[dict, list[str], list[str]]:" "_validate signature missing capability map parameter"
assert_contains "${source_text}" "if not _capability_satisfied(meta, caps_map):" "_validate is not skipping coercion for unmet capabilities"
assert_contains "${source_text}" "def _compute_system_capabilities() -> dict:" "missing _compute_system_capabilities helper"
assert_contains "${source_text}" "_CAPABILITIES_CACHE = {\"ts\": 0.0, \"data\": {}}" "missing capabilities cache module-level state"
assert_contains "${source_text}" "\"snapper_missing_reasons\": []," "capabilities map missing snapper_missing_reasons key"
assert_contains "${source_text}" "\"ghost_missing_reasons\": []," "capabilities map missing ghost_missing_reasons key"
assert_contains "${source_text}" "\"kernel_purge_missing_reasons\": []," "capabilities map missing kernel_purge_missing_reasons key"

# Backend: dedicated /api/system/capabilities endpoint.
assert_contains "${source_text}" "if path == \"/api/system/capabilities\":" "missing /api/system/capabilities endpoint route"
assert_contains "${source_text}" "caps = _compute_system_capabilities()" "/api/system/capabilities is not reusing _compute_system_capabilities"

# Backend: POST /api/config validate call passes capabilities map.
assert_contains "${source_text}" "_caps = _compute_system_capabilities()" "POST /api/config is not computing capabilities for validate"
assert_contains "${source_text}" "eff2, warnings2, invalid2 = _validate(eff, _caps)" "POST /api/config _validate call is not capability-aware"

# Frontend: capability lock helper + renderer wiring + skip + load.
assert_contains "${source_text}" "function _capabilityLockReason(meta, caps) {" "missing frontend _capabilityLockReason helper"
assert_contains "${source_text}" "row.classList.add('znh-capability-locked');" "renderer is not tagging locked rows with znh-capability-locked class"
assert_contains "${source_text}" "capabilityLockedKeys.push(f.key);" "renderer is not tracking capabilityLockedKeys for the banner"
assert_contains "${source_text}" "capBanner.className = 'znh-capability-lock-banner';" "renderer is not inserting the capability-lock banner element"
assert_contains "${source_text}" "if (row && row.classList && row.classList.contains('znh-capability-locked')) {" "_collectSettingsPatch is not skipping capability-locked rows on save"
assert_contains "${source_text}" "_api('/api/system/capabilities', { method: 'GET' })" "settingsLoad is not fetching /api/system/capabilities"
assert_contains "${source_text}" "_settingsCapabilities = caps || null;" "settingsLoad is not storing capabilities for the renderer"
assert_contains "${source_text}" "var _settingsCapabilities = null;" "missing _settingsCapabilities global declaration"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: WebUI Settings drawer capability-aware gating regression checks passed"
