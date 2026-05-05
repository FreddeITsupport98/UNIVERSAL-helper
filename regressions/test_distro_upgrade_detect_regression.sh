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
require_contains "${source_text}" "releaseModel === 'fixed' && (status === 'available'" \
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

# 17) Distro-upgrade FINISH path: bash helper, dispatcher branch, and quick-action
#    entry so Fedora users get a one-click "Reboot now to finish upgrade" path
#    after the staged download completes.
require_contains "${source_text}" "znh_distro_upgrade_run_finish() {" \
    "Missing distro-upgrade finish helper (znh_distro_upgrade_run_finish)"
require_contains "${source_text}" "finish|reboot|--finish|--reboot)" \
    "Dispatcher missing finish/reboot subcommand routing"
require_contains "${source_text}" "znh_distro_upgrade_run_finish \"\${fin_yes}\"" \
    "Dispatcher does not forward --distro-upgrade finish to znh_distro_upgrade_run_finish"
require_contains "${source_text}" "system-upgrade reboot" \
    "Distro-upgrade finish helper missing dnf system-upgrade reboot invocation"
require_contains "${source_text}" "\"distro-upgrade-reboot\":" \
    "Quick-action allowlist missing distro-upgrade-reboot entry"
require_contains "${source_text}" "--distro-upgrade\", \"finish\", \"--yes\"" \
    "Quick-action distro-upgrade-reboot missing --distro-upgrade finish --yes argv"
require_contains "${source_text}" 'REBOOTUPGRADE' \
    "Distro-upgrade reboot quick-action missing REBOOTUPGRADE confirmation phrase"

# 18) WebUI progress + reboot wiring: the Rocket Wizard now keeps the overlay
#    open after starting the apply quick-action, streams progress through the
#    same big banner used by the regular Rocket update flow, and renders a
#    "Reboot now to finish upgrade" CTA on completion.
require_contains "${source_text}" "function _ruDistroUpgradeTrackJob(" \
    "Missing _ruDistroUpgradeTrackJob progress tracker"
require_contains "${source_text}" "function _ruDistroUpgradeRenderRunning(" \
    "Missing _ruDistroUpgradeRenderRunning progress banner renderer"
require_contains "${source_text}" "function _ruDistroUpgradeRenderDone(" \
    "Missing _ruDistroUpgradeRenderDone result renderer"
require_contains "${source_text}" "function _ruDistroUpgradeFinishingCommand(" \
    "Missing _ruDistroUpgradeFinishingCommand helper for family-specific reboot command"
require_contains "${source_text}" "_znhApiJobStreamStart('quick-action'" \
    "Distro-upgrade tracker not using SSE quick-action stream for live progress"
require_contains "${source_text}" "action: 'distro-upgrade-reboot'" \
    "Distro-upgrade reboot button does not invoke distro-upgrade-reboot quick-action"
require_contains "${source_text}" "id=\"ru-distro-reboot\"" \
    "Distro-upgrade done view missing Reboot now CTA button"

# 19) New Ubuntu codename-to-version helper and cycle-math helper exist.
require_contains "${source_text}" "__znh_ubuntu_codename_to_version() {" \
    "Missing __znh_ubuntu_codename_to_version codename→version map helper"
require_contains "${source_text}" "__znh_ubuntu_compute_next_version() {" \
    "Missing __znh_ubuntu_compute_next_version release-cycle math helper"

# 20) Ubuntu codename table covers key releases (noble=24.04, plucky=25.04).
require_contains "${source_text}" "noble)    printf '24.04'" \
    "Ubuntu codename table missing 'noble' → 24.04 mapping"
require_contains "${source_text}" "plucky)   printf '25.04'" \
    "Ubuntu codename table missing 'plucky' → 25.04 mapping"
require_contains "${source_text}" "regal)    printf '26.04'" \
    "Ubuntu codename table missing 'regal' → 26.04 mapping"

# 21) Ubuntu check_ubuntu() uses 4 extraction methods: direct grep, codename parse,
#    meta-release feed (curl), and cycle-math fallback.
require_contains "${source_text}" "grep -oE '[0-9]{2}\\.[0-9]{2}" \
    "check_ubuntu Method 1 (direct YY.MM grep) missing"
require_contains "${source_text}" "changelogs.ubuntu.com/meta-release" \
    "check_ubuntu Method 3 (Ubuntu meta-release API) missing"
require_contains "${source_text}" "__znh_ubuntu_compute_next_version \"\${current_ver}\"" \
    "check_ubuntu Method 4 (cycle-math fallback) missing"

# 22) Debian probe now detects next stable codename and sets ZNH_DISTRO_UPGRADE_TARGET.
require_contains "${source_text}" "bookworm|bookworm/sid) next_version=\"13\"; next_codename=\"trixie\"" \
    "check_debian missing bookworm→13 (trixie) mapping"
require_contains "${source_text}" "trixie|trixie/sid)     next_version=\"14\"; next_codename=\"forky\"" \
    "check_debian missing trixie→14 (forky) mapping"

# 23) Leap probe computes next minor version (major.minor+1) and sets target.
require_contains "${source_text}" "candidate_minor=\$((10#\${minor} + 1))" \
    "check_leap missing candidate_minor arithmetic for next version"
require_contains "${source_text}" 'ZNH_DISTRO_UPGRADE_TARGET="${next_ver:-}"' \
    "check_leap not setting ZNH_DISTRO_UPGRADE_TARGET"

# 24) znh_distro_upgrade_check() passes detected target to state_write_file for
#    debian/leap/rhel so the JSON has a real version number.
require_contains "${source_text}" 'znh_distro_upgrade_state_write_file "manual" "${ZNH_DISTRO_UPGRADE_TARGET}"' \
    "debian/leap/rhel check() not passing target to state_write_file"
require_contains "${source_text}" '_rhel_next_major=$((10#${_rhel_major} + 1))' \
    "RHEL next-major-version computation missing"

# 25) Ubuntu release notes URL sanitized to bare YY.MM before building wiki URL.
require_contains "${source_text}" "grep -oE '[0-9]{2}\\.[0-9]{2}'" \
    "Ubuntu release_notes_url missing YY.MM sanitization grep"
require_contains "${source_text}" "wiki.ubuntu.com/\${_ubuntu_ver_clean}/ReleaseNotes" \
    "Ubuntu release_notes_url missing sanitized URL construction"

# 26) JS _ruRenderDistroUpgrade handles manual-status families with target version shown.
require_contains "${source_text}" "isManual  = status === 'manual'" \
    "_ruRenderDistroUpgrade JS not checking isManual status"
require_contains "${source_text}" "\\uD83D\\uDD27" \
    "_ruRenderDistroUpgrade manual view missing wrench emoji for manual upgrades"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: distro-upgrade detection regression checks passed"
