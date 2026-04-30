#!/usr/bin/env bash
# Static regression smoke test for the downloader prefetch error classifier
# + libdnf5 offline-staging sandbox path fix.
#
# Why this test exists:
# Older builds blanket-classified ANY non-zero rc from the downloader prefetch
# (and the distro-upgrade prefetch) as `error:solver:RC` and wrote that into
# `/var/log/zypper-auto/download-status.txt`. The WebUI Notification Center
# then surfaced a high-severity "Downloader prefetch error / Solver/download
# error (rc=1) / Incident: inc-downloader-solver-1" popup even when the actual
# failure was:
#   * benign "Nothing to do" exit (per package manager),
#   * a transient DNS/connect/network issue,
#   * a sandbox/EROFS error (e.g. dnf5 staging the offline upgrade under
#     /usr/lib/sysimage/libdnf5/offline/ being blocked by ProtectSystem=full
#     when the unit's ReadWritePaths= didn't list libdnf5 staging dirs).
#
# This regression guards:
#   * the new shared package-manager helpers
#     (`znh_pm_is_readonly_fs_output_file`, `znh_pm_is_benign_no_updates_output_file`),
#   * the new downloader classifier `znh_downloader_classify_download_failure`,
#   * the libdnf5 offline staging dirs land in BOTH the deployed
#     `zypper-autodownload.service` ReadWritePaths= line AND the verify
#     auto-repair Check 10c rewrite (`dl_expected_rw`),
#   * the auto-repair trigger now ALSO fires when the existing
#     ReadWritePaths= is missing the libdnf5 staging dirs entirely,
#   * the cross-distro / zypper / distro-upgrade prefetch failure paths route
#     through the classifier instead of writing `error:solver:$RC` directly,
#   * `znh_downloader_run_prefetch_download` exposes the captured stderr file
#     to the caller via the new optional second arg.
#
# Format: prints `FAIL SUMMARY (N)` and exits 1 on failure.

# This regression intentionally greps the target file for literal `${...}`
# placeholders that appear inside heredocs (the unit-template line uses
# `${LOG_DIR}`/`${user_dash_rw}`/`${dl_expected_rw}`). Single quotes are
# required so the shell does not expand them before grep sees them.
# shellcheck disable=SC2016,SC1003

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_downloader_prefetch_error_classification_regression.sh [path/to/UNI-auto.sh]

Asserts that the embedded downloader script classifies prefetch failures
correctly (benign vs network vs read-only sandbox vs solver) and that the
generated zypper-autodownload.service plus the verify auto-repair
`dl_expected_rw` line both include the dnf5 libdnf5 offline staging dirs.
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

FAILURES=()

record_failure() {
    FAILURES+=("$1")
}

require_contains() {
    local needle="$1" label="$2"
    if ! grep -Fq -- "${needle}" "${TARGET_FILE}"; then
        record_failure "${label} (missing: ${needle})"
    fi
}

require_extended_grep() {
    local pattern="$1" label="$2"
    if ! grep -Eq -- "${pattern}" "${TARGET_FILE}"; then
        record_failure "${label} (missing pattern: ${pattern})"
    fi
}

# --- 1) Read-only / EROFS detector helper exists with the expected pattern ---
require_contains \
    'znh_pm_is_readonly_fs_output_file() {' \
    "Missing helper znh_pm_is_readonly_fs_output_file (read-only sandbox detector)"
require_contains \
    'cannot create directories: Read-only' \
    "znh_pm_is_readonly_fs_output_file does not match the libdnf5 'cannot create directories: Read-only' message"
# Original regex base must stay in place for backward compatibility.
require_contains \
    'read-only file system' \
    "znh_pm_is_readonly_fs_output_file regex no longer matches the canonical 'read-only file system' marker"
require_contains \
    'EROFS' \
    "znh_pm_is_readonly_fs_output_file regex no longer matches the EROFS errno marker"
require_contains \
    'cannot create directories: Read-only' \
    "znh_pm_is_readonly_fs_output_file regex no longer matches the libdnf5 'cannot create directories: Read-only' marker"
# Widened dnf5/libdnf5 wording variants must also be present (see
# changelog entry for the readonly-fs taxonomy expansion).
require_contains \
    'mkstemp.*read-only' \
    "znh_pm_is_readonly_fs_output_file is missing the 'mkstemp.*read-only' dnf5 wording variant"
require_contains \
    'mkdir.*read-only' \
    "znh_pm_is_readonly_fs_output_file is missing the 'mkdir.*read-only' dnf5 wording variant"
require_contains \
    'failed to create.*read-only' \
    "znh_pm_is_readonly_fs_output_file is missing the 'failed to create.*read-only' generic-write wording"
require_contains \
    'unable to create.*read-only' \
    "znh_pm_is_readonly_fs_output_file is missing the 'unable to create.*read-only' wording variant"
require_contains \
    'permission denied.*read-only' \
    "znh_pm_is_readonly_fs_output_file is missing the 'permission denied.*read-only' wording variant"
require_contains \
    'read-only filesystem' \
    "znh_pm_is_readonly_fs_output_file is missing the lowercase 'read-only filesystem' spelling"
require_contains \
    'errno=30' \
    "znh_pm_is_readonly_fs_output_file is missing the EROFS errno=30 numeric marker"

# --- 2) Benign "no updates" detector helper exists with per-PM patterns ---
require_contains \
    'znh_pm_is_benign_no_updates_output_file() {' \
    "Missing helper znh_pm_is_benign_no_updates_output_file (benign no-op detector)"
require_contains \
    'nothing to do|no packages marked for update|package(s)? already installed|all packages are up to date|nothing provides|transaction is empty' \
    "Benign-detector dnf branch is missing expected 'nothing to do' patterns"
require_contains \
    '0 upgraded, 0 newly installed, 0 to remove' \
    "Benign-detector apt branch is missing the canonical apt 'nothing changed' summary pattern"
require_contains \
    'there is nothing to do|nothing to do| up to date|target not found' \
    "Benign-detector pacman branch is missing the expected 'nothing to do/up to date' patterns"
# Guard: must NEVER classify as benign when stderr also contains real solver markers.
require_contains \
    'conflict|conflicts|conflicting requests|problem:|has inferior architecture|nothing provides|solver|signature verification failed|gpg|repo refresh failed|metadata download failed|404|not found|forbidden|bad gateway|unable to find a match|no match for argument|cannot prepare internal mirrorlist|error: failed' \
    "Benign-detector is missing the failure-marker guard (must reject err_files that look like real failures)"

# --- 3) New shared classifier helper exists and writes the right statuses ---
require_contains \
    'znh_downloader_classify_download_failure() {' \
    "Missing helper znh_downloader_classify_download_failure (shared status classifier)"
# The canonical status strings the classifier must be able to produce.
require_contains \
    'znh_downloader_write_status "complete:0:0"' \
    "Classifier does not write 'complete:0:0' for benign no-op exits"
# Read-only sandbox failures now use a structured `error:repo:readonly_fs`
# subkind so the WebUI body can mention `ReadWritePaths=` and the AI Smart
# Report can key off `error_kind=readonly_fs` directly. Generic `error:repo`
# (no subkind) must remain for non-readonly_fs runtime errors.
require_contains \
    'znh_downloader_write_status "error:repo:readonly_fs"' \
    "Classifier read-only branch must write the structured 'error:repo:readonly_fs' status (not the bare 'error:repo')"
require_contains \
    'znh_downloader_write_status "error:repo"' \
    "Classifier still needs to produce 'error:repo' (generic non-readonly_fs / non-solver runtime errors fall-through)"
require_contains \
    'znh_downloader_write_status "error:network"' \
    "Classifier does not produce 'error:network' (DNS/connect/repo-metadata fetch failures)"
require_contains \
    'znh_downloader_write_status "error:solver:${rc}"' \
    "Classifier does not produce 'error:solver:\${rc}' for actual solver/conflict failures"
# The classifier MUST mention ReadWritePaths in the read-only message so the
# user has a self-diagnose hint.
require_contains \
    'check ReadWritePaths= on the systemd unit' \
    "Classifier read-only branch is missing the 'check ReadWritePaths=' user hint"

# --- 3a) Structured error_kind taxonomy emitted into downloader-events.log ---
# The AI Smart Report's repair-plan catalog now keys off `error_kind=...`
# directly (instead of re-parsing free-form `status=` strings). The shell
# side maps the status to the taxonomy via znh_downloader_status_to_error_kind.
require_contains \
    'znh_downloader_status_to_error_kind() {' \
    "Missing helper znh_downloader_status_to_error_kind (status -> error_kind taxonomy mapper)"
require_contains \
    'error:repo:readonly_fs|error:repo:readonly-fs)' \
    "znh_downloader_status_to_error_kind does not map error:repo:readonly_fs to the readonly_fs taxonomy"
require_contains \
    "printf '%s' 'readonly_fs'" \
    "znh_downloader_status_to_error_kind does not emit the 'readonly_fs' error_kind value"
# Emit-event line must include the structured error_kind field after the
# legacy code= field so consumers (AI Smart Report / log scrapers) get an
# explicit taxonomy slot without re-parsing the status string.
require_contains \
    'line="DOWNLOADER_EVENT ts=${ts} level=${level} pm=${SYSTEM_PKG_MANAGER} event=${event} status=${status} code=${code} error_kind=${error_kind} incident_id=${incident_id} message=' \
    "DOWNLOADER_EVENT log line must include the structured error_kind=... field"
# znh_downloader_write_status must derive + forward the error_kind to the
# emitter so every status write produces the taxonomy field, not just the
# explicit classifier path.
require_contains \
    'error_kind="$(znh_downloader_status_to_error_kind "${status}")"' \
    "znh_downloader_write_status does not derive error_kind from the status string"
require_contains \
    'znh_downloader_emit_event "${level}" "${event}" "${status}" "${message}" "${status#*:}" "${error_kind}"' \
    "znh_downloader_write_status does not forward error_kind into znh_downloader_emit_event"

# --- 3b) AI Smart Report repair-plan catalog learns the readonly_fs class ---
# The Python `_signal_kind_from_line` classifier must recognise the new
# `error_kind=readonly_fs` field and the `error:repo:readonly_fs` status
# string and tag them as the new `downloader-readonly-fs` incident kind so
# the repair-plan catalog can route them to the `verify` action (which is
# what actually rewrites ReadWritePaths= on the deployed systemd unit).
require_contains \
    'if ("error_kind=readonly_fs" in l)' \
    "AI signal classifier does not recognise the structured error_kind=readonly_fs field"
require_contains \
    'return "downloader-readonly-fs"' \
    "AI signal classifier does not return the new 'downloader-readonly-fs' incident kind"
require_contains \
    '"downloader-readonly-fs": 78,' \
    "AI incident impact_by_kind table is missing the 'downloader-readonly-fs' weight"
require_contains \
    '"id": "downloader-readonly-fs",' \
    "AI repair-plan catalog is missing the 'downloader-readonly-fs' entry"
require_contains \
    '"incident_kinds": ["downloader-readonly-fs"],' \
    "AI repair-plan catalog 'downloader-readonly-fs' entry is not bound to the new incident kind"

# --- 4) The prefetch runner exposes the err_file to the caller ---
require_contains \
    'znh_downloader_run_prefetch_download() {' \
    "znh_downloader_run_prefetch_download helper is missing"
require_contains \
    'local out_var_name="$1"' \
    "znh_downloader_run_prefetch_download does not accept the rc out-var (1st arg)"
require_contains \
    'local out_err_var_name="${2:-}"' \
    "znh_downloader_run_prefetch_download does not accept the optional err_file out-var (2nd arg)"
# The function must NOT auto-delete the err_file when the caller wants to inspect it.
require_contains \
    'printf -v "${out_err_var_name}" '"'"'%s'"'"' "${dl_err}"' \
    "znh_downloader_run_prefetch_download does not pass the err_file path back to the caller via the optional 2nd arg"

# --- 5) Cross-distro flow + zypper flow + distro-upgrade prefetch route through the classifier ---
# We expect at least 3 invocations of the classifier (cross-distro + zypper + distro-upgrade).
classifier_call_count="$(grep -c -- 'znh_downloader_classify_download_failure' "${TARGET_FILE}" || true)"
if [ "${classifier_call_count:-0}" -lt 4 ]; then
    # 1 definition + 3 invocations = 4 minimum. Be conservative: <4 is a regression.
    record_failure "Expected the classifier to be defined once and invoked from 3 flows (cross-distro / zypper / distro-upgrade); found ${classifier_call_count:-0} occurrences (need >=4)"
fi

# Cross-distro flow: must invoke the classifier with an err_file and stop using the legacy blanket write.
require_contains \
    'znh_downloader_run_prefetch_download ZYP_RET DL_ERR_FILE' \
    "Cross-distro flow does not capture DL_ERR_FILE alongside ZYP_RET"
require_contains \
    'znh_downloader_classify_download_failure "prefetch download" "${ZYP_RET}" "${DL_ERR_FILE}"' \
    "Cross-distro flow does not route the failure through znh_downloader_classify_download_failure"

# Distro-upgrade prefetch must also use the classifier on rc!=0.
require_contains \
    'znh_downloader_classify_download_failure "distro-upgrade prefetch (Fedora ${version_id:-?} -> ${target})" "${du_rc}" "${du_err}"' \
    "Distro-upgrade prefetch failure path does not route through znh_downloader_classify_download_failure"

# Negative: the legacy blanket 'error:solver:$ZYP_RET' write must no longer
# appear in the cross-distro success/failure code path. (The classifier is now
# responsible for writing 'error:solver:${rc}' only when stderr actually shows
# solver/conflict markers.)
unexpected_blanket="$(grep -c -- 'znh_downloader_write_status "error:solver:$ZYP_RET"' "${TARGET_FILE}" || true)"
if [ "${unexpected_blanket:-0}" -gt 0 ]; then
    record_failure "Legacy blanket 'znh_downloader_write_status \"error:solver:\$ZYP_RET\"' write is still present (use znh_downloader_classify_download_failure instead)"
fi
# Same for the distro-upgrade legacy blanket write.
unexpected_du_blanket="$(grep -c -- 'znh_downloader_write_status "error:solver:${du_rc}"' "${TARGET_FILE}" || true)"
if [ "${unexpected_du_blanket:-0}" -gt 0 ]; then
    record_failure "Legacy blanket distro-upgrade 'znh_downloader_write_status \"error:solver:\${du_rc}\"' write is still present (use znh_downloader_classify_download_failure instead)"
fi

# --- 6) Deployed downloader unit ReadWritePaths now includes the libdnf5 staging dirs ---
require_contains \
    '-/usr/lib/sysimage/libdnf5 -/usr/lib/sysimage/libdnf5/offline' \
    "Deployed zypper-autodownload.service ReadWritePaths= is missing the dnf5 libdnf5 offline staging dirs (required for distro-upgrade prefetch under ProtectSystem=full)"

# --- 7) Verify auto-repair Check 10c rewrite line also includes the libdnf5 staging dirs ---
# The full expected rewrite string lives on a single line as `dl_expected_rw=...`.
require_contains \
    'dl_expected_rw="ReadWritePaths=/var/log/zypper-auto -/var/cache/zypp -/var/cache/zypp/packages -/var/cache/dnf -/var/cache/libdnf5 -/var/cache/apt -/var/cache/apt/archives -/var/cache/pacman/pkg -/var/lib/dnf -/var/lib/apt -/var/lib/apt/lists -/var/lib/pacman -/var/lib/dpkg -/var/lib/zypp -/var/lib/zypper -/var/lib/zypper-auto -/usr/lib/sysimage/libdnf5 -/usr/lib/sysimage/libdnf5/offline"' \
    "Verify auto-repair (Check 10c) dl_expected_rw line is missing the libdnf5 staging dirs"

# --- 8) Auto-repair trigger now ALSO fires when libdnf5 paths are missing entirely ---
# Prior builds only triggered when an UNPREFIXED distro path was found. Older
# installs that already had the optional-prefix paths but lacked libdnf5 would
# never self-heal. The fix adds an explicit "missing libdnf5" trigger.
require_contains \
    "! printf '%s\\n' \"\${dl_existing}\" | grep -qF '/usr/lib/sysimage/libdnf5'" \
    "Verify auto-repair Check 10c does not trigger when the deployed unit is missing the libdnf5 staging dirs"

# --- 9) bash -n syntax check ---
if ! bash -n "${TARGET_FILE}" 2>/dev/null; then
    record_failure "bash -n syntax check failed for ${TARGET_FILE}"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: downloader prefetch error classification + libdnf5 sandbox path wiring intact"
