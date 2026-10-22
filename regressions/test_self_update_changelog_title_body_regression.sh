#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes are intentional throughout this
# file: assertions grep the target for LITERAL unexpanded ${...} JS source strings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_self_update_changelog_title_body_regression.sh [path/to/UNI-auto.sh]

Regression guard for the WebUI changelog fetch (title + commit/release MESSAGE):
  - shared formatters render every entry as header + Title: + Message: body
  - rolling commits keep the FULL commit message body (old code kept only the
    first line); stable lists the candidate release PLUS earlier releases,
    each with its title + message body
  - bodies are indented and bounded (truncation marker), so one huge body
    cannot flood the view
  - every changelog surface uses the shared formatters: the Self-Update
    "Fetch changelog" button, the post-install release-notes views, and the
    welcome overlay release notes
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

count_occurrences() {
    local needle="$1"
    grep -Fc -- "${needle}" "${TARGET_FILE}" 2>/dev/null || printf '0\n'
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

# --- 1) Shared formatter helpers exist ---
require_contains "${source_text}" 'function _suChangelogShortDate(iso) {' "Missing _suChangelogShortDate helper"
require_contains "${source_text}" 'function _suChangelogIndentBody(text, maxChars) {' "Missing _suChangelogIndentBody helper"
require_contains "${source_text}" 'function _suFormatCommitBlock(c, bodyMax) {' "Missing _suFormatCommitBlock helper"
require_contains "${source_text}" 'function _suFormatReleaseBlock(r, bodyMax) {' "Missing _suFormatReleaseBlock helper"

# --- 2) Commit block: TITLE = first line, MESSAGE = full remaining body ---
require_contains "${source_text}" "var title = (lines[0] || '').replace(/^\s+|\s+$/g, '');" "Missing commit title extraction (first line, trimmed)"
require_contains "${source_text}" "var body = lines.slice(1).join('\n');" "Missing commit body retention (lines after the title are KEPT, not discarded)"
require_contains "${source_text}" "out.push('  Title: ' + (title || '(no commit title)'));" "Missing commit 'Title:' render line"
require_contains "${source_text}" "out.push('  Message:');" "Missing 'Message:' render line"
require_contains "${source_text}" 'var ind = _suChangelogIndentBody(body, bodyMax || 900);' "Missing bounded/indented commit body render"
require_contains "${source_text}" '((((c || {}).commit || {}).author || {}).name || ' "Missing commit author.name in the header line"
require_contains "${source_text}" 'dt = _suChangelogShortDate((((c || {}).commit || {}).author || {}).date || ' "Missing commit short-date in the header line"

# --- 3) Old title-only truncation must be gone from every fetch path ---
require_not_contains "${source_text}" "msg = msg.split('\\n')[0];" "Old title-only commit truncation (msg.split newline first-line) still present"
require_not_contains "${source_text}" "out2.push('- ' + sha + (dt ? (' ' + dt) : '') + ' ' + msg);" "Old single-line rolling changelog render still present"

# --- 4) Body bounding + indent + truncation marker ---
require_contains "${source_text}" "t = t.slice(0, n).replace(/\\s+$/, '') + '\\n…(truncated)';" "Missing body truncation marker"
require_contains "${source_text}" "for (var i = 0; i < lines.length; i++) out.push('    ' + lines[i]);" "Missing 4-space body indent"

# --- 5) Release block: title (name/tag) + message (body) ---
require_contains "${source_text}" "out.push('  Title: ' + (name || tag || '(no release title)'));" "Missing release 'Title:' render line (name with tag fallback)"
require_contains "${source_text}" "out.push('  Message: (no release notes)');" "Missing release empty-body fallback message"
require_contains "${source_text}" "(r.prerelease ? '  (prerelease)' : '')" "Missing release prerelease marker in the header line"
require_contains "${source_text}" 'var ind = _suChangelogIndentBody(body, bodyMax || 4000);' "Missing bounded release body render"

# --- 6) Multi-release listing: candidate + earlier releases ---
require_contains "${source_text}" 'releases: candidates,' "Missing releases (candidate list) in _suSelectStableReleaseCandidate return"
require_contains "${source_text}" "'Earlier releases (title + message each):'" "Missing 'Earlier releases' section label"
_earlier_count="$(count_occurrences "'Earlier releases (title + message each):'")"
if [ "${_earlier_count}" -lt 2 ] 2>/dev/null; then
    record_failure "Earlier-releases section must exist in BOTH the shared stable fetcher and the Fetch-changelog button path (found: ${_earlier_count})"
fi
require_contains "${source_text}" 'for (var sri = 1; sri < rest.length && sri <= 5; sri++)' "Missing earlier-releases loop in the Fetch-changelog stable path (max 5)"
require_contains "${source_text}" "out.push(_suFormatReleaseBlock(j, 4000));" "Missing candidate release block render (Fetch-changelog stable path)"

# --- 7) Both Fetch-changelog paths use the shared formatters ---
require_contains "${source_text}" "arr.forEach(function(c) {
                out2.push(_suFormatCommitBlock(c, 900));
            });" "Missing _suFormatCommitBlock usage in the Fetch-changelog rolling path"
require_contains "${source_text}" 'out.push(_suFormatCommitBlock(c, 900));' "Missing _suFormatCommitBlock usage in a rolling path"

# --- 8) Shared fetchers updated too (post-install + welcome surfaces) ---
require_contains "${source_text}" 'arr.forEach(function(c) {
                out.push(_suFormatCommitBlock(c, 900));
            });' "Missing _suFormatCommitBlock usage in _suFetchRollingCommitsText"
require_contains "${source_text}" "out.push('Rolling channel (latest commits on main — title + commit message)');" "Missing updated rolling header (title + commit message)"
require_contains "${source_text}" 'var rest = (sel && sel.releases && sel.releases.length) ? sel.releases : [];' "Missing releases list usage in a stable fetcher"

# --- 9) Post-install / welcome surfaces still route through the shared fetchers ---
require_contains "${source_text}" "var fetchNotes = (ch === 'rolling') ? _suFetchRollingCommitsText : _suFetchStableReleaseNotesText;" "Missing shared-fetcher routing in the welcome/post-install release-notes surface"

# --- 10) Robustness: non-array GitHub responses still handled in the changelog paths ---
require_contains "${source_text}" "out2.push('ERROR: ' + msgRA);" "Missing non-array error handling in the Fetch-changelog rolling path"

# --- 11) Bash syntax sanity of the target file ---
if ! bash -n "${TARGET_FILE}" >/dev/null 2>&1; then
    record_failure "Target file fails bash -n syntax check: ${TARGET_FILE}"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: self-update changelog title + commit/release message regression checks passed"
