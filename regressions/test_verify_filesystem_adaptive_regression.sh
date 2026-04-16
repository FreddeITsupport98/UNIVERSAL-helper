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
Usage: ./test_verify_filesystem_adaptive_regression.sh [path/to/UNI-auto.sh]

Static regression smoke test for filesystem-adaptive verify/auto-healing:
  - verify path defines reusable root-fs + snapper-support helpers
  - snapper/btrfs checks are gated by detected root filesystem
  - snapper timer auto-heal is skipped on non-btrfs or missing root config
  - safety-snapshot path skips on non-btrfs or missing snapper root config
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

require_contains "${source_text}" "znh_root_filesystem_type() {" "Missing root filesystem helper"
require_contains "${source_text}" "znh_is_btrfs_root_filesystem() {" "Missing btrfs root helper"
require_contains "${source_text}" "znh_snapper_root_verification_supported() {" "Missing snapper root support helper"

require_contains "${source_text}" "VERIFY_ROOT_FSTYPE=\"\$(znh_root_filesystem_type)\"" "verify path not using shared root filesystem helper"
require_contains "${source_text}" "VERIFY_BTRFS_ROOT=0" "verify path missing btrfs root flag"
require_contains "${source_text}" "VERIFY_SNAPPER_ROOT_SUPPORTED=0" "verify path missing snapper support flag"
require_contains "${source_text}" "if znh_snapper_root_verification_supported; then" "verify path missing snapper support detection"

require_contains "${source_text}" "Snapper root config check skipped (root fstype=\${VERIFY_ROOT_FSTYPE:-unknown}, non-btrfs system)" "snapper root check is not gated for non-btrfs systems"
require_contains "${source_text}" "Snapper timer checks skipped on non-btrfs root filesystem (\${VERIFY_ROOT_FSTYPE:-unknown})" "snapper timer check is not gated for non-btrfs systems"
require_contains "${source_text}" "Snapper timer checks skipped (snapper root config unavailable at /etc/snapper/configs/root)" "snapper timer check is not gated for missing root config"

require_contains "${source_text}" "Safety snapshot skipped: root filesystem is \${root_fstype} (snapper safety snapshots are btrfs-specific)" "safety snapshot path missing non-btrfs guard"
require_contains "${source_text}" "Safety snapshot skipped: snapper root config is not available at /etc/snapper/configs/root" "safety snapshot path missing snapper root-config guard"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: filesystem-adaptive verify regression checks passed"
