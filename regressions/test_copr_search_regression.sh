#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes are intentional throughout this
# file: assertions grep the target for LITERAL unexpanded ${...} shell source strings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_copr_search_regression.sh [path/to/UNI-auto.sh]

Regression guard for the Copr search + multi-select enable module (--copr-search):
  - official Copr API v3 search endpoint (project/search, verified live)
  - title (owner/project full name) + description listing per project
  - opi-style interactive numbered multi-select TUI (numbers/ranges/all/none)
  - idempotent enable via dnf/dnf5 copr enable (already-enabled skipped)
  - copr plugin auto-install (dnf5-plugins / dnf-plugins-core)
  - 'dnf copr-search <query>' wrapper hook (generator heredoc + fish function)
  - CLI wiring (early allowlist + dispatcher + help text) + uninstaller note
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
        record_failure "${label} (unexpectedly present: ${needle})"
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

# --- 1) Module presence + CLI wiring ---
require_contains "${source_text}" 'run_copr_search_only() {' "Missing run_copr_search_only function"
require_contains "${source_text}" 'elif [[ "${1:-}" == "--copr-search" ]]; then' "Missing --copr-search dispatcher branch"
require_contains "${source_text}" 'run_copr_search_only "$@"' "Missing run_copr_search_only dispatch call with the query args"
require_contains "${source_text}" '--setup-SF|--media-repos|--setup-media-repos|--copr-search|--uninstall-zypper' "Missing --copr-search in the early option allowlist"
require_contains "${source_text}" '--copr-search <query>   Search Fedora Copr (official API v3) for <query>, list every project with its' "Missing --copr-search help text"

# --- 2) Official API v3 endpoint + fetch (verified: project/search, NOT coprs/search) ---
require_contains "${source_text}" 'https://copr.fedorainfracloud.org/api_3/project/search?query=${_cs_q}' "Missing official Copr API v3 project/search fetch"
require_not_contains "${source_text}" 'api_3/coprs/search?query' "Wrong endpoint: api_3/coprs/search (404) still referenced"
require_contains "${source_text}" '__znh_check_service_reachable "https://copr.fedorainfracloud.org" "Copr (copr.fedorainfracloud.org)"' "Missing Copr hub reachability pre-check"
require_contains "${source_text}" 'urllib.parse.quote(sys.argv[1])' "Missing query URL-encoding via python3 urllib"

# --- 3) Title (full_name) + description listing ---
require_contains "${source_text}" 'full_name = str(it.get("full_name") or "").strip()' "Missing full_name (title) extraction from the API response"
require_contains "${source_text}" 'desc = " ".join(str(it.get("description") or "").split())' "Missing description extraction from the API response"
require_contains "${source_text}" 'sys.stdout.write(full_name + "\t" + first_line + "\n")' "Missing TSV full_name+description output line"
require_contains "${source_text}" 'mapfile -t _cs_lines <<<"${_cs_tsv}"' "Missing mapfile parse of the Copr result TSV"

# --- 3b) Colorized standardized listing (number/title/description + markers + blank lines) ---
require_contains "${source_text}" 'local _cs_cnum="" _cs_ctitle="" _cs_cdesc="" _cs_cok="" _cs_creset=""' "Missing the copr-search color variable block"
require_contains "${source_text}" 'if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then' "Missing the TTY + NO_COLOR color gate (https://no-color.org)"
require_contains "${source_text}" "_cs_cnum=\$'\\033[96m'" "Missing the bright-cyan entry-number color"
require_contains "${source_text}" "_cs_ctitle=\$'\\033[1m'" "Missing the bold title color"
require_contains "${source_text}" "_cs_cdesc=\$'\\033[33m'" "Missing the yellow description color (one distinct, consistent color)"
require_contains "${source_text}" "_cs_cok=\$'\\033[92m'" "Missing the bright-green [ALREADY ENABLED] color"
require_contains "${source_text}" "_cs_cgrp=\$'\\033[95m'" "Missing the bright-magenta [group] color for @-namespace projects"
require_contains "${source_text}" "_cs_cerr=\$'\\033[91m'" "Missing the bright-red invalid-selection color"
require_contains "${source_text}" "_cs_creset=\$'\\033[0m'" "Missing the color reset"

# --- 3c) Per-entry markers ([group] / [ALREADY ENABLED]) via the helper ---
require_contains "${source_text}" '__znh_copr_entry_markers() {' "Missing the per-entry marker helper"
require_contains "${source_text}" '@*) _m="  ${_cs_cgrp}[group]${_cs_creset}" ;;' "Missing the @-prefix [group] marker branch in the helper"
require_contains "${source_text}" '_m="${_m}  ${_cs_cok}[ALREADY ENABLED]${_cs_creset}"' "Missing the [ALREADY ENABLED] marker in the helper"

# --- 3d) Listing printf formats (colored + plain, with markers) ---
require_contains "${source_text}" "printf '%s%3d%s) %s%s%s%s\n'" "Missing the colorized number+title+markers printf (entry numbers colored, titles bold)"
require_contains "${source_text}" "printf '  %3d) %s%s\n'" "Missing the plain number+title+markers printf"
require_contains "${source_text}" '%s→ %3d%s) %s%s%s%s\n' "Missing the instant selection-feedback printf format (→ N) title + markers)"
require_contains "${source_text}" '→ selected all %d project(s)' "Missing the all-instant selection feedback line"
require_contains "${source_text}" '%s - %s%s%s%s\n' "Missing the colorized confirmation-preview entry printf format (with markers)"
require_contains "${source_text}" '# Colored interactive listing: stdout only (no log tee; ANSI' "Missing the stdout-only rationale (ANSI escapes must never enter LOG_FILE)"
require_not_contains "${source_text}" '"${_cs_cdesc}" "${_cs_descs[${_cs_i}]}" "${_cs_creset}" | tee -a' "Colored description printf must not tee to LOG_FILE (ANSI escapes in log)"
require_not_contains "${source_text}" '%s%3d%s) %s%s%s\n' "Old 6-arg colorized number+title printf format still present (superseded by the +markers format)"
require_not_contains "${source_text}" '%s%3d%s) %s%s%s  %s[ALREADY ENABLED]%s\n' "Old inline [ALREADY ENABLED] printf format still present (superseded by the marker helper)"

# --- 3e) Pager for large interactive listings ---
require_contains "${source_text}" 'ZNH_COPR_SEARCH_PAGE_THRESHOLD:-25' "Missing the pager threshold default (25)"
require_contains "${source_text}" 'command -v less >/dev/null 2>&1' "Missing the less availability check for the pager"
require_contains "${source_text}" 'less -R -X "${_cs_listing_tmp}"' "Missing the less -R pager invocation"
require_contains "${source_text}" 'press q to continue to the selection' "Missing the pager trailing hint line"
require_contains "${source_text}" 'Copr listing shown via pager (less -R)' "Missing the pager usage log line"
require_not_contains "${source_text}" '>>"${_cs_listing_tmp}" | tee -a' "Paged listing buffer must not tee to LOG_FILE (ANSI escapes in log)"

# --- 4) Idempotency: already-enabled detection (local copr list) + skip ---
require_contains "${source_text}" '"${_cs_dnf}" copr list 2>/dev/null || true' "Missing local copr list probe for already-enabled repos"
require_contains "${source_text}" '[ALREADY ENABLED]' "Missing [ALREADY ENABLED] marker in the listing"
require_contains "${source_text}" 'is already enabled; skipping.' "Missing already-enabled skip message"

# --- 5) opi-style multi-select TUI ---
require_contains "${source_text}" 'Select Copr repositories to enable (multi-select):' "Missing multi-select selection prompt"
require_contains "${source_text}" 'or a range, e.g.  3-7' "Missing range (3-7) selection hint"
require_contains "${source_text}" 'or  all  /  none' "Missing all/none selection hints"
require_contains "${source_text}" 'press Enter on an empty line to cancel' "Missing Enter-to-cancel hint"
require_contains "${source_text}" 'Selection cancelled; nothing was changed.' "Missing cancel message"
require_contains "${source_text}" 'Invalid selection' "Missing invalid-selection error with usage hint"
require_contains "${source_text}" 'Proceed? [y/N]: ' "Missing y/N confirmation before enabling"
require_contains "${source_text}" 'The following ${#_cs_sel[@]} Copr repositories will be enabled:' "Missing confirmation preview list"

# --- 6) Enable via dnf/dnf5 copr enable (idempotent) + plugin ensure ---
require_contains "${source_text}" '"${_cs_dnf}" -y copr enable "${_cs_names[${_cs_i}]}"' "Missing dnf/dnf5 copr enable invocation"
require_contains "${source_text}" 'if command -v dnf5 >/dev/null 2>&1; then
        _cs_dnf="dnf5"' "Missing dnf5-default detection in the copr-search module"
require_contains "${source_text}" '_cs_copr_pkg="dnf5-plugins"' "Missing dnf5-plugins plugin ensure (dnf5)"
require_contains "${source_text}" '_cs_copr_pkg="dnf-plugins-core"' "Missing dnf-plugins-core plugin ensure (dnf4)"
require_contains "${source_text}" 'Failed to enable Copr repository ${_cs_names[${_cs_i}]}' "Missing enable-failure error with the manual resolve hint"

# --- 7) Non-interactive listing-only mode ---
require_contains "${source_text}" 'Non-interactive mode: listing only.' "Missing non-interactive listing-only mode"
require_contains "${source_text}" '(or: dnf copr-search ${_cs_query})' "Missing dnf copr-search hint in non-interactive mode"

# --- 8) Optional package install afterwards ---
require_contains "${source_text}" "Install '\${_cs_query}' from the enabled Copr repositories now? [y/N]: " "Missing optional package-install prompt after enabling"

# --- 9) Fedora-family gate (clean exit elsewhere) ---
require_contains "${source_text}" '--copr-search currently targets Fedora-family systems only. Exiting cleanly; nothing was changed.' "Missing clean exit for non-Fedora families"

# --- 10) dnf wrapper hook: 'dnf copr-search <query>' routes to the helper ---
require_contains "${source_text}" 'if [ "${WRAPPER_PM}" = "dnf" ] && [ "${1:-}" = "copr-search" ]; then' "Missing dnf copr-search interception in the wrapper generator"
require_contains "${source_text}" 'exec sudo zypper-auto-helper --copr-search "$@"' "Missing wrapper exec of the copr-search helper under sudo"
require_contains "${source_text}" 'case install in upgrade up remove rm distro-sync reinstall downgrade copr-search' "Missing copr-search case in the fish dnf wrapper function"
require_contains "${source_text}" "dnf itself has no copr-search" "Missing fish wrapper comment explaining the copr-search routing"

# --- 11) Uninstaller note about kept Copr repositories ---
require_contains "${source_text}" 'Copr repositories enabled via --copr-search / dnf copr-search are kept' "Missing uninstaller note about kept Copr repositories"
require_contains "${source_text}" 'sudo dnf copr remove <owner>/<project>' "Missing uninstaller manual copr-remove hint"

# --- 12) Bash syntax sanity of the target file ---
if ! bash -n "${TARGET_FILE}" >/dev/null 2>&1; then
    record_failure "Target file fails bash -n syntax check: ${TARGET_FILE}"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: copr-search TUI + dnf wrapper hook regression checks passed"
