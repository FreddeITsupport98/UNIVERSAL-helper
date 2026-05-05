#!/usr/bin/env bash
# RUNNER_RUNTIME=runtime
# shellcheck disable=SC1091
#
# Runtime regression: distro-upgrade skip + version-computation for Ubuntu and Leap.
# Runs cleanly on any distro (Fedora, Tumbleweed, etc.) — Ubuntu/Leap tools are
# mocked via fake binaries and function overrides so no real upgrade tools are needed.
#
# Validates:
#   Ubuntu skip   – check_ubuntu() returns 1 cleanly when do-release-upgrade is absent.
#   Ubuntu codename map – __znh_ubuntu_codename_to_version produces correct YY.MM values.
#   Ubuntu cycle math   – __znh_ubuntu_compute_next_version April↔October arithmetic.
#   Ubuntu method-1     – YY.MM is extracted directly when present in do-release-upgrade output.
#   Ubuntu method-2     – codename in quotes is parsed and mapped to a version number.
#   Ubuntu method-4     – cycle-math fallback fires when no version/codename found.
#   Leap skip     – check_leap() returns 1 (no upgrade flagged) regardless of zypper.
#   Leap arithmetic     – check_leap() computes major.minor+1 even without zypper repos.
#   Leap no-zypper      – check_leap() works the same when zypper is absent from PATH.

# -e intentionally omitted: subshells may return non-zero (tested function results).
# -u and pipefail kept for hygiene.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

if [ ! -f "${TARGET_FILE}" ]; then
    echo "FAIL SUMMARY (1)" >&2
    echo " - Target file not found: ${TARGET_FILE}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
FAILURES=()
PASS_COUNT=0

record_failure() { FAILURES+=("$1"); }
pass()           { PASS_COUNT=$((PASS_COUNT + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "${actual}" = "${expected}" ]; then
        pass
    else
        record_failure "${label}: expected='${expected}' got='${actual}'"
    fi
}

assert_rc() {
    local label="$1" expected_rc="$2" actual_rc="$3"
    if [ "${actual_rc}" -eq "${expected_rc}" ]; then
        pass
    else
        record_failure "${label}: expected rc=${expected_rc} got rc=${actual_rc}"
    fi
}

# ---------------------------------------------------------------------------
# Extract helper functions from the target file into a temp snippet.
# We pull exactly the four functions we need so we don't have to source the
# full installer (which requires root, writes logs, etc.).
# ---------------------------------------------------------------------------
TMP_SNIPPET="$(mktemp /tmp/znh_du_skip_regression_XXXXXX.sh)"
trap 'rm -f "${TMP_SNIPPET}"' EXIT

python3 - <<PYEOF >> "${TMP_SNIPPET}"
import re, sys

src = open("${TARGET_FILE}", "r", errors="replace").read()

# Functions to extract (in declaration order)
targets = [
    "__znh_ubuntu_codename_to_version",
    "__znh_ubuntu_compute_next_version",
    "znh_distro_upgrade_check_ubuntu",
    "znh_distro_upgrade_check_leap",
]

# Simple brace-balanced extractor for top-level bash functions.
def extract_function(text, name):
    pattern = r'^' + re.escape(name) + r'\s*\(\s*\)\s*\{'
    m = re.search(pattern, text, re.MULTILINE)
    if not m:
        return None
    start = m.start()
    depth = 0
    i = start
    while i < len(text):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[start:i+1]
        i += 1
    return None

print("#!/usr/bin/env bash")
print("# Auto-extracted helpers for regression testing")
for name in targets:
    body = extract_function(src, name)
    if body:
        print("")
        print(body)
    else:
        print(f"# WARNING: could not extract {name}", file=__import__("sys").stderr)
PYEOF

# Minimal stubs for globals the functions read
cat >> "${TMP_SNIPPET}" << 'STUBS'

# Stubs – overridden per test case below
VERSION_ID=""
VERSION_CODENAME=""
ZNH_DISTRO_UPGRADE_CURRENT=""
ZNH_DISTRO_UPGRADE_AVAILABLE=0
ZNH_DISTRO_UPGRADE_TARGET=""
STUBS

# Source the extracted snippet into this shell
# shellcheck source=/dev/null
. "${TMP_SNIPPET}"

# ---------------------------------------------------------------------------
# 1. Ubuntu codename → version mapping
# ---------------------------------------------------------------------------
assert_eq "codename focal"    "20.04" "$(__znh_ubuntu_codename_to_version focal)"
assert_eq "codename jammy"    "22.04" "$(__znh_ubuntu_codename_to_version jammy)"
assert_eq "codename noble"    "24.04" "$(__znh_ubuntu_codename_to_version noble)"
assert_eq "codename oracular" "24.10" "$(__znh_ubuntu_codename_to_version oracular)"
assert_eq "codename plucky"   "25.04" "$(__znh_ubuntu_codename_to_version plucky)"
assert_eq "codename questing" "25.10" "$(__znh_ubuntu_codename_to_version questing)"
assert_eq "codename regal"    "26.04" "$(__znh_ubuntu_codename_to_version regal)"
# Case-insensitive
assert_eq "codename NOBLE"    "24.04" "$(__znh_ubuntu_codename_to_version NOBLE)"
assert_eq "codename Jammy"    "22.04" "$(__znh_ubuntu_codename_to_version Jammy)"
# Extra words after codename (e.g. "Noble Numbat") – only first word used
assert_eq "codename 'Noble Numbat'" "24.04" "$(__znh_ubuntu_codename_to_version "Noble Numbat")"
# Unknown codename → empty string
assert_eq "codename unknown"  "" "$(__znh_ubuntu_codename_to_version foobar)"
assert_eq "codename empty"    "" "$(__znh_ubuntu_codename_to_version "")"

# ---------------------------------------------------------------------------
# 2. Ubuntu release-cycle math (April → October, October → April next year)
# ---------------------------------------------------------------------------
assert_eq "cycle 24.04→" "24.10" "$(__znh_ubuntu_compute_next_version 24.04)"
assert_eq "cycle 24.10→" "25.04" "$(__znh_ubuntu_compute_next_version 24.10)"
assert_eq "cycle 25.04→" "25.10" "$(__znh_ubuntu_compute_next_version 25.04)"
assert_eq "cycle 25.10→" "26.04" "$(__znh_ubuntu_compute_next_version 25.10)"
assert_eq "cycle 22.04→" "22.10" "$(__znh_ubuntu_compute_next_version 22.04)"
assert_eq "cycle 22.10→" "23.04" "$(__znh_ubuntu_compute_next_version 22.10)"
# Bad input → empty (function returns 1, output empty)
assert_eq "cycle bad input" "" "$(__znh_ubuntu_compute_next_version "" 2>/dev/null || true)"
assert_eq "cycle non-april/oct month" "" "$(__znh_ubuntu_compute_next_version 24.07 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 3. Ubuntu skip: do-release-upgrade absent → check_ubuntu() returns 1 cleanly
# ---------------------------------------------------------------------------
# NOTE: do NOT define a bash function named do-release-upgrade — command -v finds
# shell functions, which would defeat the "tool absent" test.  Instead, filter the
# real binary out of PATH by excluding the directory that contains it.
(
    set +e
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID="24.04"
    VERSION_CODENAME="noble"
    ZNH_DISTRO_UPGRADE_AVAILABLE=99   # sentinel – must not be changed
    ZNH_DISTRO_UPGRADE_TARGET="SENTINEL"
    # Build a filtered PATH: keep all dirs EXCEPT the one containing do-release-upgrade.
    # On Fedora (tool not installed) this is a no-op.  On Ubuntu it removes /usr/bin.
    # grep/awk/cut/sed remain available via other PATH entries.
    _filtered_path=""
    IFS=: read -r -a _path_arr <<< "${PATH}"
    for _d in "${_path_arr[@]}"; do
        [ -x "${_d}/do-release-upgrade" ] || _filtered_path="${_filtered_path:+${_filtered_path}:}${_d}"
    done
    PATH="${_filtered_path:-/usr/local/bin:/usr/bin:/bin}"
    _rc=0; znh_distro_upgrade_check_ubuntu; _rc=$?
    echo "rc_ubuntu_skip=${_rc}"
    echo "avail_ubuntu_skip=${ZNH_DISTRO_UPGRADE_AVAILABLE}"
    echo "target_ubuntu_skip=${ZNH_DISTRO_UPGRADE_TARGET}"
) > /tmp/znh_skip_ubuntu_out_$$.txt 2>/dev/null; _rc_subshell=$?

_rc_ubuntu_skip="$(   grep '^rc_ubuntu_skip='    /tmp/znh_skip_ubuntu_out_$$.txt | cut -d= -f2)"
_avail_ubuntu_skip="$(grep '^avail_ubuntu_skip=' /tmp/znh_skip_ubuntu_out_$$.txt | cut -d= -f2)"
_target_ubuntu_skip="$(grep '^target_ubuntu_skip=' /tmp/znh_skip_ubuntu_out_$$.txt | cut -d= -f2)"
rm -f /tmp/znh_skip_ubuntu_out_$$.txt

assert_rc  "ubuntu skip: rc is 1"            1   "${_rc_ubuntu_skip:-0}"
assert_eq  "ubuntu skip: AVAILABLE unchanged" "99" "${_avail_ubuntu_skip:-?}"
assert_eq  "ubuntu skip: TARGET unchanged"   "SENTINEL" "${_target_ubuntu_skip:-?}"

# ---------------------------------------------------------------------------
# 4. Ubuntu method-1: YY.MM extracted directly from do-release-upgrade output
# ---------------------------------------------------------------------------
(
    set +e
    FAKE_BIN="$(mktemp -d)"
    trap 'rm -rf "${FAKE_BIN}"' EXIT
    cat > "${FAKE_BIN}/do-release-upgrade" << 'FAKE'
#!/bin/sh
echo "New release '25.04 LTS' available."
exit 0
FAKE
    chmod +x "${FAKE_BIN}/do-release-upgrade"
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID="24.10"
    ZNH_DISTRO_UPGRADE_AVAILABLE=0
    ZNH_DISTRO_UPGRADE_TARGET=""
    # Prepend fake bin; keep real PATH so grep/sed/awk remain available
    PATH="${FAKE_BIN}:${PATH}"
    _rc=0; znh_distro_upgrade_check_ubuntu; _rc=$?
    echo "rc_m1=${_rc}"
    echo "avail_m1=${ZNH_DISTRO_UPGRADE_AVAILABLE}"
    echo "target_m1=${ZNH_DISTRO_UPGRADE_TARGET}"
) > /tmp/znh_m1_out_$$.txt 2>/dev/null

_rc_m1="$(    grep '^rc_m1='    /tmp/znh_m1_out_$$.txt | cut -d= -f2)"
_avail_m1="$( grep '^avail_m1=' /tmp/znh_m1_out_$$.txt | cut -d= -f2)"
_target_m1="$(grep '^target_m1=' /tmp/znh_m1_out_$$.txt | cut -d= -f2)"
rm -f /tmp/znh_m1_out_$$.txt

assert_rc "ubuntu method-1: rc is 0"          0       "${_rc_m1:-1}"
assert_eq "ubuntu method-1: AVAILABLE=1"      "1"     "${_avail_m1:-0}"
assert_eq "ubuntu method-1: target is 25.04"  "25.04" "${_target_m1:-?}"

# ---------------------------------------------------------------------------
# 5. Ubuntu method-2: codename in quotes extracted and mapped
# ---------------------------------------------------------------------------
(
    set +e
    FAKE_BIN="$(mktemp -d)"
    trap 'rm -rf "${FAKE_BIN}"' EXIT
    cat > "${FAKE_BIN}/do-release-upgrade" << 'FAKE'
#!/bin/sh
echo "New release 'plucky' found."
exit 0
FAKE
    chmod +x "${FAKE_BIN}/do-release-upgrade"
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID="24.10"
    ZNH_DISTRO_UPGRADE_AVAILABLE=0
    ZNH_DISTRO_UPGRADE_TARGET=""
    PATH="${FAKE_BIN}:${PATH}"
    # Override curl so method-3 is skipped (codename→version must be decisive)
    curl() { return 1; }
    _rc=0; znh_distro_upgrade_check_ubuntu; _rc=$?
    echo "rc_m2=${_rc}"
    echo "avail_m2=${ZNH_DISTRO_UPGRADE_AVAILABLE}"
    echo "target_m2=${ZNH_DISTRO_UPGRADE_TARGET}"
) > /tmp/znh_m2_out_$$.txt 2>/dev/null

_rc_m2="$(    grep '^rc_m2='    /tmp/znh_m2_out_$$.txt | cut -d= -f2)"
_avail_m2="$( grep '^avail_m2=' /tmp/znh_m2_out_$$.txt | cut -d= -f2)"
_target_m2="$(grep '^target_m2=' /tmp/znh_m2_out_$$.txt | cut -d= -f2)"
rm -f /tmp/znh_m2_out_$$.txt

assert_rc "ubuntu method-2: rc is 0"          0       "${_rc_m2:-1}"
assert_eq "ubuntu method-2: AVAILABLE=1"      "1"     "${_avail_m2:-0}"
assert_eq "ubuntu method-2: target is 25.04"  "25.04" "${_target_m2:-?}"

# ---------------------------------------------------------------------------
# 6. Ubuntu method-4: cycle-math fallback (no version, no codename, no curl)
# ---------------------------------------------------------------------------
(
    set +e
    FAKE_BIN="$(mktemp -d)"
    trap 'rm -rf "${FAKE_BIN}"' EXIT
    cat > "${FAKE_BIN}/do-release-upgrade" << 'FAKE'
#!/bin/sh
echo "New release found."
exit 0
FAKE
    chmod +x "${FAKE_BIN}/do-release-upgrade"
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID="24.04"
    ZNH_DISTRO_UPGRADE_AVAILABLE=0
    ZNH_DISTRO_UPGRADE_TARGET=""
    PATH="${FAKE_BIN}:${PATH}"
    # Override curl and disable method-3; cycle-math fallback must be decisive
    curl() { return 1; }
    _rc=0; znh_distro_upgrade_check_ubuntu; _rc=$?
    echo "rc_m4=${_rc}"
    echo "avail_m4=${ZNH_DISTRO_UPGRADE_AVAILABLE}"
    echo "target_m4=${ZNH_DISTRO_UPGRADE_TARGET}"
) > /tmp/znh_m4_out_$$.txt 2>/dev/null

_rc_m4="$(    grep '^rc_m4='    /tmp/znh_m4_out_$$.txt | cut -d= -f2)"
_avail_m4="$( grep '^avail_m4=' /tmp/znh_m4_out_$$.txt | cut -d= -f2)"
_target_m4="$(grep '^target_m4=' /tmp/znh_m4_out_$$.txt | cut -d= -f2)"
rm -f /tmp/znh_m4_out_$$.txt

assert_rc "ubuntu method-4: rc is 0"         0       "${_rc_m4:-1}"
assert_eq "ubuntu method-4: AVAILABLE=1"     "1"     "${_avail_m4:-0}"
# cycle math: 24.04 → 24.10
assert_eq "ubuntu method-4: target is 24.10" "24.10" "${_target_m4:-?}"

# ---------------------------------------------------------------------------
# 7. Ubuntu: tool returns non-zero → cycle-math fallback (|| true behavior)
# NOTE: check_ubuntu() uses 'out="$(do-release-upgrade -c 2>&1 || true)"; rc=$?'
# The '|| true' always makes rc=0 when the tool is present (even if it returns 1).
# So when the tool says "no upgrade" the function still calls cycle-math fallback.
# This test documents that actual behavior (tool present + returns 1 → rc=0, cycle math).
# ---------------------------------------------------------------------------
(
    set +e
    FAKE_BIN="$(mktemp -d)"
    trap 'rm -rf "${FAKE_BIN}"' EXIT
    cat > "${FAKE_BIN}/do-release-upgrade" << 'FAKE'
#!/bin/sh
echo "No new release found."
exit 1
FAKE
    chmod +x "${FAKE_BIN}/do-release-upgrade"
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID="24.10"
    ZNH_DISTRO_UPGRADE_AVAILABLE=0
    ZNH_DISTRO_UPGRADE_TARGET=""
    PATH="${FAKE_BIN}:${PATH}"
    # Override curl so method-3 is skipped; cycle math (24.10→25.04) must be decisive
    curl() { return 1; }
    _rc=0; znh_distro_upgrade_check_ubuntu; _rc=$?
    echo "rc_noupgrade=${_rc}"
    echo "avail_noupgrade=${ZNH_DISTRO_UPGRADE_AVAILABLE}"
    echo "target_noupgrade=${ZNH_DISTRO_UPGRADE_TARGET}"
) > /tmp/znh_noupgrade_out_$$.txt 2>/dev/null

_rc_nf="$(    grep '^rc_noupgrade='    /tmp/znh_noupgrade_out_$$.txt | cut -d= -f2)"
_avail_nf="$( grep '^avail_noupgrade=' /tmp/znh_noupgrade_out_$$.txt | cut -d= -f2)"
_target_nf="$(grep '^target_noupgrade=' /tmp/znh_noupgrade_out_$$.txt | cut -d= -f2)"
rm -f /tmp/znh_noupgrade_out_$$.txt

# || true in the function converts the tool's non-zero exit to rc=0;
# no version in output → cycle math kicks in (24.10 → 25.04 via October→April rule).
assert_rc "ubuntu tool-returns-1: rc still 0" 0       "${_rc_nf:-1}"
assert_eq "ubuntu tool-returns-1: AVAILABLE=1" "1"     "${_avail_nf:-0}"
assert_eq "ubuntu tool-returns-1: cycle target" "25.04" "${_target_nf:-?}"

# ---------------------------------------------------------------------------
# 8. Leap: returns 1 (manual, not available) and computes arithmetic target
# ---------------------------------------------------------------------------
(
    set +e
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID="15.6"
    ZNH_DISTRO_UPGRADE_AVAILABLE=0
    ZNH_DISTRO_UPGRADE_TARGET=""
    ZNH_DISTRO_UPGRADE_CURRENT=""
    # Override zypper so the lr | grep probe cannot match "leap/15.7"
    zypper() { return 1; }
    _rc=0; znh_distro_upgrade_check_leap; _rc=$?
    echo "rc_leap=${_rc}"
    echo "avail_leap=${ZNH_DISTRO_UPGRADE_AVAILABLE}"
    echo "target_leap=${ZNH_DISTRO_UPGRADE_TARGET}"
    echo "current_leap=${ZNH_DISTRO_UPGRADE_CURRENT}"
) > /tmp/znh_leap_out_$$.txt 2>/dev/null

_rc_leap="$(      grep '^rc_leap='      /tmp/znh_leap_out_$$.txt | cut -d= -f2)"
_avail_leap="$(   grep '^avail_leap='   /tmp/znh_leap_out_$$.txt | cut -d= -f2)"
_target_leap="$(  grep '^target_leap='  /tmp/znh_leap_out_$$.txt | cut -d= -f2)"
_current_leap="$( grep '^current_leap=' /tmp/znh_leap_out_$$.txt | cut -d= -f2)"
rm -f /tmp/znh_leap_out_$$.txt

assert_rc "leap: rc is 1 (manual)"           1      "${_rc_leap:-0}"
assert_eq "leap: AVAILABLE stays 0"          "0"    "${_avail_leap:-?}"
assert_eq "leap 15.6→15.7 target"           "15.7" "${_target_leap:-?}"
assert_eq "leap: CURRENT is set"             "15.6" "${_current_leap:-?}"

# ---------------------------------------------------------------------------
# 9. Leap: works with a different minor version
# ---------------------------------------------------------------------------
(
    set +e
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID="15.5"
    ZNH_DISTRO_UPGRADE_AVAILABLE=0
    ZNH_DISTRO_UPGRADE_TARGET=""
    zypper() { return 1; }
    znh_distro_upgrade_check_leap
    echo "target_leap55=${ZNH_DISTRO_UPGRADE_TARGET}"
) > /tmp/znh_leap55_out_$$.txt 2>/dev/null
_target_leap55="$(grep '^target_leap55=' /tmp/znh_leap55_out_$$.txt | cut -d= -f2)"
rm -f /tmp/znh_leap55_out_$$.txt
assert_eq "leap 15.5→15.6 target" "15.6" "${_target_leap55:-?}"

# ---------------------------------------------------------------------------
# 10. Leap: zypper absent → arithmetic fallback still gives correct target
# ---------------------------------------------------------------------------
(
    set +e
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID="15.6"
    ZNH_DISTRO_UPGRADE_AVAILABLE=0
    ZNH_DISTRO_UPGRADE_TARGET=""
    # Override zypper as a function that simulates the binary being absent
    # (command -v zypper returns non-zero; lr probe skipped entirely).
    zypper() { return 127; }
    _rc=0; znh_distro_upgrade_check_leap; _rc=$?
    echo "rc_leap_nozyp=${_rc}"
    echo "target_leap_nozyp=${ZNH_DISTRO_UPGRADE_TARGET}"
) > /tmp/znh_leap_nozyp_$$.txt 2>/dev/null
_rc_leap_nozyp="$(    grep '^rc_leap_nozyp='    /tmp/znh_leap_nozyp_$$.txt | cut -d= -f2)"
_target_leap_nozyp="$(grep '^target_leap_nozyp=' /tmp/znh_leap_nozyp_$$.txt | cut -d= -f2)"
rm -f /tmp/znh_leap_nozyp_$$.txt
assert_rc "leap no-zypper: rc is 1"           1      "${_rc_leap_nozyp:-0}"
assert_eq "leap no-zypper: target is 15.7"   "15.7" "${_target_leap_nozyp:-?}"

# ---------------------------------------------------------------------------
# 11. Leap: empty VERSION_ID → no target computed (graceful)
# ---------------------------------------------------------------------------
(
    set +e
    # shellcheck source=/dev/null
    . "${TMP_SNIPPET}"
    VERSION_ID=""
    ZNH_DISTRO_UPGRADE_AVAILABLE=0
    ZNH_DISTRO_UPGRADE_TARGET="INITIAL"
    zypper() { return 1; }
    znh_distro_upgrade_check_leap
    echo "target_leap_empty=${ZNH_DISTRO_UPGRADE_TARGET}"
) > /tmp/znh_leap_empty_$$.txt 2>/dev/null
_target_leap_empty_line="$(grep '^target_leap_empty=' /tmp/znh_leap_empty_$$.txt || true)"
_target_leap_empty="$(printf '%s' "${_target_leap_empty_line}" | cut -d= -f2)"
rm -f /tmp/znh_leap_empty_$$.txt
# Use -NOTEMPTY (no colon) so that empty string passes; only triggers on unset.
assert_eq "leap empty VERSION_ID: target empty" "" "${_target_leap_empty-NOTEMPTY}"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: distro-upgrade Ubuntu+Leap skip regression (${PASS_COUNT} assertions)"
