#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes are intentional throughout this
# file: assertions grep the target for LITERAL unexpanded ${...} shell source strings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_media_repos_universal_regression.sh [path/to/UNI-auto.sh]

Regression guard for the multimedia & codec repository setup module (--media-repos):
  - distro detection via /etc/os-release ID + ID_LIKE (fedora/arch families,
    clean exit otherwise) — includes a RUNTIME check with fixture os-release files
  - idempotent read-only state probe (.repo files / rpm -q / pacman -Q)
  - Fedora path order: RPM Fusion free+nonfree -> Terra (terra-release, then
    terra-release-multimedia when published) -> opt-in Terra Mesa override ->
    multimedia group -> ffmpeg-free swap -> codec refresh
  - Mesa override strictly confirm-gated (prompt / --mesa-override only)
  - dnf5-default detection, --dry-run offline-friendly mode
  - Arch path (full-codec set from official repos)
  - WebUI tile/badge/quick-action/status-data wiring + uninstaller note
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

require_line_number() {
    # Asserts that a needle exists in the target file and prints its first
    # matching line number (for ordering assertions). Records a failure when
    # the needle is missing.
    local needle="$1"
    local label="$2"
    local n
    n="$(grep -nF -- "${needle}" "${TARGET_FILE}" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    if [ -z "${n}" ]; then
        record_failure "${label} (missing: ${needle})"
        printf '%s\n' "0"
    else
        printf '%s\n' "${n}"
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

# --- 1) Module presence ---
require_contains "${source_text}" 'run_media_repos_only() {' "Missing run_media_repos_only function"
require_contains "${source_text}" 'znh_media_repos_detect_family() {' "Missing znh_media_repos_detect_family detection helper"
require_contains "${source_text}" 'znh_media_repos_state_probe() {' "Missing znh_media_repos_state_probe idempotency probe"
require_contains "${source_text}" '__znh_media_repos_run_or_dry() {' "Missing dry-run-aware command runner"
require_contains "${source_text}" 'ZNH_OS_RELEASE_FILE="${ZNH_OS_RELEASE_FILE:-/etc/os-release}"' "Missing ZNH_OS_RELEASE_FILE override default"

# --- 2) Detection branches (ID + ID_LIKE per spec) ---
require_contains "${source_text}" 'fedora|nobara)' "Missing ID=fedora/nobara detection branch"
require_contains "${source_text}" '        arch)' "Missing ID=arch detection branch"
require_contains "${source_text}" '        opensuse*|sles|sled)' "Missing ID=openSUSE detection branch (suse family)"
require_contains "${source_text}" 'debian|raspbian|devuan|ubuntu|linuxmint|lmde|pop|elementary|neon|kali|zorin)' "Missing ID=debian-family detection branch"
require_contains "${source_text}" '        *fedora*)' "Missing ID_LIKE contains-fedora detection branch"
require_contains "${source_text}" '        *arch*)' "Missing ID_LIKE contains-arch detection branch"
require_contains "${source_text}" '        *suse*)' "Missing ID_LIKE contains-suse detection branch"
require_contains "${source_text}" '        *debian*|*ubuntu*)' "Missing ID_LIKE contains-debian/ubuntu detection branch"
require_contains "${source_text}" 'Exiting cleanly; nothing was changed.' "Missing clean-exit message for unsupported distros"
require_contains "${source_text}" 'Nobara detected: Nobara already ships its own pre-configured multimedia repositories' "Missing dedicated Nobara note"

# --- 3) Idempotency probe: existing .repo files / package checks BEFORE adding ---
require_contains "${source_text}" 'rpm -q rpmfusion-free-release >/dev/null 2>&1 || [ -f /etc/yum.repos.d/rpmfusion-free.repo ]' "Missing rpmfusion-free probe (.repo fallback) before adding"
require_contains "${source_text}" 'rpm -q rpmfusion-nonfree-release >/dev/null 2>&1 || [ -f /etc/yum.repos.d/rpmfusion-nonfree.repo ]' "Missing rpmfusion-nonfree probe (.repo fallback) before adding"
require_contains "${source_text}" 'rpm -q terra-release >/dev/null 2>&1 || [ -f /etc/yum.repos.d/terra.repo ]' "Missing terra-release probe (.repo fallback) before adding"
require_contains "${source_text}" 'rpm -q terra-release-multimedia >/dev/null 2>&1' "Missing terra-release-multimedia probe"
require_contains "${source_text}" 'rpm -q terra-release-mesa >/dev/null 2>&1' "Missing terra-release-mesa probe"
require_contains "${source_text}" 'rpm -q ffmpeg >/dev/null 2>&1' "Missing full-ffmpeg probe"
require_contains "${source_text}" 'rpm -q ffmpeg-free >/dev/null 2>&1' "Missing ffmpeg-free probe"
require_contains "${source_text}" 'rpm -q gstreamer1-plugins-bad-freeworld >/dev/null 2>&1' "Missing freeworld GStreamer probe"
require_contains "${source_text}" 'pacman -Q ffmpeg gstreamer gst-plugins-base gst-plugins-good' "Missing Arch codec-set probe (pacman -Q)"

# --- 4) Fedora path: step ORDER (line-number assertions) ---
_ln_rpmfusion="$(require_line_number 'https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${_mr_fedora_ver}.noarch.rpm' 'Missing RPM Fusion free release URL install')"
_ln_terra="$(require_line_number "--repofrompath 'terra,https://repos.fyralabs.com/terra\$releasever' terra-release" 'Missing Terra install (official --repofrompath form with literal $releasever)')"
_ln_terra_mm="$(require_line_number '"${_mr_dnf}" install -y terra-release-multimedia' 'Missing terra-release-multimedia install step')"
_ln_mesa="$(require_line_number '"${_mr_dnf}" install -y terra-release-mesa' 'Missing terra-release-mesa install step')"
_ln_mmgrp="$(require_line_number '"${_mr_dnf}" install -y "@multimedia"' 'Missing multimedia group install step')"
_ln_ffswap="$(require_line_number 'swap -y ffmpeg-free ffmpeg --allowerasing' 'Missing ffmpeg-free -> full ffmpeg swap step')"
if [ "${_ln_rpmfusion}" -gt 0 ] && [ "${_ln_terra}" -gt 0 ] && [ "${_ln_terra}" -lt "${_ln_rpmfusion}" ] 2>/dev/null; then
    record_failure "Fedora path order broken: Terra step appears before the RPM Fusion step"
fi
if [ "${_ln_terra_mm}" -gt 0 ] && [ "${_ln_terra}" -gt 0 ] && [ "${_ln_terra_mm}" -lt "${_ln_terra}" ] 2>/dev/null; then
    record_failure "Fedora path order broken: terra-release-multimedia step appears before the terra-release step"
fi
if [ "${_ln_mesa}" -gt 0 ] && [ "${_ln_terra_mm}" -gt 0 ] && [ "${_ln_mesa}" -lt "${_ln_terra_mm}" ] 2>/dev/null; then
    record_failure "Fedora path order broken: Mesa override step appears before the terra-multimedia step"
fi
if [ "${_ln_mmgrp}" -gt 0 ] && [ "${_ln_mesa}" -gt 0 ] && [ "${_ln_mmgrp}" -lt "${_ln_mesa}" ] 2>/dev/null; then
    record_failure "Fedora path order broken: multimedia group step appears before the Mesa override step"
fi
if [ "${_ln_ffswap}" -gt 0 ] && [ "${_ln_mmgrp}" -gt 0 ] && [ "${_ln_ffswap}" -lt "${_ln_mmgrp}" ] 2>/dev/null; then
    record_failure "Fedora path order broken: ffmpeg swap step appears before the multimedia group step"
fi

# --- 5) RPM Fusion: official URLs + reachability pre-check ---
require_contains "${source_text}" 'https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${_mr_fedora_ver}.noarch.rpm' "Missing RPM Fusion nonfree release URL install"
require_contains "${source_text}" '__znh_check_service_reachable "https://mirrors.rpmfusion.org" "RPM Fusion (mirrors.rpmfusion.org)"' "Missing RPM Fusion reachability pre-check"
require_contains "${source_text}" '_mr_fedora_ver="$(rpm -E %fedora 2>/dev/null || true)"' "Missing %fedora macro expansion guard"
require_contains "${source_text}" 'does not expose the %fedora RPM macro' "Missing clean-exit for RHEL-like ID_LIKE matches without the %fedora macro"

# --- 6) Terra: official install + availability probe ---
require_contains "${source_text}" 'install -y --nogpgcheck' "Missing --nogpgcheck on the terra-release install (official Terra form)"
require_contains "${source_text}" '__znh_check_service_reachable "https://repos.fyralabs.com" "Terra (repos.fyralabs.com)"' "Missing Terra reachability pre-check"
require_contains "${source_text}" '"${_mr_dnf}" --quiet repoquery terra-release-multimedia >/dev/null 2>&1' "Missing terra-release-multimedia availability probe (published for Fedora 43+)"
require_contains "${source_text}" 'not published for this Fedora release (Fedora 43+ only)' "Missing clean skip when terra-release-multimedia is not published"

# --- 6b) v86: the "fully set up" no-op must require the Terra multimedia subrepo when published ---
require_contains "${source_text}" 'local _mr_mm_published=1' "Missing the v86 Terra-multimedia publishability flag in the fully-set-up check"
require_contains "${source_text}" '&& { [ "${ZNH_MEDIA_TERRA_MM_OK}" -eq 1 ] || [ "${_mr_mm_published}" -eq 0 ]; }' "Missing the v86 fixed fully-set-up condition (the Terra multimedia subrepo is required when published for the release — caught live: the probe said MISSING yet the shortcut exited fully-set-up)"
require_contains "${source_text}" 'Multimedia/codec repositories are already fully set up (RPM Fusion + Terra + multimedia subrepo + codec set present)' "Missing the v86 updated fully-set-up message"

# --- 6c) v88: interactive runs offer the optional Mesa prompt; ffmpeg-free label no longer reads like a missing component ---
require_contains "${source_text}" 'local _mr_proceed_to_prompt=0' "Missing the v88 proceed-to-prompt flag"
require_contains "${source_text}" 'if [ "${_mr_proceed_to_prompt}" -eq 0 ] \\' "Missing the v88 no-op-shortcut condition (non-interactive only)"
require_contains "${source_text}" 'NOT PRESENT (expected — the full-codec ffmpeg is in use; ffmpeg-free would REPLACE it)' "Missing the v88 clarifying ffmpeg-free probe label"
require_contains "${source_text}" 'INSTALLED (will be swapped to the full-codec ffmpeg)' "Missing the v88 ffmpeg-free swap-candidate label"
require_contains "${source_text}" 'v88: interactive runs also offer the' "Missing the v88 help-text note about interactive runs offering the Mesa prompt"

# --- 7) Mesa override: strictly confirm-gated (config key + --mesa-override flag) ---
require_contains "${source_text}" 'MEDIA_REPOS_MESA_OVERRIDE:-false' "Missing MEDIA_REPOS_MESA_OVERRIDE gate (string form)"
require_contains "${source_text}" '            --mesa-override)' "Missing --mesa-override dispatcher case arm"
require_contains "${source_text}" 'MEDIA_REPOS_MESA_OVERRIDE="true"' "Missing --mesa-override dispatcher flag mapping to the config key"
require_contains "${source_text}" 'validate_bool_flag MEDIA_REPOS_MESA_OVERRIDE false' "Missing MEDIA_REPOS_MESA_OVERRIDE config validator"
require_contains "${source_text}" '"MEDIA_REPOS_MESA_OVERRIDE": {"type": "bool", "default": "false"' "Missing MEDIA_REPOS_MESA_OVERRIDE schema key"
require_contains "${source_text}" 'MEDIA_REPOS_MESA_OVERRIDE=false' "Missing MEDIA_REPOS_MESA_OVERRIDE config template default"
require_contains "${source_text}" "MEDIA_REPOS_MESA_OVERRIDE', type: 'bool'" "Missing MEDIA_REPOS_MESA_OVERRIDE SETTINGS_FIELDS row"
require_contains "${source_text}" '"media-repos-mesa": {' "Missing media-repos-mesa WebUI quick action"
require_contains "${source_text}" '"phrase": "MEDIAREPOSMESA"' "Missing MEDIAREPOSMESA confirmation phrase"
require_contains "${source_text}" "Type 'YES' to proceed: " "Missing interactive YES confirmation prompt for the Mesa override"
require_contains "${source_text}" 'Non-interactive mode: the optional Terra Mesa override is skipped' "Missing non-interactive Mesa skip (must stay opt-in)"
require_contains "${source_text}" 'can conflict with RPM Fusion *-freeworld packages' "Missing Mesa override conflict warning (*-freeworld)"
require_contains "${source_text}" 'can affect HDR' "Missing Mesa override HDR warning"
require_contains "${source_text}" 'swap -y mesa-va-drivers-freeworld mesa-va-drivers --allowerasing' "Missing documented mesa-va-drivers freeworld -> Terra swap"
require_contains "${source_text}" "distro-sync -y 'mesa*'" "Missing Mesa distro-sync after enabling the override"

# --- 8) dnf5-default detection + dry-run mode ---
require_contains "${source_text}" 'if command -v dnf5 >/dev/null 2>&1; then
            _mr_dnf="dnf5"' "Missing dnf5-default detection"
require_contains "${source_text}" '[dry-run] Would run: $*' "Missing dry-run print in the command runner"
require_contains "${source_text}" 'MEDIA_REPOS_DRY_RUN:-0' "Missing MEDIA_REPOS_DRY_RUN gate"

# --- 9) Multimedia group + codec packages ---
require_contains "${source_text}" '--setopt=install_weak_deps=False --exclude=PackageKit-gstreamer-plugin' "Missing multimedia group setopt/exclude hardening"
require_contains "${source_text}" 'rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data' "Missing RPM Fusion AppStream data step"
require_contains "${source_text}" 'openh264 gstreamer1-plugin-openh264 mozilla-openh264 gstreamer1-plugin-libav' "Missing common codec package step"

# --- 10) Arch path ---
require_contains "${source_text}" 'pacman -S --noconfirm --needed' "Missing Arch idempotent codec-set install (--needed)"
require_contains "${source_text}" 'gst-plugins-ugly gst-libav ffmpeg; then' "Missing Arch codec package list in the install command"

# --- 10b) openSUSE family path (Packman + opi) ---
require_contains "${source_text}" 'zypper lr -u 2>/dev/null | grep -qi packman' "Missing Packman repo probe (zypper lr)"
require_contains "${source_text}" 'opi codecs' "Missing opi codecs (preferred documented openSUSE path)"
require_contains "${source_text}" 'zypper --non-interactive install --allow-vendor-change --from packman-essentials' "Missing Packman codec install with --allow-vendor-change --from"
require_contains "${source_text}" 'https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/Essentials/' "Missing Tumbleweed Packman Essentials URL"
require_contains "${source_text}" 'openSUSE_Leap_${_mr_suse_ver}/Essentials/' "Missing Leap Packman Essentials URL (version-keyed)"

# --- 10c) Debian/Ubuntu family path (deb-multimedia / standard codecs) ---
require_contains "${source_text}" 'deb-multimedia-keyring_2024.9.1_all.deb' "Missing deb-multimedia keyring package URL"
require_contains "${source_text}" '8dc6cbb266c701cfe58bd1d2eb9fe2245a1d6341c7110cfbfe3b5a975dcf97ca' "Missing deb-multimedia keyring SHA256 verification"
require_contains "${source_text}" '/etc/apt/sources.list.d/dmo.sources' "Missing deb-multimedia DEB822 source write"
require_contains "${source_text}" 'Signed-By: /usr/share/keyrings/deb-multimedia-keyring.pgp' "Missing DEB822 Signed-By keyring path"
require_contains "${source_text}" 'Suites: ${_mr_deb_codename}' "Missing DEB822 Suites codename substitution"
require_contains "${source_text}" 'libavcodec-extra' "Missing Debian codec set (libavcodec-extra)"
require_contains "${source_text}" 'ubuntu-restricted-extras' "Missing Ubuntu/Mint restricted-extras best-effort step"

# --- 11) CLI wiring: early allowlist + dispatcher + help ---
require_contains "${source_text}" '--setup-SF|--media-repos|--setup-media-repos|--copr-search|--uninstall-zypper' "Missing --media-repos/--copr-search in the early option allowlist"
require_contains "${source_text}" 'elif [[ "${1:-}" == "--media-repos" || "${1:-}" == "--setup-media-repos" ]]; then' "Missing --media-repos dispatcher branch"
require_contains "${source_text}" 'run_media_repos_only' "Missing run_media_repos_only dispatch call"
require_contains "${source_text}" '--media-repos           Detect the running distro (Fedora/Arch/openSUSE/Debian family via /etc/os-release)' "Missing --media-repos help text"

# --- 12) WebUI: tile + status fields + JS + quick action ---
require_contains "${source_text}" 'id="feat-media-repos-badge" data-module="media-repos" data-install-cmd="sudo zypper-auto-helper --media-repos"' "Missing Media Repos badge tile in Features & Config"
require_contains "${source_text}" '<strong id="feat-media-repos-val">${feat_media_repos}</strong>' "Missing Media Repos badge value element"
require_contains "${source_text}" "setText('feat-media-repos-val', d.feat_media_repos_installed ? 'READY' : 'MISSING');" "Missing JS live value update for the media-repos tile"
require_contains "${source_text}" "'media-repos': !!(d.feat_media_repos_installed)" "Missing JS _modInstalled media-repos entry"
require_contains "${source_text}" "'media-repos': !!(d.feat_media_repos_healthy)" "Missing JS _modHealthy media-repos entry"
require_contains "${source_text}" "setClass('feat-media-repos-dot', _modHealthy['media-repos']" "Missing JS dot class update for the media-repos tile"
require_contains "${source_text}" "var _mods = ['media-repos','arch-repos','flatpak','snap','soar','brew','pipx'];" "Missing media-repos entry in the JS badge class loop (media-repos first; arch-repos added in v70)"
require_contains "${source_text}" "'media-repos': 'media-repos'," "Missing _modQaMap media-repos quick-action mapping"
require_contains "${source_text}" '"media-repos": {' "Missing media-repos quick-action allowlist entry"
require_contains "${source_text}" '"phrase": "MEDIAREPOS"' "Missing MEDIAREPOS confirmation phrase in the quick action"
require_contains "${source_text}" '"feat_media_repos_installed": _env_bool("JSON_FEAT_MEDIA_REPOS_INSTALLED", False)' "Missing feat_media_repos_installed in the status-data Python writer"
require_contains "${source_text}" '"feat_media_repos_healthy": _env_bool("JSON_FEAT_MEDIA_REPOS_HEALTHY", False)' "Missing feat_media_repos_healthy in the status-data Python writer"
require_contains "${source_text}" 'JSON_FEAT_MEDIA_REPOS_INSTALLED="${json_feat_media_repos_installed}"' "Missing JSON_FEAT_MEDIA_REPOS_INSTALLED env passthrough"
require_contains "${source_text}" '"feat_media_repos_installed": ${json_feat_media_repos_installed},' "Missing feat_media_repos_installed in the shell JSON fallback"
require_contains "${source_text}" 'feat_media_repos_class=$([[ "${feat_media_repos_healthy}" == "1" ]]' "Missing feat_media_repos badge class computation"
require_contains "${source_text}" "danger: (qaAction === 'setup-SF' || qaAction === 'media-repos')" "Missing danger styling for the media-repos quick action"

# --- 13) Uninstaller note ---
require_contains "${source_text}" 'Multimedia/codec repositories configured by --media-repos' "Missing uninstaller note about intentionally kept media repos"

# --- 14) Bash syntax sanity of the target file ---
if ! bash -n "${TARGET_FILE}" >/dev/null 2>&1; then
    record_failure "Target file fails bash -n syntax check: ${TARGET_FILE}"
fi

# --- 15) RUNTIME: detection branches with fixture os-release files ---
_detect_fn_tmp="$(mktemp /tmp/znh_media_repos_detect_fn.XXXXXX)"
sed -n '/^znh_media_repos_detect_family() {/,/^}/p' "${TARGET_FILE}" > "${_detect_fn_tmp}" 2>/dev/null || true
if [ ! -s "${_detect_fn_tmp}" ]; then
    record_failure "Could not extract znh_media_repos_detect_family from ${TARGET_FILE}"
else
    _rt_tmpdir="$(mktemp -d /tmp/znh_media_repos_rt.XXXXXX)"
    printf '%s\n' 'ID=fedora' 'ID_LIKE=' > "${_rt_tmpdir}/os-fedora"
    printf '%s\n' 'ID=rocky' 'ID_LIKE="rhel fedora"' > "${_rt_tmpdir}/os-idlike-fedora"
    printf '%s\n' 'ID=arch' 'ID_LIKE=' > "${_rt_tmpdir}/os-arch"
    printf '%s\n' 'ID=manjaro' 'ID_LIKE=arch' > "${_rt_tmpdir}/os-idlike-arch"
    printf '%s\n' 'ID=alpine' 'ID_LIKE=' > "${_rt_tmpdir}/os-unsupported"

    printf '%s\n' 'ID=opensuse-tumbleweed' 'ID_LIKE=' > "${_rt_tmpdir}/os-opensuse"
    printf '%s\n' 'ID=sles' 'ID_LIKE="suse"' > "${_rt_tmpdir}/os-idlike-suse"
    printf '%s\n' 'ID=debian' 'VERSION_CODENAME=trixie' > "${_rt_tmpdir}/os-debian"
    printf '%s\n' 'ID=linuxmint' 'ID_LIKE="ubuntu debian"' > "${_rt_tmpdir}/os-mint"

    _detect_out() {
        # Usage: _detect_out <fixture-path>; prints the detected family.
        ZNH_OS_RELEASE_FILE="$1" bash -c 'source "${1}"; znh_media_repos_detect_family' _ "${_detect_fn_tmp}" 2>/dev/null || true
    }

    [ "$(_detect_out "${_rt_tmpdir}/os-fedora")" = "fedora" ] || record_failure "RUNTIME detection: ID=fedora did not detect the fedora family"
    [ "$(_detect_out "${_rt_tmpdir}/os-idlike-fedora")" = "fedora" ] || record_failure "RUNTIME detection: ID_LIKE contains fedora did not detect the fedora family"
    [ "$(_detect_out "${_rt_tmpdir}/os-arch")" = "arch" ] || record_failure "RUNTIME detection: ID=arch did not detect the arch family"
    [ "$(_detect_out "${_rt_tmpdir}/os-idlike-arch")" = "arch" ] || record_failure "RUNTIME detection: ID_LIKE contains arch did not detect the arch family"
    [ "$(_detect_out "${_rt_tmpdir}/os-opensuse")" = "suse" ] || record_failure "RUNTIME detection: ID=opensuse-tumbleweed did not detect the suse family"
    [ "$(_detect_out "${_rt_tmpdir}/os-idlike-suse")" = "suse" ] || record_failure "RUNTIME detection: ID_LIKE contains suse did not detect the suse family"
    [ "$(_detect_out "${_rt_tmpdir}/os-debian")" = "debian" ] || record_failure "RUNTIME detection: ID=debian did not detect the debian family"
    [ "$(_detect_out "${_rt_tmpdir}/os-mint")" = "debian" ] || record_failure "RUNTIME detection: ID_LIKE contains ubuntu (mint) did not detect the debian family"
    [ -z "$(_detect_out "${_rt_tmpdir}/os-unsupported")" ] || record_failure "RUNTIME detection: unsupported distro did not return an empty family"

    rm -rf -- "${_rt_tmpdir}" 2>/dev/null || true
fi
rm -f -- "${_detect_fn_tmp}" 2>/dev/null || true

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: media-repos universal multimedia/codec repository regression checks passed"
