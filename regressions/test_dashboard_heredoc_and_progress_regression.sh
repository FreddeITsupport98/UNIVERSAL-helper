#!/usr/bin/env bash
set -euo pipefail

# Focused regression to prevent three recurrent bugs:
#
# 1. "bad substitution" crash in generate_dashboard():
#    The dashboard HTML heredoc uses unquoted <<EOF, so bash expands all ${}.
#    JS-style ternary expressions like ${x == 'y' ? a : b} inside the heredoc
#    crash bash with "bad substitution" and abort the entire install.
#    Guard: no unescaped ${...} in the heredoc should contain == ? : operators.
#
# 2. Substring matching bug in _job_update_progress():
#    "[webui] stage: post-install" matches "[webui] stage: post-install-done"
#    because the former is a substring. The -done variants must be checked FIRST
#    in the if/elif chain.
#
# 3. Progress >100 leaking to UI:
#    Post-action progress values (101+) must be clamped when done=true.
#    The recovery function must handle the done + progress>=100 case.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

FAILS=0
FAILED_NAMES=()

fail() {
    FAILS=$((FAILS + 1))
    FAILED_NAMES+=("$1")
    printf 'FAIL: %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: ./test_dashboard_heredoc_and_progress_regression.sh [path/to/UNI-auto.sh]

Guards against:
  - bad substitution crash in dashboard HTML heredoc (JS ternary inside bash ${})
  - substring matching bug in post-install progress parser
  - 101%+ progress leaking to WebUI when job is done
EOF
    exit 0
fi

[ -f "${TARGET_FILE}" ] || { fail "Target file not found: ${TARGET_FILE}"; exit 1; }

# =========================================================================
# 1. Dashboard heredoc: no JS ternary operators inside unescaped ${}
# =========================================================================
# Extract the dashboard HTML heredoc body (between <<EOF and the closing EOF).
# The heredoc starts at: write_atomic "${out_root}" <<EOF
# and ends at a line that is just: EOF
# Within that block, find any ${...} that contains == or ? : (JS ternary syntax).

# Get line numbers of the heredoc boundaries
heredoc_start=$(grep -n 'write_atomic "${out_root}" <<EOF' "${TARGET_FILE}" | head -1 | cut -d: -f1)
if [ -z "${heredoc_start:-}" ]; then
    fail "Could not locate dashboard heredoc start (write_atomic \"\${out_root}\" <<EOF)"
else
    # Find the matching EOF line after heredoc_start
    heredoc_end=$(awk -v start="${heredoc_start}" 'NR > start && /^EOF$/ { print NR; exit }' "${TARGET_FILE}")
    if [ -z "${heredoc_end:-}" ]; then
        fail "Could not locate dashboard heredoc end (EOF line)"
    else
        # Extract heredoc body and scan for JS ternary inside ${}
        heredoc_body=$(sed -n "$((heredoc_start+1)),$((heredoc_end-1))p" "${TARGET_FILE}")

        # Pattern: ${...==...} or ${...?...} — JS ternary inside bash ${}
        # These cause "bad substitution" because bash can't parse ==, ?, : inside ${}.
        # Exclude lines that have \${ (escaped dollar) — those are safe.
        # Use grep -P (Perl regex) for reliable matching; fall back to basic grep.
        bad_ternary_lines=$(
            echo "${heredoc_body}" \
            | grep -nP '(?<!\\)\$\{[^}]*(==|\?)[^}]*\}' 2>/dev/null \
            || echo "${heredoc_body}" | grep -n '\${.*==.*}\|\${.*?.*}' | grep -v '\\\${' \
            || true
        )
        if [ -n "${bad_ternary_lines}" ]; then
            fail "Dashboard heredoc contains JS ternary inside \${} (causes 'bad substitution'):"
            echo "${bad_ternary_lines}" | head -5 >&2
        else
            pass "Dashboard heredoc: no JS ternary inside \${} (safe from bad substitution)"
        fi

        # Also check that feat_*_install_class variables are pre-computed before the heredoc
        if grep -q 'feat_flatpak_install_class=' "${TARGET_FILE}"; then
            pass "feat_*_install_class variables are pre-computed (not inline JS ternary)"
        else
            fail "feat_flatpak_install_class not found — feature badge CSS classes must be pre-computed before the heredoc"
        fi
    fi
fi

# =========================================================================
# 2. Post-install progress parser: -done variants checked before base form
# =========================================================================
# In _job_update_progress(), the "-done" markers must appear BEFORE the base
# markers in the if/elif chain. Otherwise "post-install" matches "post-install-done"
# via substring, and the -done branch never fires.

progress_func_block=$(awk '
    /def _job_update_progress\(job: dict, line: str\)/ {inblk=1}
    inblk {
        if (/^[^ ]/ && !/def _job_update_progress/) {exit}
        if (/^def / && !/def _job_update_progress/) {exit}
        print
    }
' "${TARGET_FILE}")

if [ -z "${progress_func_block}" ]; then
    fail "Could not locate _job_update_progress function"
else
    # Get the line numbers (within the block) of each marker check
    post_install_done_line=$(echo "${progress_func_block}" | grep -n 'post-install-done' | head -1 | cut -d: -f1)
    post_install_base_line=$(echo "${progress_func_block}" | grep -n 'stage: post-install' | grep -v 'done\|services\|dashboard' | head -1 | cut -d: -f1)
    post_verify_done_line=$(echo "${progress_func_block}" | grep -n 'post-verify-done' | head -1 | cut -d: -f1)
    post_verify_base_line=$(echo "${progress_func_block}" | grep -n 'stage: post-verify' | grep -v 'done' | head -1 | cut -d: -f1)

    if [ -z "${post_install_done_line:-}" ] || [ -z "${post_install_base_line:-}" ]; then
        fail "Could not find post-install progress markers in _job_update_progress"
    elif [ "${post_install_done_line}" -gt "${post_install_base_line}" ]; then
        fail "post-install-done check appears AFTER post-install check (substring match bug: -done will never fire)"
    else
        pass "post-install-done is checked BEFORE post-install (correct order)"
    fi

    if [ -z "${post_verify_done_line:-}" ] || [ -z "${post_verify_base_line:-}" ]; then
        fail "Could not find post-verify progress markers in _job_update_progress"
    elif [ "${post_verify_done_line}" -gt "${post_verify_base_line}" ]; then
        fail "post-verify-done check appears AFTER post-verify check (substring match bug: -done will never fire)"
    else
        pass "post-verify-done is checked BEFORE post-verify (correct order)"
    fi
fi

# =========================================================================
# 3. Progress clamping: done + progress>=100 must be handled
# =========================================================================
# In _recover_self_update_job(), when done=true and progress is in the
# post-action band (>100), progress must be clamped to 100.
# Without this, the WebUI shows "Failed 101%" or "Done 110%".

recovery_func_block=$(awk '
    /def _recover_self_update_job\(job_id: str\)/ {inblk=1}
    inblk {
        if (/^[^ ]/ && !/def _recover_self_update_job/) {exit}
        if (/^def / && !/def _recover_self_update_job/) {exit}
        print
    }
' "${TARGET_FILE}")

if [ -z "${recovery_func_block}" ]; then
    fail "Could not locate _recover_self_update_job function"
else
    # Must have a branch that handles: done=true AND progress >= 100
    if echo "${recovery_func_block}" | grep -q 'done and progress >= 100'; then
        pass "Recovery function handles done + progress>=100 (clamps post-action band)"
    else
        fail "Recovery function missing 'done and progress >= 100' clamping branch (101% would leak to UI)"
    fi
fi

# =========================================================================
# 4. Systemd job script emits [webui] stage markers for post-actions
# =========================================================================
# The self-update start handler must emit [webui] stage: post-install and
# [webui] stage: post-install-done markers so the progress parser can track them.

su_start_block=$(awk '
    /if path == "\/api\/self-update\/start":/ {inblk=1}
    inblk {
        if (/# Backward-compatible synchronous endpoint/) {exit}
        print
    }
' "${TARGET_FILE}")

if [ -z "${su_start_block}" ]; then
    fail "Could not locate /api/self-update/start block"
else
    if echo "${su_start_block}" | grep -q '\[webui\] stage: post-install'; then
        pass "Self-update job script emits [webui] stage: post-install marker"
    else
        fail "Self-update job script missing [webui] stage: post-install log marker"
    fi

    if echo "${su_start_block}" | grep -q '\[webui\] stage: post-install-done'; then
        pass "Self-update job script emits [webui] stage: post-install-done marker"
    else
        fail "Self-update job script missing [webui] stage: post-install-done log marker"
    fi

    if echo "${su_start_block}" | grep -q '\[webui\] stage: post-verify'; then
        pass "Self-update job script emits [webui] stage: post-verify marker"
    else
        fail "Self-update job script missing [webui] stage: post-verify log marker"
    fi

    if echo "${su_start_block}" | grep -q '\[webui\] stage: post-verify-done'; then
        pass "Self-update job script emits [webui] stage: post-verify-done marker"
    else
        fail "Self-update job script missing [webui] stage: post-verify-done log marker"
    fi
fi

# =========================================================================
# 5. bash -n syntax check (catches bad substitution at parse time)
# =========================================================================
if bash -n "${TARGET_FILE}" 2>/dev/null; then
    pass "bash -n syntax check passed (no bad substitution)"
else
    fail "bash -n syntax check FAILED (likely bad substitution or other parse error)"
fi

# =========================================================================
# Final summary
# =========================================================================
if [ "${FAILS}" -gt 0 ]; then
    echo ""
    echo "========================================"
    echo "  FAIL SUMMARY (${FAILS})"
    echo "========================================"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - ${name}"
    done
    echo "========================================"
    exit 1
fi

echo ""
pass "All dashboard heredoc + progress regression checks passed"
