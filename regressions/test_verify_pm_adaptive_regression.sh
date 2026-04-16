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
Usage: ./test_verify_pm_adaptive_regression.sh [path/to/UNI-auto.sh]

Static regression smoke test for package-manager-aware verify/auto-healing wiring:
  - verify path derives package-manager profile + primary repo DNS host
  - package-manager cache/repo/orphan/dependency checks are backend-aware
  - reboot-required check uses shared runtime helper
  - backend-native deep keyring repair exists for apt/dnf/pacman
  - zypper-specific deep repairs remain gated/skipped where appropriate
  - rpmdb checks are gated to rpm-backed package managers
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

require_contains "${source_text}" "znh_pm_is_rpm_based() {" "Missing RPM-backed package-manager helper"
require_contains "${source_text}" "znh_verify_primary_repo_host() {" "Missing verify repository host helper"
require_contains "${source_text}" "VERIFY_APT_SOURCES_LIST_PATH" "Missing apt source path override for runtime testing"
require_contains "${source_text}" "VERIFY_DNF_REPOS_DIR" "Missing dnf repo path override for runtime testing"
require_contains "${source_text}" "VERIFY_PACMAN_MIRRORLIST_PATH" "Missing pacman mirrorlist path override for runtime testing"
require_contains "${source_text}" "VERIFY_PM_IS_RPM_BASED=0" "verify path missing RPM-backed profile flag"
require_contains "${source_text}" "VERIFY_REPO_DNS_TARGET=\"\$(znh_verify_primary_repo_host \"\${VERIFY_PM}\")\"" "verify path missing primary repo DNS target derivation"
require_contains "${source_text}" "Verification package-manager profile: manager=\${VERIFY_PM}, rpm_based=\${VERIFY_PM_IS_RPM_BASED}, repo_dns_target=\${VERIFY_REPO_DNS_TARGET:-unknown}" "verify package-manager profile debug log missing"

require_contains "${source_text}" 'execute_guarded "Run zypper clean --all" zypper --non-interactive clean --all' "Disk cleanup check missing zypper cache-clean mapping"
require_contains "${source_text}" 'execute_guarded "Run apt-get clean" env DEBIAN_FRONTEND=noninteractive apt-get clean' "Disk cleanup check missing apt cache-clean mapping"
require_contains "${source_text}" 'execute_guarded "Run dnf clean all" dnf -y clean all' "Disk cleanup check missing dnf cache-clean mapping"
require_contains "${source_text}" 'execute_guarded "Run pacman cache clean" pacman -Scc --noconfirm' "Disk cleanup check missing pacman cache-clean mapping"

require_contains "${source_text}" "Checking DNS resolution for repository host (\${VERIFY_REPO_DNS_TARGET:-unknown})" "Repo DNS verify check still appears hardcoded"
require_contains "${source_text}" "getent hosts \"\${VERIFY_REPO_DNS_TARGET}\"" "Repo DNS verify check is not using derived target"

require_contains "${source_text}" "Checking repository configuration/readability for \${VERIFY_PM}" "Repository readability check missing PM-aware dispatch"
require_contains "${source_text}" "apt repository configuration is readable (apt-cache policy)" "Repository readability check missing apt branch"
require_contains "${source_text}" "dnf repositories are readable (repolist)" "Repository readability check missing dnf branch"
require_contains "${source_text}" "pacman repository configuration is readable (/etc/pacman.conf)" "Repository readability check missing pacman branch"

require_contains "${source_text}" 'cron_pm_expr="zypper"' "Cron conflict check missing default package-manager expression"
require_contains "${source_text}" 'apt) cron_pm_expr="apt-get|aptitude|apt" ;;' "Cron conflict check missing apt mapping"
require_contains "${source_text}" 'dnf) cron_pm_expr="dnf|yum" ;;' "Cron conflict check missing dnf mapping"
require_contains "${source_text}" 'pacman) cron_pm_expr="pacman" ;;' "Cron conflict check missing pacman mapping"

require_contains "${source_text}" 'zypper --no-refresh --non-interactive packages --orphaned' "Orphaned package check missing zypper branch"
require_contains "${source_text}" 'apt-get -s autoremove' "Orphaned package check missing apt branch"
require_contains "${source_text}" 'dnf -q repoquery --extras' "Orphaned package check missing dnf branch"
require_contains "${source_text}" 'pacman -Qdtq' "Orphaned package check missing pacman branch"

require_contains "${source_text}" "if check_reboot_required; then" "Reboot-required check is not using shared helper"
require_contains "${source_text}" 'execute_guarded "Clean apt caches" env DEBIAN_FRONTEND=noninteractive apt-get clean' "Proactive cleanup check missing apt cache branch"
require_contains "${source_text}" 'execute_guarded "Clean dnf caches" dnf -y clean all' "Proactive cleanup check missing dnf cache branch"
require_contains "${source_text}" 'execute_guarded "Clean pacman caches" pacman -Scc --noconfirm' "Proactive cleanup check missing pacman cache branch"

require_contains "${source_text}" "zypper lock cleanup check skipped for package manager '\${VERIFY_PM}'" "Check 37 missing non-zypper skip path"
require_contains "${source_text}" "RPM database repair check skipped for non-RPM package manager (\${VERIFY_PM})" "Check 38 missing non-RPM skip path"
require_contains "${source_text}" "RPM final sanity check skipped for non-RPM package manager (\${VERIFY_PM})" "Check 47 missing non-RPM skip path"

require_contains "${source_text}" 'zypper --non-interactive verify --details' "Dependency check missing zypper verify path"
require_contains "${source_text}" 'apt-get -o Debug::NoLocking=1 -qq check >/dev/null 2>&1' "Dependency check missing apt path"
require_contains "${source_text}" 'dnf -q check >/dev/null 2>&1' "Dependency check missing dnf path"
require_contains "${source_text}" 'pacman -Dk >/dev/null 2>&1' "Dependency check missing pacman path"

require_contains "${source_text}" "Refresh failure looks GPG/signature-related. Attempting backend-native keyring remediation..." "Check 42 missing unified backend-native keyring remediation path"
require_contains "${source_text}" "verify_pm_attempt_keyring_repair" "Check 42 missing helperized keyring repair dispatch"
require_contains "${source_text}" "verify_pm_output_looks_signature_error" "Check 42 missing helperized signature error detection"
require_contains "${source_text}" 'execute_optional "Reinstall apt keyring packages"' "Check 42 missing apt keyring reinstall action"
require_contains "${source_text}" 'execute_optional "Import RPM GPG key' "Check 42 missing dnf RPM-key import action"
require_contains "${source_text}" 'execute_optional "Populate pacman keyring"' "Check 42 missing pacman keyring populate action"
require_contains "${source_text}" "Final stale-zypper-lock pass skipped for package manager '\${VERIFY_PM}'" "Check 43 missing non-zypper skip path"
require_contains "${source_text}" "Kernel purge auto-repair is currently zypper-only; skipping on package manager '\${VERIFY_PM}'" "Check 44 missing non-zypper skip path"
require_contains "${source_text}" "Repository metadata appears unhealthy (\${metadata_stale_reason:-unknown reason})" "Check 49 missing unified metadata unhealthy message"
require_contains "${source_text}" 'execute_optional "Clean package-manager metadata cache" verify_pm_cache_cleanup' "Check 49 missing unified metadata cache cleanup helper call"
require_contains "${source_text}" 'execute_guarded "Refresh repositories (forced metadata rebuild)" verify_pm_refresh force' "Check 49 missing unified forced refresh helper call"
require_contains "${source_text}" "No cache-garbage indicators detected for package manager '\${VERIFY_PM}'" "Check 50 missing unified non-problem skip path"
require_contains "${source_text}" 'execute_guarded "Clean package-manager caches" verify_pm_cache_cleanup' "Check 50 missing unified package-manager cache cleanup call"
require_contains "${source_text}" "Zypper Turbo tuning is zypper-specific; skipping for '\${VERIFY_PM}'" "Check 51 missing non-zypper skip path"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: verify package-manager adaptive regression checks passed"
