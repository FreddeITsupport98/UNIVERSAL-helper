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
Usage: ./test_webui_poll_parse_recovery_regression.sh [path/to/UNI-auto.sh]

Focused static regression for WebUI pollLive parse recovery:
  - parse warnings are throttled
  - status-data.json parse failure retries once with cache-busting fetch
  - pollLive reuses a bounded last-good snapshot on repeated parse/read failures
  - network notification copy distinguishes parse/read failures from generic API/network failures
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

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if grep -Fq -- "${needle}" <<< "${haystack}"; then
        record_failure "${label} (unexpected: ${needle})"
    fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ ! -f "${TARGET_FILE}" ]; then
    record_failure "Target file not found: ${TARGET_FILE}"
fi

source_text=""
if [ -f "${TARGET_FILE}" ]; then
    source_text="$(cat -- "${TARGET_FILE}")"
fi

# pollLive parse retry + last-good fallback primitives
assert_contains "${source_text}" "var _pollLiveLastGoodData = null;" "missing pollLive last-good cache data variable"
assert_contains "${source_text}" "var _pollLiveLastGoodTs = 0;" "missing pollLive last-good cache timestamp variable"
assert_contains "${source_text}" "var _pollLiveParseWarnLastMs = 0;" "missing pollLive parse warning throttle state"
assert_contains "${source_text}" "function _pollLiveWarnParse(msg) {" "missing pollLive parse warning helper"
assert_contains "${source_text}" "(nowMs - _pollLiveParseWarnLastMs) < 12000" "missing pollLive parse warning throttle interval"

assert_contains "${source_text}" "var retryUrl = 'status-data.json?ts=' + Date.now() + '&retry=1';" "missing pollLive retry URL"
assert_contains "${source_text}" "return znhFetch(retryUrl, { cache: 'no-store' })" "missing pollLive retry fetch call"
assert_contains "${source_text}" "var p2 = _parsePayload(txt2, 'pollLive(retry)');" "missing pollLive retry parse label"
assert_contains "${source_text}" "_pollLiveWarnParse('pollLive recovered after retrying status-data.json fetch');" "missing retry recovery warning"
assert_contains "${source_text}" "_pollLiveWarnParse('pollLive using cached last-good status snapshot after parse failure');" "missing cached fallback warning after retry parse failure"
assert_contains "${source_text}" "_pollLiveWarnParse('pollLive retry failed; reusing cached last-good status snapshot');" "missing cached fallback warning after retry fetch failure"
assert_contains "${source_text}" "ageMs < (15 * 60 * 1000)" "missing bounded cache age check for parse fallback"
assert_contains "${source_text}" "ageMs2 < (15 * 60 * 1000)" "missing bounded cache age check for retry-failure fallback"
assert_contains "${source_text}" "_pollLiveLastGoodData = d;" "missing cache update for successful pollLive payload"
assert_contains "${source_text}" "_pollLiveLastGoodTs = Date.now();" "missing cache timestamp update for successful pollLive payload"
assert_contains "${source_text}" "var baseErr = _formatParseError(p1);" "missing pollLive parse error base composition"
assert_contains "${source_text}" "throw new Error(baseErr + ' | retry: ' + reMsg);" "missing pollLive retry error composition"

# Parse-specific notification copy should stay explicit and avoid token-mismatch wording.
assert_contains "${source_text}" "var parseLike = false;" "missing parse-like error classifier state"
assert_contains "${source_text}" "parseLike = /JSON\\.parse|JSON parse|unexpected token|expected ','|status-data\\.json JSON parse failed|snippet:/i.test(err);" "missing parse-like classifier regex"
assert_contains "${source_text}" "if (parseLike || src === 'pollLive' || url.indexOf('status-data.json') !== -1) {" "missing parse-like notification branch"
assert_contains "${source_text}" "Live status refresh failed to read status-data.json (invalid or partial JSON). This is usually temporary during file refresh." "missing parse-specific status-data notification copy"
assert_not_contains "${source_text}" "A WebUI request failed. This is usually temporary (API restart, token mismatch, network hiccup)." "stale token-mismatch generic copy should not be present"

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: pollLive parse-recovery regression checks passed"
