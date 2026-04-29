#!/usr/bin/env bash
set -euo pipefail

# Static regression smoke test for the distro-upgrade detection / WebUI / CLI
# wiring added to UNI-auto.sh. Validates:
#   - Bash module helper functions exist (rolling/fixed classification, fedora /
#     ubuntu / debian / leap probes, state writer, notification helper, CLI
#     dispatcher and apply flow).
#   - The dashboard state JSON file path is exported and matches the WebUI/
#     notifier contract (/var/lib/zypper-auto/distro-upgrade.json).
#   - CLI flags for --check-distro-upgrade / --distro-upgrade / --distro-upgrade-status
#     are present in the early option allowlist AND wired into the main
#     dispatcher, and the helper text mentions them.
#   - The notification helper invokes notify-send + journald (logger) with the
#     correct topic, so the WebUI / desktop "ready to install" surface stays
#     functional.
#   - The uninstaller dry-run output and cleanup section both reference the new
#     distro-upgrade.json state file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_distro_upgrade_detect_regression.sh [path/to/UNI-auto.sh]

Static regression smoke test for distro-upgrade detection wiring:
  - bash helpers (znh_distro_release_model_classify, znh_distro_upgrade_check,
    znh_distro_upgrade_check_fedora/_ubuntu/_debian/_leap,
    znh_distro_upgrade_state_write_file, znh_distro_upgrade_send_notification,
    znh_distro_upgrade_run_apply, znh_distro_upgrade_cli_dispatch)
  - the WebUI/notifier state file path (/var/lib/zypper-auto/distro-upgrade.json)
  - CLI dispatcher entries for --check-distro-upgrade, --distro-upgrade,
    --distro-upgrade-status
  - --help text exposes the new commands
  - notify-send + journald wiring uses the "system-software-update" icon and
    the "zypper-auto-helper-distro-upgrade" logger tag
  - rolling distros (Tumbleweed/Arch/Manjaro/etc.) are classified as rolling
  - fixed distros (Fedora/Ubuntu/Debian/Leap/RHEL/Mint) are classified as fixed
  - uninstaller cleans up the new state file (and dry-run prints it)
EOF
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

# 1) Helper functions exist in the new module.
require_contains "${source_text}" "znh_distro_release_model_classify() {" \
    "Missing distro release-model classifier helper"
require_contains "${source_text}" "znh_distro_upgrade_state_write_file() {" \
    "Missing distro-upgrade state JSON writer"
require_contains "${source_text}" "znh_distro_upgrade_check_fedora() {" \
    "Missing Fedora distro-upgrade probe"
require_contains "${source_text}" "znh_distro_upgrade_check_ubuntu() {" \
    "Missing Ubuntu/Mint distro-upgrade probe"
require_contains "${source_text}" "znh_distro_upgrade_check_debian() {" \
    "Missing Debian distro-upgrade probe"
require_contains "${source_text}" "znh_distro_upgrade_check_leap() {" \
    "Missing openSUSE Leap distro-upgrade probe"
require_contains "${source_text}" "znh_distro_upgrade_check() {" \
    "Missing top-level distro-upgrade entry helper"
require_contains "${source_text}" "znh_distro_upgrade_send_notification() {" \
    "Missing distro-upgrade notification helper"
require_contains "${source_text}" "znh_distro_upgrade_status_print() {" \
    "Missing distro-upgrade status printer helper"
require_contains "${source_text}" "znh_distro_upgrade_run_apply() {" \
    "Missing distro-upgrade apply helper"
require_contains "${source_text}" "znh_distro_upgrade_cli_dispatch() {" \
    "Missing distro-upgrade CLI dispatcher helper"

# 2) Classifier covers rolling AND fixed-cycle distros.
require_contains "${source_text}" "opensuse-tumbleweed|opensuse-slowroll)" \
    "Classifier missing rolling openSUSE Tumbleweed/Slowroll case"
require_contains "${source_text}" "arch|manjaro|endeavouros|garuda|artix|cachyos|siduction|gentoo|void|nixos|chimera|kaos)" \
    "Classifier missing rolling Arch-family/etc. case"
require_contains "${source_text}" "fedora|nobara)" \
    "Classifier missing Fedora/Nobara case"
require_contains "${source_text}" "ubuntu|pop|elementary|neon|kali|zorin)" \
    "Classifier missing Ubuntu-family case"
require_contains "${source_text}" "linuxmint|lmde)" \
    "Classifier missing Linux Mint case"
require_contains "${source_text}" "debian|raspbian|devuan)" \
    "Classifier missing Debian-family case"
require_contains "${source_text}" "opensuse-leap|sles|sled)" \
    "Classifier missing openSUSE Leap/SLES case"
require_contains "${source_text}" 'ZNH_DISTRO_RELEASE_MODEL="rolling"' \
    "Classifier never assigns rolling release model"
require_contains "${source_text}" 'ZNH_DISTRO_RELEASE_MODEL="fixed"' \
    "Classifier never assigns fixed release model"

# 3) Fedora probe uses the dnf/repoquery + releasever approach.
# shellcheck disable=SC2016  # literal substring of the helper source; ${candidate} is inside single quotes by design
require_contains "${source_text}" 'repoquery --releasever="${candidate}"' \
    "Fedora probe missing repoquery --releasever wiring"
require_contains "${source_text}" "fedora-release" \
    "Fedora probe missing fedora-release package signal"

# 4) Ubuntu probe uses the do-release-upgrade -c probe.
require_contains "${source_text}" "do-release-upgrade -c" \
    "Ubuntu probe missing do-release-upgrade -c invocation"

# 5) Apply paths point to the right backends.
require_contains "${source_text}" "system-upgrade download --refresh --releasever=" \
    "Fedora apply path missing dnf system-upgrade download"
require_contains "${source_text}" "do-release-upgrade" \
    "Ubuntu apply path missing do-release-upgrade invocation"

# 6) State file path + WebUI surface.
require_contains "${source_text}" 'ZNH_DISTRO_UPGRADE_STATE_DIR="/var/lib/zypper-auto"' \
    "Missing ZNH_DISTRO_UPGRADE_STATE_DIR constant"
# shellcheck disable=SC2016  # literal substring; ${...} is part of the helper assignment expression we are matching
require_contains "${source_text}" 'ZNH_DISTRO_UPGRADE_STATE_FILE="${ZNH_DISTRO_UPGRADE_STATE_DIR}/distro-upgrade.json"' \
    "Missing ZNH_DISTRO_UPGRADE_STATE_FILE constant"
require_contains "${source_text}" '"release_model": "%s",' \
    "State JSON missing release_model field"
require_contains "${source_text}" '"distro_family": "%s",' \
    "State JSON missing distro_family field"
require_contains "${source_text}" '"current_version": "%s",' \
    "State JSON missing current_version field"
require_contains "${source_text}" '"target_version": "%s",' \
    "State JSON missing target_version field"
require_contains "${source_text}" '"status": "%s",' \
    "State JSON missing status field"

# 7) Notification + journald wiring.
# shellcheck disable=SC2016  # literal substring; ${urgency} is part of the helper invocation we are matching
require_contains "${source_text}" 'notify-send -u "${urgency}" -t 20000' \
    "Distro-upgrade notification missing notify-send invocation"
require_contains "${source_text}" '-i "system-software-update"' \
    "Distro-upgrade notification missing system-software-update icon"
require_contains "${source_text}" 'logger -t "zypper-auto-helper-distro-upgrade"' \
    "Distro-upgrade notification missing journald logger tag"

# 8) Early option allowlist exposes the new flags.
require_contains "${source_text}" "--check-distro-upgrade|--distro-upgrade|--distro-upgrade-status|--distro-upgrade-check" \
    "Option allowlist is missing the new --distro-upgrade flags"

# 9) Main CLI dispatcher routes the new flags through the helper.
# shellcheck disable=SC2016  # literal substrings of the helper dispatcher; ${1:-} / $@ are inside the matched bash code
require_contains "${source_text}" 'elif [[ "${1:-}" == "--check-distro-upgrade" || "${1:-}" == "--distro-upgrade-check" ]]; then' \
    "Main dispatcher missing --check-distro-upgrade branch"
# shellcheck disable=SC2016
require_contains "${source_text}" 'elif [[ "${1:-}" == "--distro-upgrade-status" ]]; then' \
    "Main dispatcher missing --distro-upgrade-status branch"
# shellcheck disable=SC2016
require_contains "${source_text}" 'elif [[ "${1:-}" == "--distro-upgrade" ]]; then' \
    "Main dispatcher missing --distro-upgrade branch"
require_contains "${source_text}" 'znh_distro_upgrade_cli_dispatch check' \
    "Dispatcher does not route --check-distro-upgrade through cli_dispatch helper"
require_contains "${source_text}" 'znh_distro_upgrade_cli_dispatch status' \
    "Dispatcher does not route --distro-upgrade-status through cli_dispatch helper"
# shellcheck disable=SC2016
require_contains "${source_text}" 'znh_distro_upgrade_cli_dispatch "$@"' \
    "Dispatcher does not forward --distro-upgrade subcommands to cli_dispatch helper"

# 10) Helper text mentions the new commands so users can discover them.
require_contains "${source_text}" "  --check-distro-upgrade  Check whether a major distro version upgrade is available" \
    "Help text missing --check-distro-upgrade entry"
require_contains "${source_text}" "  --distro-upgrade-status Print the current distro-upgrade detection state" \
    "Help text missing --distro-upgrade-status entry"
require_contains "${source_text}" "  --distro-upgrade [status|check|apply [--yes]]" \
    "Help text missing --distro-upgrade summary line"

# 11) Uninstaller updates: dry-run + cleanup must reference the new state file.
require_contains "${source_text}" "/var/lib/zypper-auto/distro-upgrade.json (distro-upgrade detection state for the WebUI)" \
    "Uninstaller dry-run output missing distro-upgrade.json reference"
require_contains "${source_text}" "/var/lib/zypper-auto/distro-upgrade.json \\" \
    "Uninstaller cleanup section missing distro-upgrade.json removal entry"

# 12) Dashboard API endpoint surfaces the distro-upgrade JSON to the WebUI.
require_contains "${source_text}" "/api/system/distro-upgrade" \
    "Dashboard API missing /api/system/distro-upgrade endpoint string"

# 13) Dashboard banner element wired into the main card so fixed-cycle distros
#    get a visible "ready to install" surface (rolling distros stay hidden).
require_contains "${source_text}" 'id="znh-distro-upgrade-banner"' \
    "Dashboard HTML missing znh-distro-upgrade-banner element"
require_contains "${source_text}" 'id="znh-distro-upgrade-open-btn"' \
    "Dashboard banner missing 'Open in Rocket' button"
require_contains "${source_text}" 'id="znh-distro-upgrade-copy-btn"' \
    "Dashboard banner missing 'Copy command' button"
require_contains "${source_text}" 'id="znh-distro-upgrade-refresh-btn"' \
    "Dashboard banner missing 'Re-check' button"
require_contains "${source_text}" 'id="znh-distro-upgrade-dismiss-btn"' \
    "Dashboard banner missing 'Dismiss' button"

# 14) JS helpers fetch + render the distro-upgrade state, gate visibility on
#    fixed release model + available status, and wire into the Rocket UI init.
require_contains "${source_text}" "function znhDistroUpgradeFetch(" \
    "Missing znhDistroUpgradeFetch JS helper"
require_contains "${source_text}" "function znhDistroUpgradeRender(" \
    "Missing znhDistroUpgradeRender JS helper"
require_contains "${source_text}" "function _wireDistroUpgradeBannerUI(" \
    "Missing _wireDistroUpgradeBannerUI wiring helper"
require_contains "${source_text}" "releaseModel === 'fixed' && status === 'available'" \
    "Distro-upgrade renderer not gated on release_model='fixed' AND status='available'"
require_contains "${source_text}" "if (typeof _wireDistroUpgradeBannerUI === 'function') _wireDistroUpgradeBannerUI();" \
    "_wireRocketUI does not invoke _wireDistroUpgradeBannerUI on init"

# 15) Rocket Wizard distro_upgrade mode: opt branch + family-specific renderer
#    so dashboard banner clicks land in a focused wizard flow instead of the
#    regular package-update preview.
require_contains "${source_text}" "function _ruRenderDistroUpgrade(" \
    "Missing _ruRenderDistroUpgrade wizard renderer"
require_contains "${source_text}" "opts.distro_upgrade === true || opts.distroUpgrade === true" \
    "rocketUpdateWizardOpen missing distro_upgrade opt branch"
require_contains "${source_text}" "DISTROUPGRADE" \
    "Distro-upgrade wizard missing DISTROUPGRADE confirmation phrase"
require_contains "${source_text}" "action: 'distro-upgrade'" \
    "Distro-upgrade wizard missing distro-upgrade quick-action invocation"

# 16) Quick-action allowlist: zypper-auto-helper exposes the new distro-upgrade
#    keys so the wizard's Apply via Rocket button can launch a background job.
require_contains "${source_text}" "distro-upgrade-check" \
    "Quick-action allowlist missing distro-upgrade-check entry"
require_contains "${source_text}" "--distro-upgrade apply --yes" \
    "Quick-action allowlist missing --distro-upgrade apply --yes command"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: distro-upgrade detection regression checks passed"
