#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes are intentional: assertions grep
# the target for LITERAL unexpanded ${...} shell source strings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_dashboard_shortcut_sync_regression.sh [path/to/UNI-auto.sh]

Regression guard for the v92 desktop shortcut SYNC:
  - the generated .desktop embeds X-ZypperAuto-Shortcuts-Version (source of
    truth) and the Smart Update rewrites the shortcut whenever the installed
    marker differs (pre-marker files always rewrite; legacy content
    heuristics stay as belt-and-braces)
  - the Desktop-surface copy re-syncs when its own marker drifts
  - the dashboard shortcut still launches --dash-open (always the correct
    DASHBOARD_PORT-aware port) and the notification fallback URL is
    PORT-AWARE (reads dashboard-http.port, 8765 fallback) with a drift guard
    that the old hardcoded xdg-open URL is gone
  - RUNTIME fixtures (sandboxed temp HOME): first call creates the shortcut
    with the marker, a drifted marker (90) triggers a resync, and an
    up-to-date call is a no-op (no sync note); the Desktop copy is synced
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
        record_failure "${label} (must be gone, still present: ${needle})"
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

# --- 1) Version marker + marker-based sync (master) ---
require_contains "${source_text}" 'local shortcuts_ver="92"' "Missing the v92 shortcut version constant"
require_contains "${source_text}" 'X-ZypperAuto-Shortcuts-Version=${shortcuts_ver}' "Missing the v92 version marker in the generated .desktop heredoc"
require_contains "${source_text}" 'cur_ver="$(grep -F '"'"'X-ZypperAuto-Shortcuts-Version='"'"' "${desktop_file}" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"' "Missing the v92 installed-marker read"
require_contains "${source_text}" '[ "${cur_ver}" != "${shortcuts_ver}" ]' "Missing the v92 marker-diff sync trigger (the source of truth)"
require_contains "${source_text}" 'desktop shortcut synced to shortcuts-v' "Missing the v92 sync feedback note"

# --- 2) Desktop-surface copy sync ---
require_contains "${source_text}" 'copy_ver="$(grep -F '"'"'X-ZypperAuto-Shortcuts-Version='"'"' "${desktop_copy}" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"' "Missing the v92 Desktop-copy marker read"
require_contains "${source_text}" '[ "${copy_ver}" != "${shortcuts_ver}" ]' "Missing the v92 Desktop-copy drift trigger"

# --- 3) Port-correct launch surfaces ---
require_contains "${source_text}" 'Exec=${helper_bin} --dash-open' "The dashboard shortcut must launch --dash-open (port-aware), not a hardcoded URL"
require_contains "${source_text}" 'dashboard-http.port" 2>/dev/null || echo 8765' "Missing the v92 port-aware fallback URL (reads the recorded port)"
require_not_contains "${source_text}" 'xdg-open "http://127.0.0.1:8765/status.html?live=1"' "The old hardcoded xdg-open dashboard URL must be gone (breaks on moved/pinned ports)"

# --- 4) Bash syntax sanity of the target file ---
if ! bash -n "${TARGET_FILE}" >/dev/null 2>&1; then
    record_failure "Target file fails bash -n syntax check: ${TARGET_FILE}"
fi

# --- 5) RUNTIME: sandboxed shortcut generate/resync/idempotence ---
_sc_fn_tmp="$(mktemp /tmp/znh_sc_fn.XXXXXX)"
sed -n '/^__znh_ensure_dash_desktop_shortcut() {/,/^}$/p' "${TARGET_FILE}" > "${_sc_fn_tmp}" 2>/dev/null || true
if [ ! -s "${_sc_fn_tmp}" ]; then
    record_failure "Could not extract __znh_ensure_dash_desktop_shortcut from ${TARGET_FILE}"
else
    _sc_home="$(mktemp -d /tmp/znh_sc_home.XXXXXX)"
    _sc_user="$(id -un)"
    mkdir -p "${_sc_home}/.local/share/applications" "${_sc_home}/.config" "${_sc_home}/Desktop"
    # Pin xdg-user-dir DESKTOP to the fixture Desktop (absolute path).
    printf 'XDG_DESKTOP_DIR="%s/Desktop"\n' "${_sc_home}" > "${_sc_home}/.config/user-dirs.dirs"
    _sc_master="${_sc_home}/.local/share/applications/zypper-auto-dashboard.desktop"
    _sc_copy="${_sc_home}/Desktop/Zypper Auto Dashboard.desktop"

    _sc_run() {
        # Runs the extracted generator against the fixture home; prints its
        # stdout (the sync note, if any).
        (
            # shellcheck disable=SC1090
            source "${_sc_fn_tmp}" >/dev/null 2>&1
            __znh_ensure_dash_desktop_shortcut "${_sc_user}" "${_sc_home}" 2>/dev/null
        )
    }
    _sc_marker() {
        grep -F 'X-ZypperAuto-Shortcuts-Version=' "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
    }

    # Call 1: create (fresh fixture home) -> marker present, copy synced.
    _out1="$(_sc_run)"
    if [ ! -f "${_sc_master}" ]; then
        record_failure "RUNTIME sync: first call did not create the shortcut"
    else
        [ "$(_sc_marker "${_sc_master}")" = "92" ] || record_failure "RUNTIME sync: created shortcut has no/bad version marker"
        grep -qF 'Exec=/usr/local/bin/zypper-auto-helper --dash-open' "${_sc_master}" 2>/dev/null \
            || record_failure "RUNTIME sync: created shortcut Exec is not the port-aware --dash-open launch"
        grep -qF 'read line' "${_sc_master}" 2>/dev/null \
            || record_failure "RUNTIME sync: created shortcut is missing the action commands"
    fi
    if [ ! -f "${_sc_copy}" ]; then
        record_failure "RUNTIME sync: Desktop copy was not created"
    else
        [ "$(_sc_marker "${_sc_copy}")" = "92" ] || record_failure "RUNTIME sync: Desktop copy has no/bad version marker"
    fi

    # Call 2: drift the marker to 90 (an older helper's file) -> must resync.
    sed -i 's/^X-ZypperAuto-Shortcuts-Version=.*/X-ZypperAuto-Shortcuts-Version=90/' "${_sc_master}" 2>/dev/null || true
    _out2="$(_sc_run)"
    [ "$(_sc_marker "${_sc_master}")" = "92" ] || record_failure "RUNTIME sync: a drifted (90) marker was NOT resynced to 92"
    case "${_out2}" in
        *"desktop shortcut synced to shortcuts-v92"*) ;;
        *) record_failure "RUNTIME sync: the resync did not print the sync note (output: ${_out2:-empty})" ;;
    esac

    # Call 3: up to date -> no rewrite (no sync note).
    _out3="$(_sc_run)"
    if [ -n "${_out3}" ]; then
        record_failure "RUNTIME sync: an up-to-date shortcut was rewritten anyway (output: ${_out3})"
    fi

    rm -rf -- "${_sc_home}" 2>/dev/null || true
fi
rm -f -- "${_sc_fn_tmp}" 2>/dev/null || true

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: dashboard shortcut sync (shortcuts-v marker) regression checks passed"
