#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_pm_runtime_helper_missing_runtime_regression.sh [path/to/UNI-auto.sh]

Runtime regression for missing shared package-manager helper behavior:
  - extracts generated runtime consumers from UNI-auto.sh
  - rewires helper path to a guaranteed-missing file in a temp sandbox
  - asserts graceful behavior for:
      * zypper-with-ps wrapper (clear fail-fast guidance)
      * downloader (error status write, non-crashing exit)
      * install helper (clear fail-fast guidance)
      * view-changes inner script (warning + safe preview fallback)
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

require_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if ! grep -Fq -- "${needle}" <<< "${haystack}"; then
        record_failure "${label} (missing: ${needle})"
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

WRAPPER_SCRIPT="${TMP_ROOT}/zypper-with-ps"
DOWNLOADER_SCRIPT="${TMP_ROOT}/zypper-download-with-progress"
INSTALL_SCRIPT="${TMP_ROOT}/zypper-run-install"
VIEW_INNER_SCRIPT="${TMP_ROOT}/zypper-view-changes-inner.sh"

if ! extract_heredoc_block "${TARGET_FILE}" "write_atomic \"\$ZYPPER_WRAPPER_PATH\" << 'EOF'" "EOF" "${WRAPPER_SCRIPT}"; then
    record_failure "Failed to extract zypper-with-ps heredoc from ${TARGET_FILE}"
    print_fail_summary_and_exit
fi
if ! extract_heredoc_block "${TARGET_FILE}" "write_atomic \"\$DOWNLOADER_SCRIPT\" << 'DLSCRIPT'" "DLSCRIPT" "${DOWNLOADER_SCRIPT}"; then
    record_failure "Failed to extract downloader heredoc from ${TARGET_FILE}"
    print_fail_summary_and_exit
fi
if ! extract_heredoc_block "${TARGET_FILE}" "write_atomic \"\${INSTALL_SCRIPT_PATH}\" << 'EOF'" "EOF" "${INSTALL_SCRIPT}"; then
    record_failure "Failed to extract install-helper heredoc from ${TARGET_FILE}"
    print_fail_summary_and_exit
fi
if ! extract_heredoc_block "${TARGET_FILE}" "cat > \"\$TMP_SCRIPT\" << 'INNEREOF'" "INNEREOF" "${VIEW_INNER_SCRIPT}"; then
    record_failure "Failed to extract view-changes inner heredoc from ${TARGET_FILE}"
    print_fail_summary_and_exit
fi

chmod +x "${WRAPPER_SCRIPT}" "${DOWNLOADER_SCRIPT}" "${INSTALL_SCRIPT}" "${VIEW_INNER_SCRIPT}"

MISSING_HELPER="${TMP_ROOT}/missing/package-manager-runtime.sh"
DOWNLOADER_LOG_DIR="${TMP_ROOT}/downloader-log"
mkdir -p "${DOWNLOADER_LOG_DIR}"

for script_file in "${WRAPPER_SCRIPT}" "${DOWNLOADER_SCRIPT}" "${INSTALL_SCRIPT}" "${VIEW_INNER_SCRIPT}"; do
    if ! python3 - "${script_file}" "${MISSING_HELPER}" "${DOWNLOADER_LOG_DIR}" <<'PY'
import sys
from pathlib import Path

script_path, missing_helper, downloader_log_dir = sys.argv[1:4]
text = Path(script_path).read_text(encoding="utf-8", errors="replace")
text = text.replace("/usr/local/lib/zypper-auto/package-manager-runtime.sh", missing_helper)

if script_path.endswith("zypper-download-with-progress"):
    text = text.replace('LOG_DIR="/var/log/zypper-auto"', f'LOG_DIR="{downloader_log_dir}"', 1)

Path(script_path).write_text(text, encoding="utf-8")
PY
    then
        record_failure "Failed to rewire helper path for ${script_file}"
    fi
done

print_fail_summary_and_exit

# 1) zypper-with-ps wrapper should fail fast with clear guidance.
WRAPPER_OUT="${TMP_ROOT}/wrapper.out"
set +e
HOME="${TMP_ROOT}/home-wrapper" "${WRAPPER_SCRIPT}" >"${WRAPPER_OUT}" 2>&1
wrapper_rc=$?
set -e
if [ "${wrapper_rc}" -eq 0 ]; then
    record_failure "zypper-with-ps wrapper should fail when shared helper is missing"
fi
wrapper_txt="$(cat -- "${WRAPPER_OUT}" 2>/dev/null || true)"
require_contains "${wrapper_txt}" "shared package-manager runtime helper missing" "wrapper missing-helper message not shown"
require_contains "${wrapper_txt}" "Please re-run the installer: sudo zypper-auto-helper install" "wrapper reinstall guidance not shown"

# 2) downloader should not crash; it should mark status as error:repo and exit cleanly.
DOWNLOADER_OUT="${TMP_ROOT}/downloader.out"
set +e
HOME="${TMP_ROOT}/home-downloader" "${DOWNLOADER_SCRIPT}" >"${DOWNLOADER_OUT}" 2>&1
downloader_rc=$?
set -e
if [ "${downloader_rc}" -ne 0 ]; then
    record_failure "downloader should exit 0 on missing helper (graceful skip), got rc=${downloader_rc}"
fi
downloader_status_file="${DOWNLOADER_LOG_DIR}/download-status.txt"
if [ ! -f "${downloader_status_file}" ]; then
    record_failure "downloader did not write status file on missing helper (${downloader_status_file})"
else
    downloader_status="$(cat -- "${downloader_status_file}" 2>/dev/null || true)"
    require_contains "${downloader_status}" "error:repo" "downloader missing-helper path did not publish error:repo status"
fi

# 3) install helper should fail fast with clear user guidance.
INSTALL_OUT="${TMP_ROOT}/install.out"
mkdir -p "${TMP_ROOT}/home-install"
set +e
HOME="${TMP_ROOT}/home-install" "${INSTALL_SCRIPT}" --selftest >"${INSTALL_OUT}" 2>&1
install_rc=$?
set -e
if [ "${install_rc}" -eq 0 ]; then
    record_failure "install helper should fail when shared helper is missing"
fi
install_txt="$(cat -- "${INSTALL_OUT}" 2>/dev/null || true)"
require_contains "${install_txt}" "Shared package-manager helper is missing" "install helper missing-helper warning not shown"
require_contains "${install_txt}" "Please re-run the installer: sudo zypper-auto-helper install" "install helper reinstall guidance not shown"

# 4) view-changes inner script should warn and continue safely.
VIEW_OUT="${TMP_ROOT}/view-inner.out"
mkdir -p "${TMP_ROOT}/home-view"
set +e
printf '\n' | HOME="${TMP_ROOT}/home-view" bash "${VIEW_INNER_SCRIPT}" >"${VIEW_OUT}" 2>&1
view_rc=$?
set -e
if [ "${view_rc}" -ne 0 ]; then
    record_failure "view-changes inner script should complete safely when helper is missing (rc=${view_rc})"
fi
view_txt="$(cat -- "${VIEW_OUT}" 2>/dev/null || true)"
require_contains "${view_txt}" "Shared package-manager helper missing" "view-changes missing-helper warning not shown"
require_contains "${view_txt}" "Could not fetch update details." "view-changes fallback message not shown"

print_fail_summary_and_exit
echo "PASS: PM runtime helper missing-behavior runtime regression checks passed"
