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
Usage: ./test_verify_pm_profile_runtime_regression.sh [path/to/UNI-auto.sh]

Runtime regression for verify PM-profile helper behavior:
  - extracts znh_pm_is_rpm_based + znh_verify_primary_repo_host from UNI-auto.sh
  - executes helpers in an isolated sandbox (without sourcing full installer)
  - validates rpm-family detection behavior
  - validates repo-host parsing for apt/dnf/pacman fixture configs
  - validates deterministic fallback hosts when fixture config paths are missing
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

assert_equals() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [ "${actual}" != "${expected}" ]; then
        record_failure "${label} (expected='${expected}' got='${actual}')"
    fi
}

extract_block_including_start() {
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
found_start = False
found_end = False
lines = []

for line in text:
    if not in_block and line.strip() == start:
        in_block = True
        found_start = True
    if in_block and line.strip() == end:
        found_end = True
        break
    if in_block:
        lines.append(line)

if not found_start:
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

EXTRACTED_FUNCS="${TMP_ROOT}/verify-pm-profile-functions.sh"
if ! extract_block_including_start \
    "${TARGET_FILE}" \
    "znh_pm_is_rpm_based() {" \
    "# --- Function: Run Verification (used by both install and --verify modes) ---" \
    "${EXTRACTED_FUNCS}"; then
    echo "FAIL SUMMARY (1)" >&2
    echo " - Failed to extract PM profile helper block from ${TARGET_FILE}" >&2
    exit 1
fi

if ! bash -n "${EXTRACTED_FUNCS}" >/dev/null 2>&1; then
    echo "FAIL SUMMARY (1)" >&2
    echo " - Extracted helper block is not valid bash syntax" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${EXTRACTED_FUNCS}"

# Validate rpm-family detection behavior.
if ! znh_pm_is_rpm_based "zypper"; then
    record_failure "znh_pm_is_rpm_based should return success for zypper"
fi
if ! znh_pm_is_rpm_based "dnf"; then
    record_failure "znh_pm_is_rpm_based should return success for dnf"
fi
if znh_pm_is_rpm_based "apt"; then
    record_failure "znh_pm_is_rpm_based should return failure for apt"
fi
if znh_pm_is_rpm_based "pacman"; then
    record_failure "znh_pm_is_rpm_based should return failure for pacman"
fi
if znh_pm_is_rpm_based "unknown"; then
    record_failure "znh_pm_is_rpm_based should return failure for unknown manager"
fi

export SYSTEM_PKG_MANAGER="dnf"
if ! znh_pm_is_rpm_based; then
    record_failure "znh_pm_is_rpm_based should respect SYSTEM_PKG_MANAGER=dnf when no arg is provided"
fi
export SYSTEM_PKG_MANAGER="apt"
if znh_pm_is_rpm_based; then
    record_failure "znh_pm_is_rpm_based should respect SYSTEM_PKG_MANAGER=apt when no arg is provided"
fi
export SYSTEM_PKG_MANAGER=""

# Build deterministic fixture config trees for host parsing.
APT_FIXTURE_ROOT="${TMP_ROOT}/apt-fixture"
DNF_FIXTURE_ROOT="${TMP_ROOT}/dnf-fixture"
PACMAN_FIXTURE_ROOT="${TMP_ROOT}/pacman-fixture"
mkdir -p "${APT_FIXTURE_ROOT}/sources.list.d" "${DNF_FIXTURE_ROOT}/repos.d" "${DNF_FIXTURE_ROOT}/conf.d" "${PACMAN_FIXTURE_ROOT}"

cat > "${APT_FIXTURE_ROOT}/sources.list" <<'EOF'
deb https://apt.example.test/debian stable main
EOF
cat > "${DNF_FIXTURE_ROOT}/repos.d/test.repo" <<'EOF'
[test]
name=Test Repo
baseurl=https://dnf.example.test/repo/
enabled=1
gpgcheck=1
EOF
cat > "${PACMAN_FIXTURE_ROOT}/mirrorlist" <<'EOF'
Server = https://pacman.example.test/$repo/os/$arch
EOF

export VERIFY_APT_SOURCES_LIST_PATH="${APT_FIXTURE_ROOT}/sources.list"
export VERIFY_APT_SOURCES_LIST_DIR="${APT_FIXTURE_ROOT}/sources.list.d"
export VERIFY_DNF_REPOS_DIR="${DNF_FIXTURE_ROOT}/repos.d"
export VERIFY_DNF_CONFIG_DIR="${DNF_FIXTURE_ROOT}/conf.d"
export VERIFY_PACMAN_MIRRORLIST_PATH="${PACMAN_FIXTURE_ROOT}/mirrorlist"

assert_equals "download.opensuse.org" "$(znh_verify_primary_repo_host zypper)" "zypper repo host derivation mismatch"
assert_equals "apt.example.test" "$(znh_verify_primary_repo_host apt)" "apt repo host derivation mismatch"
assert_equals "dnf.example.test" "$(znh_verify_primary_repo_host dnf)" "dnf repo host derivation mismatch"
assert_equals "pacman.example.test" "$(znh_verify_primary_repo_host pacman)" "pacman repo host derivation mismatch"
assert_equals "" "$(znh_verify_primary_repo_host unknown)" "unknown manager repo host should be empty"

# Validate apt deb822-style fallback parsing.
cat > "${APT_FIXTURE_ROOT}/sources.list" <<'EOF'
# intentionally empty to force URIs fallback
EOF
cat > "${APT_FIXTURE_ROOT}/sources.list.d/deb822.sources" <<'EOF'
Types: deb
URIs: https://deb822.example.test/repository
Suites: stable
Components: main
EOF
assert_equals "deb822.example.test" "$(znh_verify_primary_repo_host apt)" "apt deb822 URIs host derivation mismatch"

# Validate deterministic fallback hosts when fixture paths are missing.
export VERIFY_APT_SOURCES_LIST_PATH="${TMP_ROOT}/missing-apt/sources.list"
export VERIFY_APT_SOURCES_LIST_DIR="${TMP_ROOT}/missing-apt/sources.list.d"
export VERIFY_DNF_REPOS_DIR="${TMP_ROOT}/missing-dnf/repos.d"
export VERIFY_DNF_CONFIG_DIR="${TMP_ROOT}/missing-dnf/conf.d"
export VERIFY_PACMAN_MIRRORLIST_PATH="${TMP_ROOT}/missing-pacman/mirrorlist"

assert_equals "deb.debian.org" "$(znh_verify_primary_repo_host apt)" "apt fallback host mismatch"
assert_equals "mirrors.fedoraproject.org" "$(znh_verify_primary_repo_host dnf)" "dnf fallback host mismatch"
assert_equals "archlinux.org" "$(znh_verify_primary_repo_host pacman)" "pacman fallback host mismatch"

print_fail_summary_and_exit
echo "PASS: verify PM profile runtime regression checks passed"
