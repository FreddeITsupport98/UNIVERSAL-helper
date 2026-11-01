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
Usage: ./test_dashboard_port_config_regression.sh [path/to/UNI-auto.sh]

Regression guard for the v91 dashboard port autopilot (DASHBOARD_PORT):
  - DASHBOARD_PORT config key with FULL wiring (default + /etc/zypper-auto.conf
    template + dashboard schema row + load_config validator with auto-fallback
    + missing-key doc + Settings drawer row)
  - preferred-port resolver helper (env DASHBOARD_PORT -> config peek;
    auto/invalid -> 8765, manual 1024-65535 echoed) — includes RUNTIME checks
    with fixture env values + fixture config files (sandboxed via the
    ZNH_DASHBOARD_CONF_FILE override)
  - conflict detection on every server-start path (non-root --dash-open fast
    path, root run_dash_open_only, --dash-bg background): busy preferred port
    -> occupant identified (ss) -> move to a free port -> desktop notification
  - the localhost Settings API CORS gate accepts ANY localhost port (manual
    pins never lock the drawer out) with a drift guard that the old fixed
    8765-8790 range gate is gone; remote origins stay rejected
  - the WebUI "Open Live URL" button builds its URL from location.port
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

require_count_at_least() {
    local needle="$1"
    local min_count="$2"
    local label="$3"
    local n
    n="$(grep -cF -- "${needle}" "${TARGET_FILE}" 2>/dev/null || true)"
    if [ "${n:-0}" -lt "${min_count}" ] 2>/dev/null; then
        record_failure "${label} (found ${n:-0} occurrences, need at least ${min_count})"
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

# --- 1) The three v91 helpers ---
require_contains "${source_text}" '__znh_dashboard_port_conf_preferred() {' "Missing the v91 preferred-port resolver helper"
require_contains "${source_text}" '__znh_port_occupant_desc() {' "Missing the v91 port-occupant detector helper"
require_contains "${source_text}" '__znh_dashboard_port_changed_notify() {' "Missing the v91 port-change notification helper"
require_contains "${source_text}" 'ZNH_DASHBOARD_CONF_FILE' "Missing the v91 sandboxed conf-file test override hook"
require_contains "${source_text}" 'ZNH_DASHBOARD_PORT_MODE="manual"' "Missing the v91 manual-mode marker in the resolver"

# --- 2) All three server-start paths honor the config + detect + move + notify ---
require_count_at_least 'port="${ZNH_DASHBOARD_PORT_PREFERRED}"' 2 "Both foreground port blocks (fast path + root run_dash_open_only) must read the resolver globals (NOT command substitution — the mode flag would be lost)"
require_count_at_least '__znh_dashboard_port_changed_notify' 4 "The notifier must be wired into all three start paths (helper def + 3 call sites)"
require_contains "${source_text}" 'moving the live dashboard to port' "Missing the v91 manual-port conflict warning (configured port busy -> move)"
require_contains "${source_text}" 'the live dashboard uses free port ${port_pick} instead' "Missing the v91 auto-mode conflict info line"
require_contains "${source_text}" 'no free port found in the 8765-8790 dashboard range' "Missing the v91 all-ports-busy warning"
require_contains "${source_text}" 'port_occ="$(__znh_port_occupant_desc "${port}")"' "Missing the v91 occupant detection in a foreground port block"
require_contains "${source_text}" 'background dashboard port ${bg_port} is already in use by' "Missing the v91 background-service conflict detection/info line"
require_contains "${source_text}" 'ss -lptnH' "Missing the v91 ss-based occupant probe"
require_contains "${source_text}" 'Port ${_pn_old} is already in use by ${_pn_occ}. The live dashboard moved to:' "Missing the v91 port-change notification body"

# --- 3) DASHBOARD_PORT config wiring (auto | 1024-65535) ---
require_contains "${source_text}" 'DASHBOARD_PORT="auto"' "Missing the DASHBOARD_PORT default/template value (auto)"
require_contains "${source_text}" '"DASHBOARD_PORT": {"type": "string", "max_len": 5, "presets": ["auto"], "default": "auto"}' "Missing the DASHBOARD_PORT dashboard schema row"
require_contains "${source_text}" 'Invalid DASHBOARD_PORT=' "Missing the DASHBOARD_PORT validator (invalid -> auto with a config warning)"
require_contains "${source_text}" '_mark_missing_key "DASHBOARD_PORT"' "Missing the DASHBOARD_PORT missing-key registration"
require_contains "${source_text}" '- DASHBOARD_PORT: live dashboard HTTP port' "Missing the DASHBOARD_PORT missing-key feature description"
require_contains "${source_text}" "key: 'DASHBOARD_PORT'" "Missing the DASHBOARD_PORT Settings drawer row"
require_contains "${source_text}" 'a fixed 1024-65535 port to pin it' "Missing the DASHBOARD_PORT config documentation (defaults comment + missing-key doc)"

# --- 4) CORS: any LOCALHOST port is allowed; remote origins stay rejected ---
require_contains "${source_text}" 'host not in ("127.0.0.1", "localhost", "::1")' "Missing the v91 localhost-any-port CORS host gate"
require_not_contains "${source_text}" '8765 <= int(port) <= 8790' "The old fixed 8765-8790 CORS port gate must be gone (it locked out manually pinned DASHBOARD_PORT values)"
require_contains "${source_text}" 'if p.scheme != "http":' "The CORS scheme gate must stay (only http origins)"

# --- 5) WebUI Open Live URL button follows the actually-served port ---
require_contains "${source_text}" "(location.port || '8765')" "Missing the v91 live-port Open Live URL button fix"

# --- 6) Help text documents the behavior ---
require_contains "${source_text}" 'v91: the live server honors DASHBOARD_PORT' "Missing the v91 --dash-open help note"

# --- 7) Bash syntax sanity of the target file ---
if ! bash -n "${TARGET_FILE}" >/dev/null 2>&1; then
    record_failure "Target file fails bash -n syntax check: ${TARGET_FILE}"
fi

# --- 8) RUNTIME: the preferred-port resolver, sandboxed (env + fixture conf) ---
_port_fn_tmp="$(mktemp /tmp/znh_dash_port_fn.XXXXXX)"
sed -n '/^__znh_dashboard_port_conf_preferred() {/,/^}/p' "${TARGET_FILE}" > "${_port_fn_tmp}" 2>/dev/null || true
if [ ! -s "${_port_fn_tmp}" ]; then
    record_failure "Could not extract __znh_dashboard_port_conf_preferred from ${TARGET_FILE}"
else
    _rt_dir="$(mktemp -d /tmp/znh_dash_port_rt.XXXXXX)"
    printf '%s\n' 'DASHBOARD_PORT="8876"' > "${_rt_dir}/conf-manual"
    printf '%s\n' 'DASHBOARD_PORT="auto"' > "${_rt_dir}/conf-auto"
    printf '%s\n' 'DASHBOARD_PORT="70000"' > "${_rt_dir}/conf-invalid"
    printf '%s\n' 'DASHBOARD_PORT=" 9001 "' > "${_rt_dir}/conf-spaced"
    : > "${_rt_dir}/conf-empty"

    _port_resolve() {
        # Usage: _port_resolve <env-value-or-"-"> <conf-file>
        # Prints "<resolved port>" then "mode=<auto|manual>" (reads the two
        # resolver globals — the callers' real contract).
        (
            if [ "$1" = "-" ]; then
                unset DASHBOARD_PORT || true
            else
                DASHBOARD_PORT="$1"
                export DASHBOARD_PORT
            fi
            ZNH_DASHBOARD_CONF_FILE="$2"
            export ZNH_DASHBOARD_CONF_FILE
            # shellcheck disable=SC1090
            source "${_port_fn_tmp}" >/dev/null 2>&1
            __znh_dashboard_port_conf_preferred
            printf '%s\n' "${ZNH_DASHBOARD_PORT_PREFERRED:-unset}"
            printf 'mode=%s\n' "${ZNH_DASHBOARD_PORT_MODE:-unset}"
        )
    }

    _rt_check() {
        # Usage: _rt_check <label> <expected port> <expected mode> <env> <conf>
        local label="$1" want_port="$2" want_mode="$3" env_val="$4" conf_file="$5" out got_port got_mode
        out="$(_port_resolve "${env_val}" "${conf_file}")"
        got_port="$(printf '%s\n' "${out}" | head -n 1)"
        got_mode="$(printf '%s\n' "${out}" | tail -n 1)"
        if [ "${got_port}" != "${want_port}" ] || [ "${got_mode}" != "mode=${want_mode}" ]; then
            record_failure "RUNTIME resolver: ${label} -> got port=${got_port} ${got_mode}, want port=${want_port} mode=${want_mode}"
        fi
    }

    _rt_check "env auto + empty conf"            "8765" "auto"   "auto"    "${_rt_dir}/conf-empty"
    _rt_check "env unset + conf manual 8876"     "8876" "manual" "-"       "${_rt_dir}/conf-manual"
    _rt_check "env unset + conf auto"            "8765" "auto"   "-"       "${_rt_dir}/conf-auto"
    _rt_check "env unset + conf invalid 70000"   "8765" "auto"   "-"       "${_rt_dir}/conf-invalid"
    _rt_check "env unset + conf spaced 9001"     "9001" "manual" "-"       "${_rt_dir}/conf-spaced"
    _rt_check "env 8876 wins over conf auto"     "8876" "manual" "8876"    "${_rt_dir}/conf-auto"
    _rt_check "env invalid 900 wins over conf"   "8765" "auto"   "900"     "${_rt_dir}/conf-manual"
    _rt_check "env unset + missing conf file"    "8765" "auto"   "-"       "${_rt_dir}/conf-missing"

    rm -rf -- "${_rt_dir}" 2>/dev/null || true
fi
rm -f -- "${_port_fn_tmp}" 2>/dev/null || true

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: dashboard port config (DASHBOARD_PORT) regression checks passed"
