#!/usr/bin/env bash
# Static regression smoke test for the cross-distro manual-update wrapper
# (zypper-with-ps + dnf/apt/apt-get/pacman-with-ps symlinks) and the
# "stuck after typing y" bug fix (no 2>&1 before | tee).
#
# Why this test exists:
#  1. The wrapper used `sudo /usr/bin/zypper "$@" 2>&1 | tee`, which merged
#     stderr into the pipe so the PM saw a non-TTY stderr and auto-cancelled
#     the interactive Continue prompt — `sudo zypper dup` did nothing after `y`.
#  2. The wrapper was zypper-only; it now also wraps dnf/apt/apt-get/pacman via
#     basename dispatch (symlinks), with per-PM update detection, post-update
#     service/reboot checks, and RPM-only duplicate-RPM cleanup.
#
# This regression guards (static, no runtime needed):
#  - WRAPPER_PM basename dispatch + __znh_pm_binary.
#  - Per-PM __znh_pm_is_update_cmd verbs.
#  - __znh_pm_is_nothing_to_do / __znh_pm_post_update_service_check /
#    __znh_pm_needs_reboot / __znh_pm_is_rpm_based helpers.
#  - The command exec uses __znh_run_pm_pty (script PTY) with NO "| tee" pipe.
#  - Fish sudo-handler intercepts all 5 PMs; zypper-wrapper.fish defines all 5.
#  - Generator creates the dnf/apt/apt-get/pacman-with-ps symlinks.
#  - Uninstaller removes the symlinks + alias lines.
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
Usage: ./test_wrapper_cross_distro_regression.sh [path/to/UNI-auto.sh]

Static regression for the cross-distro manual-update wrapper. Asserts the
PM-aware dispatch helpers, the no-2>&1 command exec, the fish intercepts,
the symlink creation in the generator, and the uninstaller cleanup.
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

require_not_contains() {
    local needle="$1" label="$2"
    if grep -Fq -- "${needle}" "${TARGET_FILE}"; then
        record_failure "${label} (unexpected: ${needle})"
    fi
}

# --- 1) PM-aware dispatch helpers (generator heredoc) ---
require_contains '__znh_wrapper_pm_from_invocation' "Missing __znh_wrapper_pm_from_invocation helper"
require_contains '__znh_pm_binary' "Missing __znh_pm_binary helper"
require_contains '__znh_pm_is_update_cmd' "Missing __znh_pm_is_update_cmd helper"
require_contains '__znh_pm_is_nothing_to_do' "Missing __znh_pm_is_nothing_to_do helper"
require_contains '__znh_pm_post_update_service_check' "Missing __znh_pm_post_update_service_check helper"
require_contains '__znh_pm_needs_reboot' "Missing __znh_pm_needs_reboot helper"
require_contains '__znh_pm_is_rpm_based' "Missing __znh_pm_is_rpm_based helper"
require_contains '__znh_run_pm_pty' "Missing __znh_run_pm_pty helper (PTY fix for the stuck-after-y bug)"
require_contains 'script -qec' "__znh_run_pm_pty does not use script -qec to allocate a PTY"
require_contains 'WRAPPER_PM="$(__znh_wrapper_pm_from_invocation)"' "WRAPPER_PM is not derived from __znh_wrapper_pm_from_invocation"

# --- 2) Per-PM update-verb detection ---
require_contains 'dnf-with-ps)        printf' "Basename dispatch missing dnf-with-ps -> dnf"
require_contains 'apt-with-ps)        printf' "Basename dispatch missing apt-with-ps -> apt"
require_contains 'apt-get-with-ps)    printf' "Basename dispatch missing apt-get-with-ps -> apt-get"
require_contains 'pacman-with-ps)     printf' "Basename dispatch missing pacman-with-ps -> pacman"
require_extended_grep '\*"-Syu"\*|\*"-Su"\*' "pacman update-verb detection (-Syu/-Su) missing"

# --- 3) Per-PM post-update + reboot checks ---
require_contains 'dnf needs-restarting -s' "dnf needs-restarting -s post-update check missing"
require_contains 'needrestart -l' "apt needrestart -l post-update check missing"
require_contains 'dnf needs-restarting -r' "dnf needs-restarting -r reboot check missing"
require_contains '/run/reboot-required' "Reboot-required marker fallback missing"

# --- 4) The bug fix: PM runs under a PTY via __znh_run_pm_pty (no | tee) ---
# The update-flow exec must call __znh_run_pm_pty (which uses `script` to
# allocate a PTY) instead of `sudo <pm> | tee`, which hung because sudo's
# setsid() put the PM in a session that wasn't the terminal's foreground pg.
require_contains '__znh_run_pm_pty "$ZYPPER_OUT_FILE"' "Update-flow exec does not call __znh_run_pm_pty"
require_not_contains 'sudo "/usr/bin/zypper" "$@" | tee' "Old | tee command exec still present (stuck-after-y bug)"
require_not_contains 'sudo "$(\$__znh_pm_binary)" "$@" | tee' "Old | tee command exec (PM-aware) still present"

# --- 5) RPM-only guards (zypp lock + duplicate cleanup) ---
if grep -Fq 'if [[ "${WRAPPER_PM}" == "zypper" ]]; then' "${TARGET_FILE}"; then
    : # lock guard present
else
    record_failure "zypp-lock wait is not guarded to WRAPPER_PM == zypper"
fi
require_extended_grep 'if __znh_pm_is_rpm_based; then' "duplicate-RPM cleanup is not guarded to __znh_pm_is_rpm_based"

# --- 6) Fish sudo-handler intercepts all 5 PMs ---
require_contains 'case zypper' "Fish sudo-handler missing 'case zypper'"
require_contains 'case dnf' "Fish sudo-handler missing 'case dnf'"
require_contains 'case apt' "Fish sudo-handler missing 'case apt'"
require_contains 'case apt-get' "Fish sudo-handler missing 'case apt-get'"
require_contains 'case pacman' "Fish sudo-handler missing 'case pacman'"

# --- 7) Fish wrapper functions for each PM ---
require_contains 'function dnf --wraps dnf' "Fish wrapper missing 'function dnf'"
require_contains 'function apt --wraps apt' "Fish wrapper missing 'function apt'"
require_contains 'function apt-get --wraps apt-get' "Fish wrapper missing 'function apt-get'"
require_contains 'function pacman --wraps pacman' "Fish wrapper missing 'function pacman'"
require_contains '~/.local/bin/dnf-with-ps' "Fish dnf function does not call dnf-with-ps"
require_contains '~/.local/bin/pacman-with-ps' "Fish pacman function does not call pacman-with-ps"

# --- 7b) Fish wrappers only route write-commands; read-only pass to command <pm> ---
# This prevents the fish completion syntax error (fish's built-in zypper
# completions call 'zypper --xmlout search' which must NOT go through the
# wrapper's sudo+script PTY layer).
require_contains 'command zypper $argv' "Fish zypper function missing 'command zypper' pass-through for read-only commands"
require_contains 'command dnf $argv' "Fish dnf function missing 'command dnf' pass-through"
require_contains 'command apt $argv' "Fish apt function missing 'command apt' pass-through"
require_contains 'command apt-get $argv' "Fish apt-get function missing 'command apt-get' pass-through"
require_contains 'command pacman $argv' "Fish pacman function missing 'command pacman' pass-through"
require_contains 'case dup dist-upgrade update up in install rm remove patch' "Fish zypper function missing write-command switch/case"

# --- 8) Generator creates the symlinks ---
require_contains 'ln -sf zypper-with-ps "${USER_BIN_DIR}/${_znh_pm_sym}-with-ps"' "Generator does not create the cross-distro PM symlinks"
require_contains 'Cross-distro PM wrapper symlinks created' "Generator missing symlink-creation success log"

# --- 9) Uninstaller removes the symlinks + alias lines ---
require_contains '"$SUDO_USER_HOME/.local/bin/dnf-with-ps"' "Uninstaller does not remove dnf-with-ps symlink"
require_contains '"$SUDO_USER_HOME/.local/bin/apt-with-ps"' "Uninstaller does not remove apt-with-ps symlink"
require_contains '"$SUDO_USER_HOME/.local/bin/apt-get-with-ps"' "Uninstaller does not remove apt-get-with-ps symlink"
require_contains '"$SUDO_USER_HOME/.local/bin/pacman-with-ps"' "Uninstaller does not remove pacman-with-ps symlink"
require_contains "/alias dnf=.*-with-ps/d" "Uninstaller bash sed missing alias dnf cleanup"
require_contains "/alias pacman=.*-with-ps/d" "Uninstaller bash sed missing alias pacman cleanup"

# --- 10) bash -n syntax check on the host script ---
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

echo "PASS: cross-distro manual-update wrapper wiring intact"
