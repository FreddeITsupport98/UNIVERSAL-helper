#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_TARGET_FILE="${REPO_ROOT}/UNI-auto.sh"
if [ ! -f "${DEFAULT_TARGET_FILE}" ]; then
    DEFAULT_TARGET_FILE="${REPO_ROOT}/zypper-auto.sh"
fi
TARGET_FILE="${1:-${DEFAULT_TARGET_FILE}}"

usage() {
    cat <<'EOF'
Usage: ./test_pm_runtime_helper_query_runtime_regression.sh [path/to/UNI-auto.sh]

Runtime regression for shared PM helper query contract:
  - extracts generated /usr/local/lib/zypper-auto/package-manager-runtime.sh heredoc
  - executes helper query mode in isolation
  - validates notifier-preview-command-argv is NUL-delimited argv payload
  - validates argv prefix matches detected package-manager family
EOF
}

FAILURES=()

record_failure() {
    local msg="$1"
    FAILURES+=("${msg}")
}

print_fail_summary_and_exit() {
    if [ "${#FAILURES[@]}" -gt 0 ]; then
        echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
        for f in "${FAILURES[@]}"; do
            echo " - ${f}" >&2
        done
        exit 1
    fi
}

require_token_at() {
    local index="$1"
    local expected="$2"
    local label="$3"
    local actual="${ARGV_TOKENS[${index}]-__missing__}"
    if [ "${actual}" != "${expected}" ]; then
        record_failure "${label} (expected token[${index}]=${expected}, got ${actual})"
    fi
}

extract_heredoc_block() {
    local source_file="$1"
    local start_marker="$2"
    local end_marker="$3"
    local output_file="$4"

    if ! python3 - "${source_file}" "${start_marker}" "${end_marker}" "${output_file}" <<'PY'
import sys
from pathlib import Path

source, start, end, out = sys.argv[1:5]
text = Path(source).read_text(encoding="utf-8", errors="replace").splitlines()

in_block = False
found_end = False
lines = []

for line in text:
    if not in_block and line.strip() == start:
        in_block = True
        continue
    if in_block and line.strip() == end:
        found_end = True
        break
    if in_block:
        lines.append(line)

if not in_block:
    raise SystemExit(2)
if not found_end:
    raise SystemExit(3)

Path(out).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
    then
        return 1
    fi
    return 0
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

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}" 2>/dev/null || true' EXIT

HELPER_SCRIPT="${TMP_ROOT}/package-manager-runtime.sh"
if ! extract_heredoc_block "${TARGET_FILE}" "write_atomic \"\${PM_RUNTIME_HELPER_PATH}\" << 'EOF'" "EOF" "${HELPER_SCRIPT}"; then
    echo "FAIL SUMMARY (1)" >&2
    echo " - Failed to extract shared PM helper heredoc from ${TARGET_FILE}" >&2
    exit 1
fi
chmod +x "${HELPER_SCRIPT}"

# Query package manager (text contract)
detected_pm="$("${HELPER_SCRIPT}" --query package-manager 2>/dev/null | tr -d '\r\n' || true)"
case "${detected_pm}" in
    zypper|apt|dnf|pacman) ;;
    *)
        record_failure "Unexpected package-manager query result: '${detected_pm}'"
        ;;
esac

# Query notifier preview argv (NUL-delimited contract)
ARGV_RAW_FILE="${TMP_ROOT}/notifier-preview-argv.bin"
set +e
"${HELPER_SCRIPT}" --query notifier-preview-command-argv >"${ARGV_RAW_FILE}"
query_rc=$?
set -e
if [ "${query_rc}" -ne 0 ]; then
    record_failure "notifier-preview-command-argv query failed (rc=${query_rc})"
fi

ARGV_TOKENS_FILE="${TMP_ROOT}/notifier-preview-argv.tokens"
set +e
python3 - "${ARGV_RAW_FILE}" >"${ARGV_TOKENS_FILE}" <<'PY'
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()
if not raw:
    raise SystemExit(2)
if b"\0" not in raw:
    raise SystemExit(3)

tokens = [chunk.decode("utf-8", errors="replace") for chunk in raw.split(b"\0") if chunk]
if not tokens:
    raise SystemExit(4)

for token in tokens:
    print(token)
PY
parse_rc=$?
set -e
if [ "${parse_rc}" -ne 0 ]; then
    record_failure "notifier-preview-command-argv payload is not valid NUL-delimited argv bytes (python rc=${parse_rc})"
fi

declare -a ARGV_TOKENS=()
if [ -f "${ARGV_TOKENS_FILE}" ]; then
    mapfile -t ARGV_TOKENS < "${ARGV_TOKENS_FILE}"
fi
if [ "${#ARGV_TOKENS[@]}" -eq 0 ]; then
    record_failure "Parsed notifier-preview argv token list is empty"
fi

require_token_at 0 "pkexec" "notifier-preview argv must start with pkexec"
case "${detected_pm}" in
    zypper)
        require_token_at 1 "zypper" "zypper notifier-preview argv command mismatch"
        require_token_at 2 "--non-interactive" "zypper notifier-preview argv flag mismatch"
        require_token_at 3 "dup" "zypper notifier-preview argv subcommand mismatch"
        require_token_at 4 "--dry-run" "zypper notifier-preview argv dry-run flag mismatch"
        ;;
    apt)
        require_token_at 1 "env" "apt notifier-preview argv env wrapper mismatch"
        require_token_at 2 "DEBIAN_FRONTEND=noninteractive" "apt notifier-preview argv env var mismatch"
        require_token_at 3 "apt-get" "apt notifier-preview argv command mismatch"
        require_token_at 4 "-s" "apt notifier-preview argv simulation flag mismatch"
        require_token_at 5 "dist-upgrade" "apt notifier-preview argv subcommand mismatch"
        ;;
    dnf)
        require_token_at 1 "dnf" "dnf notifier-preview argv command mismatch"
        require_token_at 2 "-q" "dnf notifier-preview argv quiet flag mismatch"
        require_token_at 3 "check-update" "dnf notifier-preview argv subcommand mismatch"
        ;;
    pacman)
        require_token_at 1 "pacman" "pacman notifier-preview argv command mismatch"
        require_token_at 2 "-Qu" "pacman notifier-preview argv query flag mismatch"
        ;;
esac

# Additional sanity checks for query mode behavior
manual_update="$("${HELPER_SCRIPT}" --query manual-update-command 2>/dev/null | tr -d '\r' || true)"
manual_refresh="$("${HELPER_SCRIPT}" --query manual-refresh-command 2>/dev/null | tr -d '\r' || true)"
if [ -z "${manual_update}" ]; then
    record_failure "manual-update-command query returned empty output"
fi
if [ -z "${manual_refresh}" ]; then
    record_failure "manual-refresh-command query returned empty output"
fi
if [[ "${manual_update}" != sudo* ]]; then
    record_failure "manual-update-command should start with 'sudo' (got: ${manual_update})"
fi
if [[ "${manual_refresh}" != sudo* ]]; then
    record_failure "manual-refresh-command should start with 'sudo' (got: ${manual_refresh})"
fi

set +e
"${HELPER_SCRIPT}" --query does-not-exist >/dev/null 2>&1
unknown_rc=$?
set -e
if [ "${unknown_rc}" -eq 0 ]; then
    record_failure "unknown query key should return non-zero exit"
fi

print_fail_summary_and_exit
echo "PASS: PM runtime helper query-contract runtime regression checks passed"
