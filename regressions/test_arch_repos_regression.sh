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
Usage: ./test_arch_repos_regression.sh [path/to/UNI-auto.sh]

Regression guard for the Arch unofficial repository manager (--arch-repos):
  - all ten hard failchecks (FC1-FC10) from the module spec:
    Arch-family gate, HTTPS-only, duplicate guard, ALHP CPU level,
    verbatim Arch Wiki warning, explicit confirmations (no silent
    defaults), never auto-import keys, one repo per run, post-add
    pacman -Sy validation with rollback, full action logging
  - catalog rows (verified wiki Server URLs + Key-IDs, signed/unsigned
    classes, forced SigLevel per class)
  - subcommands list/status/enable/disable/disable-all/health(--auto-disable)/history
  - --dry-run + --json listing + test override hooks
  - CLI wiring (early allowlist + dispatcher + help text) + uninstaller note
  - WebUI wiring (badge + status-data fields + JS maps + drawer card) and
    the dashboard API wiring (GET /api/arch-repos/list + dynamic quick
    actions with ARCHREPOENABLE/ARCHREPODISABLE/ARCHREPOHEAL/ARCHREPOSOFF)
  - RUNTIME fixtures: family gate, CPU level sets, section/duplicate probe,
    case-insensitive catalog lookup, ALHP level detection, health state TSV
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

require_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if grep -Fq -- "${needle}" <<< "${haystack}"; then
        record_failure "${label} (unexpectedly present: ${needle})"
    fi
}

require_contains_re() {
    local haystack="$1"
    local pattern="$2"
    local label="$3"
    if ! grep -Eq -- "${pattern}" <<< "${haystack}"; then
        record_failure "${label} (regex not matched: ${pattern})"
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

# --- 1) Module presence + CLI wiring ---
require_contains "${source_text}" 'run_arch_repos_only() {' "Missing run_arch_repos_only function"
require_contains "${source_text}" 'znh_arch_repos_state_probe() {' "Missing znh_arch_repos_state_probe (WebUI badge probe)"
require_contains "${source_text}" 'elif [[ "${1:-}" == "--arch-repos" || "${1:-}" == "--setup-arch-repos" ]]; then' "Missing --arch-repos dispatcher branch"
require_contains "${source_text}" 'run_arch_repos_only "$@"' "Missing run_arch_repos_only dispatch call with the subcommand args"
require_contains "${source_text}" '--setup-SF|--media-repos|--setup-media-repos|--copr-search|--uninstall-zypper|--arch-repos|--setup-arch-repos' "Missing --arch-repos in the early option allowlist"
require_contains "${source_text}" '  --arch-repos [list|status|enable <repo> [url]|disable <repo>|disable-all|health|history]' "Missing --arch-repos help text"

# --- 2) Failcheck documentation block + the EXACT verbatim wiki warning (FC5) ---
require_contains "${source_text}" 'FAILCHECKS (each one aborts BEFORE /etc/pacman.conf is touched):' "Missing the failcheck documentation block"
require_contains_re "${source_text}" 'FC(1|2|3|4|5|6|7|8|9|10) ' "Missing one or more FC1-FC10 markers in the failcheck block"
require_contains "${source_text}" 'ZNH_ARCH_REPOS_WIKI_WARNING="The official Arch Linux developers and the Package Maintainers do not perform tests of any sort to verify the contents of unofficial user repositories. It is your decision whether to trust their maintainers, and you take full responsibility for any consequences of using any unofficial repository."' "Missing the exact verbatim Arch Wiki warning constant"

# --- 3) FC1: Arch-family gate (clean exit elsewhere) ---
require_contains "${source_text}" 'if [ "${_ar_family}" != "arch" ]; then' "Missing the Arch-family gate branch"
require_contains "${source_text}" '--arch-repos targets Arch-family systems only. Exiting cleanly; nothing was changed.' "Missing the clean-exit message for non-Arch families"
require_contains "${source_text}" "printf '{\"supported\": false, \"family\": \"%s\", \"cpu_level\": 0, \"wiki_url\": \"%s\", \"warning_text\": \"%s\", \"repos\": []}\\n' \\" "Missing the machine-readable non-Arch JSON clean exit (list --json)"

# --- 4) FC2: HTTPS-only (refuse any non-https Server URL) ---
require_contains "${source_text}" 'FAILCHECK (HTTPS-only): refusing to enable' "Missing the HTTPS-only failcheck refusal"
require_contains "${source_text}" 'Repositories are never enabled over plain HTTP.' "Missing the plain-HTTP refusal explanation"

# --- 5) FC3: duplicate guard across BOTH config locations (pacman.conf + include file) ---
require_contains "${source_text}" 'FAILCHECK (duplicate): [${_ar_section}] already exists in the pacman configuration' "Missing the duplicate-guard failcheck"
require_contains "${source_text}" 'already exists in the pacman configuration (${ZNH_ARCH_REPOS_PACMAN_CONF} or ${ZNH_ARCH_REPOS_INCLUDE_FILE})' "Missing the both-locations duplicate-guard wording (v82)"
require_contains "${source_text}" 'FAILCHECK (duplicate): ALHP repositories are already enabled' "Missing the ALHP duplicate-guard failcheck"

# --- 5b) v82 include-file hybrid: wiring + migration + single Include line ---
require_contains "${source_text}" 'ZNH_ARCH_REPOS_INCLUDE_FILE="${ZNH_ARCH_INCLUDE_FILE:-/etc/pacman.d/zypper-auto-repos.conf}"' "Missing the v82 include-file override hook + default"
require_contains "${source_text}" 'znh_arch_repos_ensure_include() {' "Missing the v82 ensure_include wiring function"
require_contains "${source_text}" 'znh_arch_repos_grep_any_conf() {' "Missing the v82 both-locations grep helper"
require_contains "${source_text}" 'znh_arch_repos_include_wired() {' "Missing the v82 include-wired probe"
require_contains "${source_text}" '# >>> zypper-auto-helper arch-repos include (managed) >>>' "Missing the v82 managed Include-line block marker"
require_contains "${source_text}" 'pacman-conf --config="${_arei_conf}" --repo-list' "Missing the v82 migration validation via pacman-conf --repo-list"
require_contains "${source_text}" 'v82 migration FAILED; restoring the pre-migration files (fail-safe).' "Missing the v82 migration failure restore"
require_contains "${source_text}" 'v82 migration VALIDATION FAILED' "Missing the v82 migration validation-failure restore"
require_contains "${source_text}" 'if managed and any(b.strip() == sec_line for b in block):' "Missing the v82 remove_section body-match fix (managed blocks are only removed when they contain the named section)"
require_not_contains "${source_text}" 'tee -a "${_arab_conf}"' "v82 drift guard: append_block must append to the INCLUDE file, never to pacman.conf"
require_contains "${source_text}" 'tee -a "${_arab_incl}"' "Missing the v82 append_block include-file append"

# --- 5c) v83: key auto-import hardening + key sync + locale-proofing ---
require_contains "${source_text}" 'archlinuxcn-keyring|blackarch-keyring)' "Missing the v83 generalized keyring-package import case (archlinuxcn + blackarch)"
require_contains "${source_text}" 'archlinuxcn-keyring|blackarch-keyring) _area_kg_pkg=1 ;;' "Missing the v83 generalized bulk keyring-package detection"
require_contains "${source_text}" 'v83 KEY SYNC' "Missing the v83 key sync for already-enabled repos (heals rotated signing keys)"
require_contains "${source_text}" 'key sync for the already-enabled ${_area_fname} failed' "Missing the v83 key-sync warn-only failure message"
require_contains "${source_text}" 'if ${_ZNH_AR_AS_ROOT[@]+"${_ZNH_AR_AS_ROOT[@]}"} "${ZNH_ARCH_REPOS_PACMAN_BIN}" -Q "${_arki_key}" >/dev/null 2>&1; then' "Missing the v83 keyring-package idempotency check (pacman -Q skip)"
require_contains "${source_text}" 'env LC_ALL=C timeout "${ZNH_ARCH_REPOS_SYNC_TIMEOUT}" "${ZNH_ARCH_REPOS_PACMAN_BIN}" -Sy --noconfirm 2>&1' "Missing the v83 LC_ALL=C locale-proofed sync (Swedish pacman \"fel:\" was invisible to the error|fail greps)"
require_contains_re "${source_text}" 'env LC_ALL=C timeout "\$\{ZNH_ARCH_REPOS_SYNC_TIMEOUT\}"' "Missing the v83 LC_ALL=C prefix on the module pacman syncs (at least one)"
require_contains "${source_text}" 'pacman reports the database signer as this 40-char fingerprint' "Missing the v83 coderkun-aur rotated-key note in the catalog"

# --- 6) FC4: ALHP microarchitecture level check (exact psABI flag sets) ---
require_contains "${source_text}" 'FAILCHECK (ALHP CPU level): this CPU supports x86-64-v${_ar_cpu}' "Missing the ALHP CPU-level failcheck"
require_contains "${source_text}" '"cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3" "avx avx2 bmi1 bmi2 f16c fma abm movbe xsave" "avx512f avx512bw avx512cd avx512dq avx512vl"' "Missing the exact x86-64 psABI level flag sets"
require_contains "${source_text}" 'Unsupported optimised binaries can make the system unbootable' "Missing the unbootable-system warning in the ALHP level refusal"

# --- 7) FC6: explicit confirmations; no silent defaults ---
require_contains "${source_text}" 'Type ACCEPT to accept the warning above and take full responsibility: ' "Missing the ACCEPT confirmation prompt"
require_contains "${source_text}" 'Type KEYVERIFIED to confirm you verified the Key-ID yourself and will import/sign it locally: ' "Missing the KEYVERIFIED confirmation prompt (signed repos)"
require_contains "${source_text}" 'Type UNSIGNOK to re-confirm you accept SigLevel = PackageOptional for it: ' "Missing the UNSIGNOK re-confirmation prompt (unsigned repos)"
require_contains "${source_text}" 'FAILCHECK (no silent defaults): non-interactive enable requires --assume-yes' "Missing the no-silent-defaults failcheck for non-interactive enable"
require_contains "${source_text}" 'FAILCHECK (key confirmation): non-interactive enable of a SIGNED repository requires --key-verified' "Missing the non-interactive key-confirmation failcheck"
require_contains "${source_text}" 'FAILCHECK (unsigned re-confirm): non-interactive enable of an UNSIGNED repository requires --unsigned-accepted' "Missing the non-interactive unsigned re-confirmation failcheck"
require_contains "${source_text}" 'FAILCHECK (no silent defaults): non-interactive disable requires --yes.' "Missing the no-silent-defaults failcheck for non-interactive disable"
require_contains "${source_text}" 'FAILCHECK (no silent defaults): non-interactive --auto-disable requires --yes.' "Missing the no-silent-defaults failcheck for non-interactive auto-disable"

# --- 8) FC7: keys are NEVER auto-imported (ALHP mirrorlist/keyring user-installed) ---
require_contains "${source_text}" 'this helper NEVER imports or signs it' "Missing the never-auto-import key statement"
require_contains "${source_text}" 'FAILCHECK (no auto-install): the ALHP mirrorlist' "Missing the ALHP no-auto-install failcheck"
require_contains "${source_text}" 'Install '"'"'alhp-mirrorlist'"'"' and '"'"'alhp-keyring'"'"' from the AUR YOURSELF' "Missing the AUR self-install instruction for ALHP prerequisites"

# --- 9) FC8: one repository per run ---
require_contains "${source_text}" 'FAILCHECK (one repository per run): refusing to enable more than one repository in a single run' "Missing the one-repo-per-run failcheck"

# --- 10) FC9: post-add pacman -Sy validation with rollback ---
require_contains "${source_text}" 'FAILCHECK (post-add validation): ${ZNH_ARCH_REPOS_PACMAN_BIN} -Sy failed after adding ${_ar_name}; rolling the change back.' "Missing the post-add validation failcheck"
require_contains "${source_text}" 'timeout "${ZNH_ARCH_REPOS_SYNC_TIMEOUT}" "${ZNH_ARCH_REPOS_PACMAN_BIN}" -Sy --noconfirm' "Missing the timeout-bounded pacman -Sy post-add validation"
require_contains "${source_text}" 'ZNH_ARCH_REPOS_SYNC_TIMEOUT="${ZNH_ARCH_SYNC_TIMEOUT:-90}"' "Missing the ZNH_ARCH_REPOS_SYNC_TIMEOUT default (90s)"
require_contains "${source_text}" 'Rolled back: ${ZNH_ARCH_REPOS_INCLUDE_FILE} restored from ${_ar_backup}.' "Missing the rollback restore from the include-file backup (v82)"
require_contains "${source_text}" 'Rolled back: the [${_ar_section}] stanza was removed from the arch-repos config locations.' "Missing the v82 per-section rollback message"
require_contains "${source_text}" 'If you have not imported the repository key yet (signed repos), do that FIRST' "Missing the not-yet-imported-key explanation in the rollback message"

# --- 11) FC10: full action logging (state TSV + health TSV) ---
require_contains "${source_text}" 'arch-repos-state.tsv' "Missing the state TSV path"
require_contains "${source_text}" 'arch-repos-health.tsv' "Missing the health TSV path"
require_contains "${source_text}" 'znh_arch_repos_state_log "${_ar_name}" "enabled" "${_ar_class}"' "Missing the enabled state-log write after a successful enable"
require_contains "${source_text}" 'znh_arch_repos_state_log "${_arfb}" "auto-disabled" "failed the health check"' "Missing the auto-disabled state-log write in the failsafe"

# --- 12) Catalog rows (single-quoted so $arch/$repo stay literal) ---
require_contains "${source_text}" "'chaotic-aur|signed|https://geo-mirror.chaotic.cx/\$repo/\$arch|FBA220DFC880C036|" "Missing the chaotic-aur catalog row (verified URL + Key-ID)"
require_contains "${source_text}" "'archlinuxcn|signed|https://repo.archlinuxcn.org/\$arch|archlinuxcn-keyring|" "Missing the archlinuxcn catalog row (archlinuxcn-keyring FIRST note)"
require_contains "${source_text}" 'Install archlinuxcn-keyring FIRST, before any other package' "Missing the archlinuxcn-keyring-first note"
require_contains "${source_text}" "'archzfs|signed|https://github.com/archzfs/archzfs/releases/download/experimental|3A9917BF0DED5C13F69AC68FABEC0A1208037BE9|" "Missing the archzfs catalog row (verified URL + Key-ID)"
require_contains "${source_text}" 'Server = https://mirrors.uni-plovdiv.net/archzfs/experimental' "Missing the archzfs second mirror server line"
require_contains "${source_text}" "'arch4edu|signed|https://mirrors.tuna.tsinghua.edu.cn/arch4edu/\$arch|7931B6D628C8D3BA|" "Missing the arch4edu catalog row"
require_contains "${source_text}" "'bioarchlinux|signed|https://repo.bioarchlinux.org/\$arch|B1F96021DB62254D|" "Missing the bioarchlinux catalog row"
require_contains "${source_text}" "'blackarch|signed|https://blackarch.org/blackarch/blackarch/os/\$arch|blackarch-keyring|" "Missing the blackarch catalog row (v83; verified from the official blackarch.org strap.sh)"
require_contains "${source_text}" 'BlackArch Linux penetration-testing repository' "Missing the blackarch catalog note"
require_contains "${source_text}" "'coderkun-aur|signed|https://arch.suruatoel.xyz/\$repo/\$arch/|DB03E36F7F2BD6C3EDBF30DDC1A4F1C3A5397243|" "Missing the coderkun-aur catalog row with the v83 live-verified 40-char signing fingerprint"
require_not_contains "${source_text}" "'coderkun-aur|signed|https://arch.suruatoel.xyz/\$repo/\$arch/|39E27199A6BEE374|" "v83 drift guard: the stale wiki coderkun-aur key must be gone from the catalog row"
require_contains "${source_text}" "'ada|signed|http://www.orthanc.site:8080/assets/arch_ada_repo|0xED55AF75B0330A2A3BAA9986B6120CD888A0DFD2|" "Missing the ada catalog row (the http URL the HTTPS failcheck refuses)"
require_contains "${source_text}" 'The wiki lists a plain-HTTP server, so the HTTPS failcheck refuses this catalog URL' "Missing the ada plain-HTTP note (HTTPS failcheck demo)"
require_contains "${source_text}" "'ALHP|signed||alhp-keyring (AUR)|" "Missing the ALHP catalog row (special handling, empty URL)"
require_contains "${source_text}" "'mesa-git|unsigned||see the wiki page|" "Missing the mesa-git unsigned catalog row"
require_contains "${source_text}" "'heftig|unsigned||see the wiki page|" "Missing the heftig unsigned catalog row"

# --- 13) SigLevel per class: PackageRequired (signed) / FORCED PackageOptional (unsigned) ---
require_contains "${source_text}" 'local _ar_siglevel="PackageRequired"' "Missing the signed-repo SigLevel (PackageRequired)"
require_contains "${source_text}" '_ar_siglevel="PackageOptional"' "Missing the FORCED unsigned-repo SigLevel (PackageOptional)"
require_contains "${source_text}" 'This repository is UNSIGNED; enabling forces SigLevel = PackageOptional (signatures NOT checked).' "Missing the unsigned SigLevel-forced explanation shown before confirmation"

# --- 14) Subcommands + flags + dry-run + JSON + override hooks ---
require_contains "${source_text}" 'znh_arch_repos_list_json' "Missing the --json listing function"
require_contains "${source_text}" '[dry-run] Would append this managed block to ${ZNH_ARCH_REPOS_INCLUDE_FILE}:' "Missing the dry-run block preview (v82: stanzas go to the include file)"
require_contains "${source_text}" 'v82 include-file hybrid: the stanza would be appended to ${ZNH_ARCH_REPOS_INCLUDE_FILE}' "Missing the v82 include-file hybrid dry-run explanation"
require_contains "${source_text}" '[dry-run] Would then run: timeout ${ZNH_ARCH_REPOS_SYNC_TIMEOUT}s ${ZNH_ARCH_REPOS_PACMAN_BIN} -Sy --noconfirm' "Missing the dry-run validation preview"
require_contains "${source_text}" 'ZNH_ARCH_REPOS_PACMAN_CONF="${ZNH_ARCH_PACMAN_CONF:-/etc/pacman.conf}"' "Missing the ZNH_ARCH_PACMAN_CONF test override hook"
require_contains "${source_text}" 'ZNH_ARCH_REPOS_CPUINFO_FILE="${ZNH_ARCH_CPUINFO_FILE:-/proc/cpuinfo}"' "Missing the ZNH_ARCH_CPUINFO_FILE test override hook"
require_contains "${source_text}" 'ZNH_ARCH_REPOS_STATE_DIR="${ZNH_ARCH_STATE_DIR:-/var/lib/zypper-auto}"' "Missing the ZNH_ARCH_STATE_DIR test override hook"
require_contains "${source_text}" 'ZNH_ARCH_REPOS_PACMAN_BIN="${ZNH_ARCH_PACMAN_BIN:-pacman}"' "Missing the ZNH_ARCH_PACMAN_BIN test override hook"
require_contains "${source_text}" 'if [ "${ZNH_ARCH_SUDO_MODE:-auto}" = "never" ]; then' "Missing the ZNH_ARCH_SUDO_MODE=never fixture hook"
require_contains "${source_text}" 'znh_arch_repos_check_db_reachable() {' "Missing the repo-database reachability probe (ranged GET + HEAD fallback)"
require_contains "${source_text}" '-r 0-1023 "${_ard_db}"' "Missing the ranged-GET repo database probe"

# --- 15) Health failsafe: auto-disable of faulty repositories ---
require_contains "${source_text}" '--auto-disable)' "Missing the --auto-disable flag branch"
require_contains "${source_text}" 'Auto-disable (remove) the faulty repositories listed above? [y/N]: ' "Missing the auto-disable confirmation prompt"
require_contains "${source_text}" 'unreachable' "Missing the unreachable health state"
require_contains "${source_text}" 'Report-only mode. Run with --auto-disable to remove faulty repositories automatically' "Missing the report-only mode message"

# --- 16) Uninstaller note (repos kept + removal hints + state log path) ---
require_contains "${source_text}" 'Unofficial Arch repositories enabled via --arch-repos are kept as well' "Missing the uninstaller note about kept Arch repositories"
require_contains "${source_text}" 'sudo zypper-auto-helper --arch-repos disable <repo> (or '"'"'disable-all'"'"').' "Missing the uninstaller disable/disable-all removal hint"
require_contains "${source_text}" 'The enable/disable state log stays at /var/lib/zypper-auto/arch-repos-state.tsv.' "Missing the uninstaller state-log note"

# --- 17) WebUI badge + status-data.json fields ---
require_contains "${source_text}" '<strong id="feat-arch-repos-val">${feat_arch_repos}</strong>' "Missing the Arch Repos badge value element"
require_contains "${source_text}" "setText('feat-arch-repos-val', _arSup ? (_arIns ? (_arHea ? 'READY' : 'ATTN') : 'NONE') : 'N/A');" "Missing the JS live value update for the arch-repos tile (N/A/NONE/READY/ATTN)"
require_contains "${source_text}" "'arch-repos': !!(d.feat_arch_repos_installed)" "Missing JS _modInstalled arch-repos entry"
require_contains "${source_text}" "'arch-repos': !!(d.feat_arch_repos_healthy)" "Missing JS _modHealthy arch-repos entry"
require_contains "${source_text}" "setClass('feat-arch-repos-dot', _modHealthy['arch-repos'], _modInstalled['arch-repos'] && !_modHealthy['arch-repos']);" "Missing the arch-repos dot class update"
require_contains "${source_text}" "var _mods = ['media-repos','arch-repos','flatpak','snap','soar','brew','pipx'];" "Missing arch-repos in the _mods badge class loop"
require_contains "${source_text}" 'feat_arch_repos_supported=$([[ "${feat_arch_repos_supported}" == "1" ]] && echo true || echo false)' "Missing the feat_arch_repos_supported JSON computation"
require_contains "${source_text}" '"feat_arch_repos_supported": _env_bool("JSON_FEAT_ARCH_REPOS_SUPPORTED", False)' "Missing feat_arch_repos_supported in the status-data Python writer"
require_contains "${source_text}" 'JSON_FEAT_ARCH_REPOS_INSTALLED="${json_feat_arch_repos_installed}"' "Missing the JSON_FEAT_ARCH_REPOS_INSTALLED env passthrough"
require_contains "${source_text}" '"feat_arch_repos_healthy": ${json_feat_arch_repos_healthy},' "Missing feat_arch_repos_healthy in the shell JSON fallback"

# --- 18) WebUI drawer card + per-repo quick-action wiring ---
require_contains "${source_text}" 'id="arch-repos-drawer"' "Missing the Arch repos drawer element"
require_contains "${source_text}" 'arch_repos_notsupported_style="display:none;"' "Missing the non-Arch notice style default (hidden on Arch)"
require_contains "${source_text}" 'arch_repos_toolbar_style="display:none;"' "Missing the non-Arch action-toolbar hidden style (v72: drawer always rendered, toolbar hidden on non-Arch)"
require_contains "${source_text}" 'id="arch-repos-list"' "Missing the arch-repos list container"
require_contains "${source_text}" 'id="arch-repos-warning"' "Missing the arch-repos warning banner element"
require_contains "${source_text}" 'data-qa="arch-repos-auto-heal"' "Missing the Auto-disable faulty toolbar quick action button"
require_contains "${source_text}" 'data-qa="arch-repos-health"' "Missing the Check health toolbar quick action button"
require_contains "${source_text}" 'data-qa="arch-repos-disable-all"' "Missing the Disable all toolbar quick action button"
require_contains "${source_text}" "_znhArchReposFetch" "Missing the arch-repos card fetch function"
require_contains "${source_text}" "action: 'arch-repos-enable:' + n," "Missing the per-repo enable quick-action wiring in the card"
require_contains "${source_text}" "action: 'arch-repos-disable:' + n," "Missing the per-repo disable quick-action wiring in the card"
require_contains "${source_text}" "window.addEventListener('znh-data-updated', function() {" "Missing the data-updated re-fetch listener for the arch-repos card"
require_contains "${source_text}" "try { _znhArchReposFetch(); } catch (eAR1) {}" "Missing the data-updated re-fetch call for the arch-repos card"

# --- 19) Dashboard API: GET endpoint + auth prefix + dynamic quick actions ---
require_contains "${source_text}" 'if path == "/api/arch-repos/list":' "Missing the GET /api/arch-repos/list endpoint"
require_contains "${source_text}" 'path.startswith("/api/arch-repos/")' "Missing /api/arch-repos/ in an auth-required prefix list"
require_contains "${source_text}" 'def _arch_repos_quick_actions() -> dict:' "Missing the _arch_repos_quick_actions builder"
require_contains "${source_text}" 'tbl.update(_arch_repos_quick_actions())' "Missing the quick-action table update with the arch-repos entries"
require_contains "${source_text}" '"phrase": "ARCHREPOENABLE",' "Missing the ARCHREPOENABLE confirmation phrase"
require_contains "${source_text}" '"phrase": "ARCHREPODISABLE",' "Missing the ARCHREPODISABLE confirmation phrase"
require_contains "${source_text}" '"phrase": "ARCHREPOHEAL",' "Missing the ARCHREPOHEAL confirmation phrase"
require_contains "${source_text}" '"phrase": "ARCHREPOSOFF",' "Missing the ARCHREPOSOFF confirmation phrase"
require_contains "${source_text}" '"cmd": [HELPER_BIN, "--arch-repos", "enable", name, "--assume-yes", "--key-verified", "--unsigned-accepted"],' "Missing the per-repo enable quick-action command"
require_contains "${source_text}" '"cmd": [HELPER_BIN, "--arch-repos", "health", "--auto-disable", "--yes"],' "Missing the auto-heal quick-action command"

# --- 20) Bash syntax sanity of the target file ---
if ! bash -n "${TARGET_FILE}" >/dev/null 2>&1; then
    record_failure "Target file fails bash -n syntax check: ${TARGET_FILE}"
fi

# ============================================================================
# RUNTIME fixture tests (extract the real functions from the target and exec
# them against fixture files; no network, no system changes)
# ============================================================================
_rt_dir="$(mktemp -d /tmp/znh_arch_repos_rt.XXXXXX)"
trap 'rm -rf -- "${_rt_dir}"' EXIT

# Extract the dependency-light helpers (no log_* calls) into one source file.
_ar_fn_file="${_rt_dir}/arch_fns.sh"
{
    sed -n '/^znh_arch_repos_catalog_lookup() {/,/^}/p' "${TARGET_FILE}"
    sed -n '/^znh_arch_repos_grep_any_conf() {/,/^}/p' "${TARGET_FILE}"
    sed -n '/^znh_arch_repos_section_exists() {/,/^}/p' "${TARGET_FILE}"
    sed -n '/^znh_arch_repos_alhp_level() {/,/^}/p' "${TARGET_FILE}"
    sed -n '/^znh_arch_repos_cpu_level() {/,/^}/p' "${TARGET_FILE}"
    sed -n '/^znh_arch_repos_health_state() {/,/^}/p' "${TARGET_FILE}"
    sed -n '/^znh_arch_repos_expand_url() {/,/^}/p' "${TARGET_FILE}"
    sed -n '/^ZNH_ARCH_REPO_SPECS=(/,/^)/p' "${TARGET_FILE}"
} >"${_ar_fn_file}" 2>/dev/null || true

if ! grep -q 'znh_arch_repos_cpu_level() {' "${_ar_fn_file}" 2>/dev/null; then
    record_failure "Could not extract the arch-repos helper functions from ${TARGET_FILE}"
else
    # --- Fixture files ---
    _os_arch="${_rt_dir}/os-release-arch"
    printf 'ID=arch\nID_LIKE=archlinux\n' >"${_os_arch}"
    _os_manjaro="${_rt_dir}/os-release-manjaro"
    printf 'ID=manjaro\nID_LIKE=arch\n' >"${_os_manjaro}"
    _os_fedora="${_rt_dir}/os-release-fedora"
    printf 'ID=fedora\n' >"${_os_fedora}"

    _cpu_v2="${_rt_dir}/cpuinfo-v2"
    printf 'flags\t\t: fpu vme cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 cmov\n' >"${_cpu_v2}"
    _cpu_v3="${_rt_dir}/cpuinfo-v3"
    printf 'flags\t\t: fpu cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave\n' >"${_cpu_v3}"
    _cpu_v4="${_rt_dir}/cpuinfo-v4"
    printf 'flags\t\t: cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave avx512f avx512bw avx512cd avx512dq avx512vl\n' >"${_cpu_v4}"
    _cpu_v1="${_rt_dir}/cpuinfo-v1"
    printf 'flags\t\t: fpu vme sse sse2 syscall cmov\n' >"${_cpu_v1}"
    _cpu_none="${_rt_dir}/cpuinfo-none"
    printf 'model name\t: qemu\n' >"${_cpu_none}"

    _conf="${_rt_dir}/pacman.conf"
    {
        printf '[options]\nHoldPkg = pacman glibc\n\n'
        printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n\n'
        printf '[extra]\nInclude = /etc/pacman.d/mirrorlist\n\n'
        printf '[chaotic-aur]\nSigLevel = PackageRequired\nServer = https://geo-mirror.chaotic.cx/$repo/$arch\n\n'
        printf '[build.kilabit.info]\nSigLevel = PackageRequired\nServer = https://build.kilabit.info/aur\n\n'
        printf '[core-x86-64-v3]\nInclude = /etc/pacman.d/alhp-mirrorlist\n\n'
    } >"${_conf}"

    # v82 include-file fixture (a stanza that lives ONLY in the include file).
    _incl="${_rt_dir}/zypper-auto-repos.conf"
    {
        printf '# zypper-auto-helper arch-repos include file (v82) fixture\n'
        printf '[archzfs]\nSigLevel = PackageRequired\nServer = https://github.com/archzfs/archzfs/releases/download/experimental\n\n'
    } >"${_incl}"

    _state_dir="${_rt_dir}/state"
    mkdir -p "${_state_dir}"
    # Two entries, appended in order: for chaotic-aur the newest (last) entry is
    # 'ok'; for archlinuxcn the newest is 'unreachable' (newest entry wins).
    printf '2026-10-21T19:00:00Z\tchaotic-aur\tok\thealth run\n' >"${_state_dir}/arch-repos-health.tsv"
    printf '2026-10-21T20:00:00Z\tarchlinuxcn\tunreachable\thealth run\n' >>"${_state_dir}/arch-repos-health.tsv"

    # --- FC1 runtime: the shared family detector (Arch gate input) ---
    _detect_fn="${_rt_dir}/detect_fn.sh"
    sed -n '/^znh_media_repos_detect_family() {/,/^}/p' "${TARGET_FILE}" >"${_detect_fn}" 2>/dev/null || true
    if [ -s "${_detect_fn}" ]; then
        for _fixture in "${_os_arch}:arch" "${_os_manjaro}:arch" "${_os_fedora}:fedora"; do
            _os_file="${_fixture%%:*}"
            _want="${_fixture##*:}"
            _got="$(ZNH_OS_RELEASE_FILE="${_os_file}" bash -c 'source "${1}"; znh_media_repos_detect_family' _ "${_detect_fn}" 2>/dev/null || true)"
            if [ "${_got}" != "${_want}" ]; then
                record_failure "FC1 runtime: family detector returned '${_got}' for ${_os_file} (expected '${_want}')"
            fi
        done
    else
        record_failure "Could not extract znh_media_repos_detect_family for the FC1 runtime fixtures"
    fi

    # --- FC4 runtime: CPU level detection from cpuinfo flags ---
    for _fixture in "${_cpu_v2}:2" "${_cpu_v3}:3" "${_cpu_v4}:4" "${_cpu_v1}:1" "${_cpu_none}:0"; do
        _cpu_file="${_fixture%%:*}"
        _want="${_fixture##*:}"
        _got="$(ZNH_ARCH_REPOS_CPUINFO_FILE="${_cpu_file}" bash -c 'source "${1}"; znh_arch_repos_cpu_level' _ "${_ar_fn_file}" 2>/dev/null || true)"
        if [ "${_got}" != "${_want}" ]; then
            record_failure "FC4 runtime: cpu_level returned '${_got}' for ${_cpu_file} (expected '${_want}')"
        fi
    done

    # --- FC3 runtime: section existence probe (dotted names + the v82
    # include file: archzfs lives ONLY in the include fixture — the probe
    # must find it there; archlinuxcn exists in neither). ---
    for _probe in "chaotic-aur:0" "archzfs:0" "build.kilabit.info:0" "archlinuxcn:1" "no-such-repo:1"; do
        _section="${_probe%%:*}"
        _want_fail="${_probe##*:}"
        ZNH_ARCH_REPOS_PACMAN_CONF="${_conf}" ZNH_ARCH_REPOS_INCLUDE_FILE="${_incl}" bash -c 'source "${1}"; znh_arch_repos_section_exists "${2}"' _ "${_ar_fn_file}" "${_section}" 2>/dev/null \
            && _got_fail=0 || _got_fail=1
        if [ "${_got_fail}" != "${_want_fail}" ]; then
            record_failure "FC3 runtime: section_exists '${_section}' returned fail=${_got_fail} (expected fail=${_want_fail})"
        fi
    done

    # --- Catalog runtime: case-insensitive lookup + unknown refusal ---
    _spec="$(bash -c 'source "${1}"; znh_arch_repos_catalog_lookup "CHAOTIC-AUR"' _ "${_ar_fn_file}" 2>/dev/null || true)"
    if ! grep -Fq 'chaotic-aur|signed|https://geo-mirror.chaotic.cx/$repo/$arch|FBA220DFC880C036' <<<"${_spec}"; then
        record_failure "Catalog runtime: case-insensitive lookup of CHAOTIC-AUR did not return the chaotic-aur spec (got: ${_spec})"
    fi
    _spec_unknown="$(bash -c 'source "${1}"; znh_arch_repos_catalog_lookup "definitely-not-a-repo"' _ "${_ar_fn_file}" 2>/dev/null || true)"
    if [ -n "${_spec_unknown}" ]; then
        record_failure "Catalog runtime: unknown repo lookup should return empty (got: ${_spec_unknown})"
    fi

    # --- ALHP level detection runtime (both config locations; the v3
    # section lives in the pacman.conf fixture) ---
    _alhp="$(ZNH_ARCH_REPOS_PACMAN_CONF="${_conf}" ZNH_ARCH_REPOS_INCLUDE_FILE="${_incl}" bash -c 'source "${1}"; znh_arch_repos_alhp_level' _ "${_ar_fn_file}" 2>/dev/null || true)"
    if [ "${_alhp}" != "v3" ]; then
        record_failure "ALHP runtime: alhp_level returned '${_alhp}' for a [core-x86-64-v3] fixture (expected 'v3')"
    fi
    # v82: an ALHP section that lives ONLY in the include file is also detected.
    _incl_alhp="${_rt_dir}/zypper-auto-repos-alhp.conf"
    printf '[core-x86-64-v2]\nInclude = /etc/pacman.d/alhp-mirrorlist\n' >"${_incl_alhp}"
    _alhp2="$(ZNH_ARCH_REPOS_PACMAN_CONF="${_rt_dir}/pacman.conf-empty" ZNH_ARCH_REPOS_INCLUDE_FILE="${_incl_alhp}" bash -c 'source "${1}"; znh_arch_repos_alhp_level' _ "${_ar_fn_file}" 2>/dev/null || true)"
    if [ "${_alhp2}" != "v2" ]; then
        record_failure "ALHP runtime (v82 include file): alhp_level returned '${_alhp2}' for an include-only [core-x86-64-v2] fixture (expected 'v2')"
    fi

    # --- Health state TSV runtime: ok / unreachable / unknown ---
    _h_ok="$(ZNH_ARCH_REPOS_STATE_DIR="${_state_dir}" bash -c 'source "${1}"; znh_arch_repos_health_state "chaotic-aur"' _ "${_ar_fn_file}" 2>/dev/null || true)"
    if [ "${_h_ok}" != "ok" ]; then
        record_failure "Health runtime: chaotic-aur state returned '${_h_ok}' (expected 'ok')"
    fi
    _h_bad="$(ZNH_ARCH_REPOS_STATE_DIR="${_state_dir}" bash -c 'source "${1}"; znh_arch_repos_health_state "archlinuxcn"' _ "${_ar_fn_file}" 2>/dev/null || true)"
    if [ "${_h_bad}" != "unreachable" ]; then
        record_failure "Health runtime: archlinuxcn state returned '${_h_bad}' (expected 'unreachable' — newest entry wins)"
    fi
    _h_none="$(ZNH_ARCH_REPOS_STATE_DIR="${_state_dir}" bash -c 'source "${1}"; znh_arch_repos_health_state "no-such-repo"' _ "${_ar_fn_file}" 2>/dev/null || true)"
    if [ "${_h_none}" != "unknown" ]; then
        record_failure "Health runtime: unknown repo state returned '${_h_none}' (expected 'unknown')"
    fi

    # --- URL expansion runtime: pacman $repo/$arch variables ---
    _url="$(bash -c 'source "${1}"; znh_arch_repos_expand_url "https://geo-mirror.chaotic.cx/\$repo/\$arch" "chaotic-aur"' _ "${_ar_fn_file}" 2>/dev/null || true)"
    if ! grep -Eq '^https://geo-mirror\.chaotic\.cx/chaotic-aur/(x86_64|aarch64)$' <<<"${_url}"; then
        record_failure "URL runtime: expand_url returned '${_url}' (expected the pacman \$repo and \$arch variables substituted)"
    fi
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: arch-repos failchecks + WebUI/API wiring + runtime fixtures regression passed"
