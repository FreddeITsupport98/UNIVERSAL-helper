#!/usr/bin/env bash
# RUNNER_NEEDS_TARGET=0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_cross_distro_conflict_ux_regression.sh [path/to/UNI-auto.sh]

Static regression for the cross-distro conflict guidance UX:
  - Embedded Dashboard API exposes a single _conflict_guidance helper used as
    the source of truth for the WebUI overlay and (mirrored) for the notifier.
  - GET /api/system/conflict-guidance route exists.
  - /api/system/dup/preview, /api/system/dup/job and the recovery payloads
    embed conflict_guidance alongside conflict_detected/conflict_summary.
  - _ruRenderPreview and _ruRenderDone read payload.package_manager and
    payload.conflict_guidance, gate the zypper-only solver button row, and
    surface a per-PM "Open terminal" CTA on apt/dnf/pacman.
EOF
}

FAILURES=()

record_failure() {
    local msg="$1"
    FAILURES+=("${msg}")
}

assert_contains() {
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

# Backend: shared guidance helper + endpoint.
assert_contains "${source_text}" 'def _conflict_guidance(' "missing _conflict_guidance helper in embedded dashboard API"
assert_contains "${source_text}" "/api/system/conflict-guidance" "missing GET /api/system/conflict-guidance route"
assert_contains "${source_text}" '"recommended_cmd"' "guidance helper missing recommended_cmd field"
assert_contains "${source_text}" '"refresh_cmd"' "guidance helper missing refresh_cmd field"
assert_contains "${source_text}" '"terminal_only"' "guidance helper missing terminal_only field"
assert_contains "${source_text}" '"solver_choices"' "guidance helper missing solver_choices field"
assert_contains "${source_text}" '"manager_hint"' "guidance helper missing manager_hint field"

# Backend: dup endpoints carry conflict_guidance.
assert_contains "${source_text}" '"conflict_guidance"' "dup endpoint payloads do not carry conflict_guidance"

# Frontend: PM-aware overlays read package_manager + conflict_guidance from
# their input objects (`p` for preview, `opts` for done).
assert_contains "${source_text}" "function _ruRenderPreview" "missing _ruRenderPreview overlay renderer"
assert_contains "${source_text}" "function _ruRenderDone" "missing _ruRenderDone overlay renderer"
assert_contains "${source_text}" "p.conflict_guidance" "_ruRenderPreview does not consume p.conflict_guidance"
assert_contains "${source_text}" "p.package_manager" "_ruRenderPreview does not consume p.package_manager"
assert_contains "${source_text}" "opts.conflict_guidance" "_ruRenderDone does not consume opts.conflict_guidance"
assert_contains "${source_text}" "opts.package_manager" "_ruRenderDone does not consume opts.package_manager"

# Solver button row + zypper-only behaviour must be gated by pm === 'zypper'.
assert_contains "${source_text}" "isZypperPm = (pmName === 'zypper')" "_ruRenderPreview missing isZypperPm gate (pm === 'zypper')"
assert_contains "${source_text}" "isZypperDone = (pmDone === 'zypper')" "_ruRenderDone missing isZypperDone gate (pm === 'zypper')"

# PM helper for copy-and-toast (Open terminal CTA flow).
assert_contains "${source_text}" "_ruPmCopyAndToast" "missing _ruPmCopyAndToast helper for non-zypper Open terminal CTA"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: cross-distro conflict UX regression checks passed"
