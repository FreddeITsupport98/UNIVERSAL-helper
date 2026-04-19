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
Usage: ./test_scrub_ghost_cross_distro_guard_regression.sh [path/to/UNI-auto.sh]

Static regression that guards scrub-ghost distro compatibility behavior:
  - check_supported_os_or_die exists
  - no openSUSE-only hard-fail exit in that guard function
  - guard messaging is advisory/best-effort
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

assert_not_contains() {
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
    record_failure "Target file not found: ${TARGET_FILE}"
fi

source_text=""
if [ -f "${TARGET_FILE}" ]; then
    source_text="$(cat -- "${TARGET_FILE}")"
fi

assert_contains "${source_text}" "check_supported_os_or_die() {" "missing scrub-ghost distro guard function"

guard_block=""
if [ -f "${TARGET_FILE}" ]; then
    guard_block="$(
        awk '
            /^check_supported_os_or_die\(\) \{$/ { in_fn=1 }
            in_fn { print }
            in_fn && /^}$/ { exit 0 }
        ' "${TARGET_FILE}"
    )"
fi

if [ -z "${guard_block}" ]; then
    record_failure "could not extract check_supported_os_or_die function body"
else
    assert_contains "${guard_block}" "best-effort mode" "guard should advertise best-effort compatibility"
    assert_not_contains "${guard_block}" "this tool only runs on openSUSE" "guard must not hard-lock to openSUSE"
    assert_not_contains "${guard_block}" "Unsupported openSUSE variant: Leap" "guard must not hard-fail on Leap"
    assert_not_contains "${guard_block}" "exit 1" "guard must not hard-exit by distro"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: scrub-ghost cross-distro guard regression checks passed"
