#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_cleanup_guard_and_config_warning_descriptions_regression.sh [path/to/UNI-auto.sh]

Static regression guard for:
  - legacy pycache cleanup skip behavior when ~/.local/bin is missing
  - missing-key warning descriptions for key notifier/debug config options
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

require_contains "${source_text}" "legacy_user_bin_dir=\"\${SUDO_USER_HOME}/.local/bin\"" "Missing legacy user bin directory variable for pycache cleanup guard"
require_contains "${source_text}" "if [ -d \"\${legacy_user_bin_dir}\" ]; then" "Missing directory-existence guard before legacy pycache cleanup"
require_contains "${source_text}" "Legacy user bin directory not present (skipping pycache cleanup): \${legacy_user_bin_dir}" "Missing non-error skip log for absent legacy user bin directory"

require_contains "${source_text}" "LOCK_REMINDER_ENABLED)" "Missing missing-key description case for LOCK_REMINDER_ENABLED"
require_contains "${source_text}" "NO_UPDATES_REMINDER_REPEAT_ENABLED)" "Missing missing-key description case for NO_UPDATES_REMINDER_REPEAT_ENABLED"
require_contains "${source_text}" "UPDATES_READY_REMINDER_REPEAT_ENABLED)" "Missing missing-key description case for UPDATES_READY_REMINDER_REPEAT_ENABLED"
require_contains "${source_text}" "LOG_FOLDER_OPENER)" "Missing missing-key description case for LOG_FOLDER_OPENER"

require_contains "${source_text}" "desktop lock reminder notifications are shown while a package-manager lock is active" "Missing LOCK_REMINDER_ENABLED description text"
require_contains "${source_text}" "identical \\\"No updates found\\\" notifications can repeat while the system remains up to date" "Missing NO_UPDATES_REMINDER_REPEAT_ENABLED description text"
require_contains "${source_text}" "identical \\\"Updates ready\\\" notifications can repeat while the same update set remains pending" "Missing UPDATES_READY_REMINDER_REPEAT_ENABLED description text"
require_contains "${source_text}" "optional preferred folder opener command (e.g. dolphin/nautilus) used before xdg-open fallback in debug/log views" "Missing LOG_FOLDER_OPENER description text"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: cleanup guard and config warning description regression checks passed"
