#!/usr/bin/env bash
# Static regression smoke test for the cross-distro downloader/verify unit
# ReadWritePaths fix and the new distro-upgrade prefetch hook.
#
# Why this test exists:
# Older builds shipped `ReadWritePaths=/var/cache/zypp /var/cache/dnf /var/cache/apt
# /var/cache/pacman/pkg /var/lib/dnf /var/lib/apt /var/lib/pacman /var/lib/dpkg ...`
# without the systemd `-` optional-path prefix. On any distro that doesn't have
# ALL of those paths (Fedora -> no /var/cache/apt, Debian -> no /var/cache/dnf,
# Arch -> no /var/cache/zypp, etc.), the unit failed with code=226/NAMESPACE
# before it could write download-status.txt, leaving the dashboard stuck on
# "DOWNLOADER STATUS: idle".
#
# This regression guards:
#   * `ReadWritePaths=` for the generated downloader unit prefixes every
#     distro-specific cache/state path with `-` (optional-path).
#   * `/var/log/zypper-auto` stays unprefixed.
#   * The verify unit's fallback ReadWritePaths line is also cross-distro safe.
#   * `--verify` now contains an auto-repair pass for the deployed downloader
#     unit so older installs heal automatically.
#   * The new `DOWNLOADER_INCLUDE_DISTRO_UPGRADE` config knob is wired
#     (validate_bool_flag, downloader env read, helper definition + invocation).
#
# Format: prints `FAIL SUMMARY (N)` and exits 1 on failure.

# This regression intentionally greps the target file for literal
# `${...}` placeholders that appear inside heredocs (the unit-template line
# uses `${LOG_DIR}`/`${user_dash_rw}` and `${dl_expected_rw}`). Single quotes
# are required so the shell does not expand them before grep sees them.
# shellcheck disable=SC2016,SC1003

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_downloader_unit_readwritepaths_regression.sh [path/to/UNI-auto.sh]

Asserts that the generated zypper-autodownload.service is cross-distro safe
and that the downloader prefetch flow hooks distro-upgrade staging behind a
documented config knob.
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

require_not_contains() {
    local needle="$1" label="$2"
    if grep -Fq -- "${needle}" "${TARGET_FILE}"; then
        record_failure "${label} (unexpected: ${needle})"
    fi
}

# --- 1) Downloader unit ReadWritePaths must prefix distro-specific paths with '-' ---
require_contains \
    "ReadWritePaths=/var/log/zypper-auto -/var/cache/zypp -/var/cache/zypp/packages -/var/cache/dnf -/var/cache/libdnf5 -/var/cache/apt -/var/cache/apt/archives -/var/cache/pacman/pkg -/var/lib/dnf -/var/lib/apt -/var/lib/apt/lists -/var/lib/pacman -/var/lib/dpkg -/var/lib/zypp -/var/lib/zypper -/var/lib/zypper-auto" \
    "Downloader unit ReadWritePaths is not cross-distro safe (must prefix every distro-specific path with '-')"

# Negative: the previous unprefixed form must be gone in the unit-template heredoc.
require_not_contains \
    "ReadWritePaths=/var/cache/zypp /var/cache/dnf /var/cache/apt /var/cache/pacman/pkg /var/lib/dnf /var/lib/apt /var/lib/pacman /var/lib/dpkg /var/log/zypper-auto" \
    "Old unprefixed ReadWritePaths line is still present in downloader service template"

# --- 2) Verify unit fallback ReadWritePaths uses '-' prefix on /var/cache/zypp ---
require_contains \
    'ReadWritePaths=${LOG_DIR} /run /var/run -/var/cache/zypp -/var/cache/dnf -/var/cache/apt -/var/cache/pacman/pkg ${user_dash_rw}' \
    "Verify unit fallback ReadWritePaths is not cross-distro safe (must prefix /var/cache/zypp etc. with '-')"

# --- 3) --verify contains the new auto-repair check for the installed downloader unit ---
require_contains \
    'Check 10c: Downloader unit ReadWritePaths must tolerate cross-distro paths.' \
    "Missing Check 10c (auto-repair for deployed downloader unit ReadWritePaths) in --verify path"
require_contains \
    'DL_UNIT_FILE="/etc/systemd/system/zypper-autodownload.service"' \
    "Check 10c does not target /etc/systemd/system/zypper-autodownload.service"
require_contains \
    'sed -i "s|^ReadWritePaths=.*$|${dl_expected_rw}|" "${DL_UNIT_FILE}"' \
    "Check 10c does not rewrite the deployed unit's ReadWritePaths line"
require_contains \
    'systemctl reset-failed zypper-autodownload.service' \
    "Check 10c does not reset failed state after rewriting the unit"
require_contains \
    'Restart downloader timer (apply ReadWritePaths fix)' \
    "Check 10c does not restart the downloader timer after rewriting the unit"

# --- 4) DOWNLOADER_INCLUDE_DISTRO_UPGRADE config knob is documented + validated ---
require_contains \
    '# DOWNLOADER_INCLUDE_DISTRO_UPGRADE' \
    "DOWNLOADER_INCLUDE_DISTRO_UPGRADE knob is missing from /etc/zypper-auto.conf documentation"
require_contains \
    'DOWNLOADER_INCLUDE_DISTRO_UPGRADE=true' \
    "DOWNLOADER_INCLUDE_DISTRO_UPGRADE default value is missing from the config template"
require_contains \
    'validate_bool_flag DOWNLOADER_INCLUDE_DISTRO_UPGRADE true' \
    "DOWNLOADER_INCLUDE_DISTRO_UPGRADE is not validated by load_config"

# --- 5) Embedded downloader script reads the flag and defines the prefetch helper ---
require_contains \
    'DOWNLOADER_INCLUDE_DISTRO_UPGRADE="${DOWNLOADER_INCLUDE_DISTRO_UPGRADE:-true}"' \
    "Embedded downloader script does not read DOWNLOADER_INCLUDE_DISTRO_UPGRADE env"
require_contains \
    'znh_downloader_distro_upgrade_prefetch() {' \
    "Embedded downloader script is missing znh_downloader_distro_upgrade_prefetch helper"
# Fedora-only safe prefetch command must be present
require_contains \
    '"${dnf_bin}" system-upgrade download --refresh --releasever="${target}" -y' \
    "distro-upgrade prefetch helper is missing the dnf system-upgrade download invocation"
# Helper writes a low-priority command (nice -n 10 + ionice -c2 -n7)
require_contains \
    '/usr/bin/nice -n 10 /usr/bin/ionice -c2 -n7 \' \
    "distro-upgrade prefetch helper does not run the heavy command at low priority"
# Detect-only mode must short-circuit the helper
require_contains \
    'Distro-upgrade prefetch skipped (DOWNLOADER_DOWNLOAD_MODE=detect-only)' \
    "distro-upgrade prefetch helper is missing the detect-only short-circuit"
# Disable knob must short-circuit the helper as well
require_contains \
    'Distro-upgrade prefetch disabled via DOWNLOADER_INCLUDE_DISTRO_UPGRADE' \
    "distro-upgrade prefetch helper does not honor DOWNLOADER_INCLUDE_DISTRO_UPGRADE=false"

# --- 6) The helper must be invoked from BOTH cross-distro and zypper completion paths ---
# Count the call sites; both branches should reach this helper before exiting.
prefetch_call_count="$(grep -c -- 'znh_downloader_distro_upgrade_prefetch || true' "${TARGET_FILE}" || true)"
if [ "${prefetch_call_count:-0}" -lt 2 ]; then
    record_failure "distro-upgrade prefetch helper must be invoked in both cross-distro and zypper flows (found ${prefetch_call_count:-0}, need >=2)"
fi

# --- 7) bash -n syntax check ---
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

echo "PASS: cross-distro downloader unit + distro-upgrade prefetch wiring intact"
