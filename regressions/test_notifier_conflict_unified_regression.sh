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
Usage: ./test_notifier_conflict_unified_regression.sh [path/to/UNI-auto.sh]

Static regression for the unified cross-distro notifier conflict UX:
  - Notifier carries its own _conflict_guidance helper that mirrors the
    Dashboard API helper (single source of truth for headline, explanation,
    recommended command, refresh command, terminal_only flag, solver_choices,
    steps, manager_hint).
  - error:repo and error:solver: branches build per-PM messages from the
    shared helper output instead of inline zypper-only strings.
  - error:repo branch surfaces an "Open Terminal" action that runs the
    PM-aware refresh command directly via _open_terminal_with_command.
  - error:solver: branch switches the "Install Now" action by terminal_only:
    on apt/dnf/pacman it offers "Open Terminal" with the recommended command;
    on zypper it keeps the existing zypper-run-install Install Now flow
    AND adds an additional Open Terminal shortcut.
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

# Notifier owns its mirrored guidance helper + terminal launcher.
assert_contains "${source_text}" 'def _conflict_guidance(surface: str = "notifier"' "notifier missing _conflict_guidance helper (mirrors Dashboard API)"
assert_contains "${source_text}" 'def _open_terminal_with_command(' "notifier missing _open_terminal_with_command helper"
assert_contains "${source_text}" 'systemd-run' "notifier _open_terminal_with_command should detach via systemd-run --user --scope"

# Both error:repo and error:solver: branches expose Open Terminal action.
assert_contains "${source_text}" 'elif status.startswith("error:repo"):' "notifier missing error:repo branch"
assert_contains "${source_text}" 'elif status.startswith("error:solver:"):' "notifier missing error:solver branch"
assert_contains "${source_text}" 'n.add_action("open-terminal", "Open Terminal", on_action, refresh_cmd)' "notifier error:repo branch missing PM-aware Open Terminal action"
assert_contains "${source_text}" 'n.add_action("open-terminal", "Open Terminal", on_action, recommended_cmd)' "notifier error:solver branch missing PM-aware Open Terminal action"

# error:solver: builds its message from the shared guidance helper.
assert_contains "${source_text}" 'guidance = _conflict_guidance(' "notifier error:solver branch is not consuming _conflict_guidance"
assert_contains "${source_text}" 'terminal_only = bool(guidance.get("terminal_only"))' "notifier error:solver branch is not reading terminal_only from guidance"
assert_contains "${source_text}" 'recommended_cmd = guidance.get("recommended_cmd")' "notifier error:solver branch is not reading recommended_cmd from guidance"
assert_contains "${source_text}" 'manager_hint = guidance.get("manager_hint")' "notifier error:solver branch is not reading manager_hint from guidance"

# Install Now action is gated to non-terminal_only (zypper) and Open Terminal is offered alongside.
assert_contains "${source_text}" 'if terminal_only:' "notifier error:solver branch is not branching on terminal_only for actions"
assert_contains "${source_text}" 'n.add_action("install", "Install Now", on_action, action_script)' "notifier error:solver branch missing zypper Install Now action"

# on_action handler must understand the open-terminal action.
assert_contains "${source_text}" '"open-terminal"' "notifier on_action handler missing open-terminal dispatch"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: notifier unified cross-distro conflict UX regression checks passed"
