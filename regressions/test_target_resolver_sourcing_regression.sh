#!/usr/bin/env bash
# RUNNER_NEEDS_TARGET=0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"

usage() {
    cat <<'EOF'
Usage: ./test_target_resolver_sourcing_regression.sh

Regression guard to prevent target-resolution drift:
  - every regressions/test_*.sh must source regressions/target_resolver.sh
EOF
}

FAILURES=()

record_failure() {
    local msg="$1"
    FAILURES+=("${msg}")
}

required_source_line=". \"\${SCRIPT_DIR}/target_resolver.sh\""

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ ! -d "${SCRIPT_DIR}" ]; then
    echo "FAIL SUMMARY (1)" >&2
    echo " - Regression directory not found: ${SCRIPT_DIR}" >&2
    exit 1
fi

shopt -s nullglob
shell_tests=( "${SCRIPT_DIR}"/test_*.sh )
shopt -u nullglob

if [ "${#shell_tests[@]}" -eq 0 ]; then
    record_failure "No shell regression files found under ${SCRIPT_DIR}"
fi

for test_path in "${shell_tests[@]}"; do
    test_name="$(basename "${test_path}")"
    if ! grep -Fq -- "${required_source_line}" "${test_path}"; then
        record_failure "${test_name}: missing required source line '${required_source_line}'"
    fi
done

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: all shell regressions source target_resolver.sh"
