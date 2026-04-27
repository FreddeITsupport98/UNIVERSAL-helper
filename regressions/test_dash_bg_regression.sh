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
Usage: ./test_dash_bg_regression.sh [path/to/UNI-auto.sh]

Static regression for the always-on background dashboard mode:
  - --dash-bg start|stop|status flag is parsed and whitelisted.
  - --dash-bg-enable / --dash-bg-disable are wired to systemctl --user.
  - The user-level systemd unit writer __znh_write_dash_bg_user_unit emits
    ~/.config/systemd/user/zypper-auto-dashboard-bg.service with low-impact
    resource limits (Nice=19, IOSchedulingClass=idle, MemoryHigh, MemoryMax).
  - Background mode uses *-bg pid files distinct from --dash-open and exposes
    the BG cadence env knobs (ZNH_DASHBOARD_BG_INTERVAL_SECONDS,
    ZNH_DASHBOARD_BG_MAX_IDLE_SECONDS).
  - WEBUI_BACKGROUND_DASH_ENABLED + WEBUI_BACKGROUND_DASH_PROFILE config keys
    are present in the dashboard schema, the embedded config template, the
    validator block, and the JS Settings drawer field array.
  - The uninstaller cleanly disables and removes the BG user service so
    'sudo zypper-auto-helper --uninstall' takes the BG service down too.
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

# CLI flag is whitelisted and parsed.
assert_contains "${source_text}" '--dash-bg|--dash-bg-enable|--dash-bg-disable' "--dash-bg* flags missing from CLI whitelist"
assert_contains "${source_text}" '== "--dash-bg" ]]' "missing --dash-bg branch in arg parser"
assert_contains "${source_text}" '== "--dash-bg-enable" ]]' "missing --dash-bg-enable branch"
assert_contains "${source_text}" '== "--dash-bg-disable" ]]' "missing --dash-bg-disable branch"

# BG pid file naming distinct from --dash-open.
assert_contains "${source_text}" "dashboard-http-bg.pid" "BG mode missing distinct dashboard-http-bg.pid"
assert_contains "${source_text}" "dashboard-sync-bg.pid" "BG mode missing distinct dashboard-sync-bg.pid"
assert_contains "${source_text}" "dashboard-perf-bg.pid" "BG mode missing distinct dashboard-perf-bg.pid"

# BG cadence env knobs distinct from interactive cadence.
assert_contains "${source_text}" "ZNH_DASHBOARD_BG_INTERVAL_SECONDS" "missing ZNH_DASHBOARD_BG_INTERVAL_SECONDS env knob"
assert_contains "${source_text}" "ZNH_DASHBOARD_BG_MAX_IDLE_SECONDS" "missing ZNH_DASHBOARD_BG_MAX_IDLE_SECONDS env knob"

# User systemd unit writer + content.
assert_contains "${source_text}" "__znh_write_dash_bg_user_unit" "missing __znh_write_dash_bg_user_unit helper"
assert_contains "${source_text}" "zypper-auto-dashboard-bg.service" "missing zypper-auto-dashboard-bg.service unit name"
assert_contains "${source_text}" "Nice=19" "BG service unit missing Nice=19 low-impact limit"
assert_contains "${source_text}" "IOSchedulingClass=idle" "BG service unit missing IOSchedulingClass=idle"
assert_contains "${source_text}" "MemoryHigh=120M" "BG service unit missing MemoryHigh limit"
assert_contains "${source_text}" "MemoryMax=200M" "BG service unit missing MemoryMax limit"

# --dash-bg-enable wires systemctl --user enable + linger.
assert_contains "${source_text}" "systemctl --user daemon-reload" "--dash-bg-enable missing systemctl --user daemon-reload"
assert_contains "${source_text}" "systemctl --user enable --now zypper-auto-dashboard-bg.service" "--dash-bg-enable missing systemctl --user enable --now"
assert_contains "${source_text}" "loginctl enable-linger" "--dash-bg-enable should attempt loginctl enable-linger for boot persistence"

# --dash-bg-disable wires systemctl --user disable + cleanup.
assert_contains "${source_text}" "systemctl --user disable --now zypper-auto-dashboard-bg.service" "--dash-bg-disable missing systemctl --user disable --now"

# Schema + config template + validators wire the new keys.
assert_contains "${source_text}" '"WEBUI_BACKGROUND_DASH_ENABLED": {"type": "bool", "default": "false"}' "schema missing WEBUI_BACKGROUND_DASH_ENABLED entry"
assert_contains "${source_text}" '"WEBUI_BACKGROUND_DASH_PROFILE": {"type": "enum", "allowed": ["powersaving","balanced","performance"], "default": "powersaving"}' "schema missing WEBUI_BACKGROUND_DASH_PROFILE entry"
assert_contains "${source_text}" "WEBUI_BACKGROUND_DASH_ENABLED=false" "config template missing WEBUI_BACKGROUND_DASH_ENABLED default"
assert_contains "${source_text}" 'WEBUI_BACKGROUND_DASH_PROFILE="powersaving"' "config template missing WEBUI_BACKGROUND_DASH_PROFILE default"
assert_contains "${source_text}" "validate_bool_flag WEBUI_BACKGROUND_DASH_ENABLED false" "validator missing for WEBUI_BACKGROUND_DASH_ENABLED"
assert_contains "${source_text}" 'validate_allowed_set WEBUI_BACKGROUND_DASH_PROFILE powersaving "powersaving,balanced,performance"' "validator missing for WEBUI_BACKGROUND_DASH_PROFILE"

# Settings drawer field array surfaces the new keys.
assert_contains "${source_text}" "key: 'WEBUI_BACKGROUND_DASH_ENABLED'" "SETTINGS_FIELDS missing WEBUI_BACKGROUND_DASH_ENABLED entry"
assert_contains "${source_text}" "key: 'WEBUI_BACKGROUND_DASH_PROFILE'" "SETTINGS_FIELDS missing WEBUI_BACKGROUND_DASH_PROFILE entry"

# Uninstaller takes the BG service down and removes its unit file.
assert_contains "${source_text}" "systemctl --user disable --now zypper-auto-dashboard-bg.service || true" "uninstaller missing BG service disable in user-timer/service section"
assert_contains "${source_text}" '"$SUDO_USER_HOME/.config/systemd/user/zypper-auto-dashboard-bg.service"' "uninstaller missing BG service unit file in rm -f list"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: --dash-bg always-on background dashboard regression checks passed"
