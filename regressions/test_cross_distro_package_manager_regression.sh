#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_cross_distro_package_manager_regression.sh [path/to/UNI-auto.sh]

Static regression smoke test for cross-distro package-manager wiring:
  - package manager detection supports apt/dnf/pacman/zypper
  - package name resolution and install-hint helpers exist
  - dependency installer path uses the package-manager abstraction
  - phase-2 runtime helpers wire downloader/install/notifier/view paths
  - hardcoded "sudo zypper install" guidance is no longer present
EOF
}

FAILURES=()

record_failure() {
    local msg="$1"
    FAILURES+=("${msg}")
}

require_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if ! grep -Fq -- "${needle}" <<< "${haystack}"; then
        record_failure "${label} (missing: ${needle})"
    fi
}

require_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if grep -Fq -- "${needle}" <<< "${haystack}"; then
        record_failure "${label} (unexpected: ${needle})"
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

require_contains "${source_text}" "detect_system_package_manager() {" "Missing package-manager detection helper"
require_contains "${source_text}" "SYSTEM_PKG_MANAGER=\"apt\"" "Missing apt detection path"
require_contains "${source_text}" "SYSTEM_PKG_MANAGER=\"dnf\"" "Missing dnf detection path"
require_contains "${source_text}" "SYSTEM_PKG_MANAGER=\"pacman\"" "Missing pacman detection path"
require_contains "${source_text}" "SYSTEM_PKG_MANAGER=\"zypper\"" "Missing zypper detection path"

require_contains "${source_text}" "znh_resolve_package_name() {" "Missing package-name resolver helper"
require_contains "${source_text}" "znh_install_hint_for_package() {" "Missing install-hint helper"
require_contains "${source_text}" "znh_install_package_via_system_pm() {" "Missing package install helper"

require_contains "${source_text}" "package=\"\$(znh_resolve_package_name \"\$logical_package\")\"" "Dependency checker is not using package-name resolver"
require_contains "${source_text}" "if ! znh_install_package_via_system_pm \"\$package\"; then" "Dependency checker is not using package-manager install helper"
# Phase-2 runtime abstraction checks (downloader/install/notifier/view paths)
require_contains "${source_text}" "PM_RUNTIME_HELPER_PATH=\"\${PM_RUNTIME_HELPER_DIR}/package-manager-runtime.sh\"" "Missing shared PM helper path definition"
require_contains "${source_text}" "write_atomic \"\${PM_RUNTIME_HELPER_PATH}\" << 'EOF'" "Missing shared PM helper generation block"
require_contains "${source_text}" "znh_pm_downloader_refresh_run() {" "Shared PM helper missing downloader refresh dispatcher"
require_contains "${source_text}" "znh_pm_install_upgrade_streaming() {" "Shared PM helper missing install-upgrade dispatcher"
require_contains "${source_text}" "znh_pm_view_changes_preview_run() {" "Shared PM helper missing view-changes preview dispatcher"
require_contains "${source_text}" "znh_pm_query_notifier_preview_command_argv() {" "Shared PM helper missing notifier preview argv query function"
require_contains "${source_text}" "PM_RUNTIME_HELPER=\"/usr/local/lib/zypper-auto/package-manager-runtime.sh\"" "Runtime consumers are not declaring shared helper path"
require_contains "${source_text}" ". \"\${PM_RUNTIME_HELPER}\"" "Runtime consumers are not sourcing shared helper"
require_contains "${source_text}" "znh_pm_is_lock_failure" "Missing downloader lock classifier wiring to shared PM helper"
require_contains "${source_text}" "znh_pm_is_network_output_file" "Missing downloader network classifier wiring to shared PM helper"
require_contains "${source_text}" "znh_pm_downloader_refresh_run >/dev/null 2>\"\$REFRESH_ERR\"" "Missing downloader refresh invocation via shared PM helper"
require_contains "${source_text}" "znh_pm_downloader_preview_run \"\$DRY_OUTPUT\" \"\$DRY_ERR\"" "Missing downloader preview invocation via shared PM helper"
require_contains "${source_text}" "znh_pm_downloader_download_run \"\$DL_ERR\" \"\${DUP_EXTRA_FLAGS:-}\"" "Missing downloader download invocation via shared PM helper"

require_contains "${source_text}" "znh_pm_install_upgrade_streaming \"\${LOG_FILE}\" \"\${tmp_out}\"" "Missing install helper runtime upgrade dispatch call"
require_contains "${source_text}" "znh_pm_capture_package_snapshot \"\${PKG_PRE_FILE}\"" "Missing install helper pre-update package snapshot dispatch call"
require_contains "${source_text}" "pkexec env DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade" "Install helper missing apt upgrade command"
require_contains "${source_text}" "pkexec dnf -y upgrade" "Install helper missing dnf upgrade command"
require_contains "${source_text}" "pkexec pacman -Syu --noconfirm" "Install helper missing pacman upgrade command"

require_contains "${source_text}" "_preview_command() -> list[str]:" "Notifier missing preview command builder helper"
require_contains "${source_text}" "_run_preview_command(timeout: int = 60) -> tuple[int, str]:" "Notifier missing preview command runner helper"
require_contains "${source_text}" "_recommended_manual_update_command() -> str:" "Notifier missing manual update command helper"
require_contains "${source_text}" "_recommended_manual_refresh_command() -> str:" "Notifier missing manual refresh command helper"
require_contains "${source_text}" "helper_argv = _query_pm_helper_argv(\"notifier-preview-command-argv\")" "Notifier preview command is not wired to shared helper query"
require_contains "${source_text}" "helper_pm = _query_pm_helper_text(\"package-manager\")" "Notifier package-manager detection is not wired to shared helper query"
require_contains "${source_text}" "rc, preview_output = _run_preview_command(timeout=30)" "Notifier completion check is not using manager-aware preview runner"
require_contains "${source_text}" "rc, dry_output = _run_preview_command(timeout=60)" "Notifier solver summary is not using manager-aware preview runner"
require_contains "${source_text}" "refresh_cmd = _recommended_manual_refresh_command()" "Notifier repository-error path is not using manager-aware refresh guidance"

require_contains "${source_text}" "pkexec env DEBIAN_FRONTEND=noninteractive apt-get -s dist-upgrade" "View-changes helper missing apt preview command"
require_contains "${source_text}" "pkexec dnf -q check-update" "View-changes helper missing dnf preview command"
require_contains "${source_text}" "pkexec pacman -Qu" "View-changes helper missing pacman preview command"

require_not_contains "${source_text}" "sudo zypper install" "Hardcoded zypper install guidance still present"
require_not_contains "${source_text}" "The background updater could not reach the openSUSE repositories." "Notifier network error message is still openSUSE-only"
require_not_contains "${source_text}" "Run 'sudo zypper refresh' in a terminal for full details." "Notifier repository recovery hint is still hardcoded to zypper refresh"
require_not_contains "${source_text}" "No zypper run performed (environment not safe). Exiting." "Notifier empty-preview log path is still zypper-only"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: cross-distro package-manager regression checks passed"
