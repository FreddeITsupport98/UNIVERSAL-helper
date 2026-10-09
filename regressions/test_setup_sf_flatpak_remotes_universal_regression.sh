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
Usage: ./test_setup_sf_flatpak_remotes_universal_regression.sh [path/to/UNI-auto.sh]

Static regression guard for the universal Flatpak remote setup in --setup-SF:
  - ZNH_FLATPAK_REMOTE_SPECS table with all six remotes
    (flathub, flathub-beta, fedora OCI, fedora-testing OCI #testing tag,
     appcenter, gnome-nightly) and the canonical remote-add URLs
  - per-remote reachability pre-check with extra accepted HTTP codes
    (OCI registries answer 401 to unauthenticated probes)
  - system-wide scope as root / --user scope unprivileged
  - resulting `flatpak remotes` listing for both scopes
  - table-driven setup-sf-last-report.txt report block
  - --setup-SF help text, WebUI quick-action explain text
  - uninstaller informational note about intentionally kept remotes
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

# --- 1) Universal remote table: all six remotes with canonical URLs ---
require_contains "${source_text}" 'ZNH_FLATPAK_REMOTE_SPECS=(' "Missing universal Flatpak remote spec table"
require_contains "${source_text}" '"flathub|https://dl.flathub.org/repo/flathub.flatpakrepo|https://dl.flathub.org/repo/flathub.flatpakrepo|"' "Missing flathub row in universal remote table"
require_contains "${source_text}" '"flathub-beta|https://dl.flathub.org/beta-repo/flathub-beta.flatpakrepo|https://dl.flathub.org/beta-repo/flathub-beta.flatpakrepo|"' "Missing flathub-beta row (canonical dl.flathub.org beta-repo URL) in universal remote table"
require_contains "${source_text}" '"fedora|oci+https://registry.fedoraproject.org|https://registry.fedoraproject.org/v2/|401"' "Missing fedora OCI remote row with 401 extra accepted code"
require_contains "${source_text}" '"fedora-testing|oci+https://registry.fedoraproject.org#testing|https://registry.fedoraproject.org/v2/|401"' "Missing fedora-testing OCI remote row (#testing tag, 401 extra accepted code)"
require_contains "${source_text}" '"appcenter|https://flatpak.elementary.io/repo.flatpakrepo|https://flatpak.elementary.io/repo.flatpakrepo|"' "Missing appcenter row in universal remote table"
require_contains "${source_text}" '"gnome-nightly|https://nightly.gnome.org/gnome-nightly.flatpakrepo|https://nightly.gnome.org/gnome-nightly.flatpakrepo|"' "Missing gnome-nightly row in universal remote table"

# --- 2) Reachability helper accepts extra HTTP codes (OCI 401) ---
require_contains "${source_text}" 'extra_ok_codes="${4:-}"' "Missing optional 4th extra_ok_codes argument in __znh_check_service_reachable"
require_contains "${source_text}" 'for _extra_code in ${extra_ok_codes}; do' "Missing extra accepted-code loop in __znh_check_service_reachable"
require_contains "${source_text}" '(HTTP ${http_code} accepted as OK for this service type)' "Missing accepted-as-OK log line for extra HTTP codes"

# --- 3) Table-driven loop in run_setup_sf_only ---
require_contains "${source_text}" 'for _spec in "${ZNH_FLATPAK_REMOTE_SPECS[@]}"; do' "Missing table-driven remote loop over ZNH_FLATPAK_REMOTE_SPECS"
require_contains "${source_text}" "IFS='|' read -r _rname _rurl _rcheck _rextra <<<\"\${_spec}\"" "Missing spec row splitter in the remote loop"
require_contains "${source_text}" 'flatpak remote-add --if-not-exists ${_fp_scope[@]+"${_fp_scope[@]}"} "${_rname}" "${_rurl}"' "Missing remote-add invocation with scope-aware flags and spec URL"

# --- 4) System-wide vs --user scope selection ---
require_contains "${source_text}" 'local -a _fp_scope=()' "Missing _fp_scope array declaration"
require_contains "${source_text}" '_fp_scope=(--user)' "Missing --user scope fallback for unprivileged runs"
require_contains "${source_text}" 'Running unprivileged: adding Flatpak remotes with --user scope.' "Missing unprivileged --user scope log line"
require_contains "${source_text}" 'Running as root: adding Flatpak remotes system-wide (shared by all users).' "Missing root system-wide scope log line"

# --- 5) Per-remote reachability pre-check wiring ---
require_contains "${source_text}" '! __znh_check_service_reachable "${_rcheck}" "${_rname} remote" 10 "${_rextra}"; then' "Missing per-remote reachability pre-check with extra codes passthrough"

# --- 6) Legacy Flathub gating preserved for Discover-removal/Bazaar steps ---
require_contains "${source_text}" 'if [ "${_rname}" = "flathub" ]; then' "Missing flathub-specific gating branch in the remote loop"
require_contains "${source_text}" 'flathub_reachable=1' "Missing flathub_reachable assignment in the remote loop"
require_contains "${source_text}" 'flathub_ok=1' "Missing flathub_ok assignment in the remote loop"

# --- 7) Resulting remote listing (both scopes) ---
require_contains "${source_text}" 'flatpak remotes 2>/dev/null | tee -a "${LOG_FILE}" || true' "Missing system-scope flatpak remotes listing"
require_contains "${source_text}" 'flatpak remotes --user 2>/dev/null | tee -a "${LOG_FILE}" || true' "Missing user-scope flatpak remotes listing"

# --- 8) Table-driven setup-sf-last-report.txt block ---
require_contains "${source_text}" 'while read -r _rr_name _rr_state; do' "Missing table-driven report loop over per-remote results"
require_contains "${source_text}" "done <<<\"\${_fp_results}\"" "Missing _fp_results feed into the report loop"

# --- 9) Help text + WebUI quick-action explain text ---
require_contains "${source_text}" 'Install/configure Snapd and Flatpak (packages + universal Flatpak remotes:' "Missing universal remotes mention in --setup-SF help text"
require_contains "${source_text}" 'adds the universal Flatpak remotes (Flathub, Flathub Beta, Fedora OCI stable/testing, AppCenter, GNOME Nightly; system-wide when run as root, --user scope otherwise)' "Missing universal remotes mention in the WebUI setup-SF quick-action explain text"

# --- 10) Uninstaller informational note about intentionally kept remotes ---
require_contains "${source_text}" 'Flatpak remotes configured by --setup-SF (Flathub, Flathub Beta, Fedora' "Missing uninstaller note about kept Flatpak remotes"
require_contains "${source_text}" 'flatpak remote-delete <name>' "Missing uninstaller manual remote-delete hint"

# --- 11) Stale drift guards: legacy hardcoded paths must be gone ---
require_not_contains "${source_text}" 'https://flathub.org/beta-repo/flathub-beta.flatpakrepo' "Legacy flathub-beta URL (flathub.org host) still present; canonical dl.flathub.org URL expected"
require_not_contains "${source_text}" 'flathub_beta_ok' "Legacy flathub_beta_ok variable still present (superseded by table-driven _fp_results)"
require_not_contains "${source_text}" 'appcenter_ok' "Legacy appcenter_ok variable still present (superseded by table-driven _fp_results)"

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

echo "PASS: setup-SF universal Flatpak remotes regression checks passed"
