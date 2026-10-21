#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes are intentional throughout this
# file: assertions grep the target for LITERAL unexpanded ${...} source strings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_notifier_updates_ready_dedupe_regression.sh [path/to/UNI-auto.sh]

Regression guard for the "Updates Ready to Install" duplicate/stale popup fixes:
  - dedupe comparison ignores the volatile "Downloads complete: ... in Xs"
    note (its duration text changed on every downloader run and re-showed the
    same popup every notifier tick -> the user saw the popup twice+)
  - stale-cache guard: an install AFTER the cached dry-run was written
    (WebUI Rocket flow / plain manual upgrade) no longer re-pops "ready to
    install" for already-installed updates (package-DB mtime vs cache mtime,
    then a fresh preview)
  - UPDATES_READY_REMINDER_REPEAT_ENABLED default flipped true -> false
    (the popup is persistent; re-showing stacks duplicates on KDE Plasma)
  - WebUI Rocket worker clears the dry-run/download cache after a successful
    update (mirrors zypper-run-install)
  - the flag is now schema-validated + toggleable from the Settings drawer
  - RUNTIME: extracts the real helpers from the embedded notifier and proves
    the mtime guard cases + the dedupe key comparison with the real log texts
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

# --- 1) Stale-cache helpers exist + probe the transaction-backed PM databases ---
require_contains "${source_text}" 'def _pm_db_mtime() -> float:' "Missing _pm_db_mtime helper"
require_contains "${source_text}" '"/usr/lib/sysimage/rpm/rpmdb.sqlite",  # RPM: Fedora 41+ default' "Missing Fedora 41+ rpmdb.sqlite candidate"
require_contains "${source_text}" '"/var/lib/rpm/rpmdb.sqlite",            # RPM: classic sqlite' "Missing classic rpmdb.sqlite candidate"
require_contains "${source_text}" '"/var/lib/dpkg/status",                 # APT: Debian/Ubuntu/Mint' "Missing dpkg status candidate"
require_contains "${source_text}" '"/var/lib/pacman/local",                # pacman: Arch' "Missing pacman local-db candidate"
require_contains "${source_text}" 'would make every '"'"'rpm -q'"'"' look like an install and re-trigger the' "Missing the -wal/-shm sidecar skip rationale (reads must not look like installs)"
require_contains "${source_text}" 'def _cache_stale_after_install() -> bool:' "Missing _cache_stale_after_install helper"
require_contains "${source_text}" 'if db_mtime > 0 and db_mtime > cache_mtime:' "Missing the db-newer-than-cache comparison"

# --- 2) The stale-cache guard runs a fresh preview before showing Updates Ready ---
require_contains "${source_text}" 'if output and output.strip() and _cache_stale_after_install():' "Missing the stale-cache guard invocation"
require_contains "${source_text}" "log_info(\"Re-running a fresh preview (stale-cache guard) before showing 'Updates Ready'\")" "Missing the stale-cache guard fresh-preview log"
require_contains "${source_text}" 'update_status("SKIPPED: stale dry-run cache (install detected); no fresh preview data")' "Missing the stale-guard skip status"

# --- 3) Dedupe fix: volatile completion note stripped from the comparison ---
require_contains "${source_text}" 'def _strip_volatile_note(text):' "Missing _strip_volatile_note dedupe helper"
require_contains "${source_text}" 'return re.sub(r"✅ Downloads complete[^\n]*\n?", "", text or "").strip()' "Missing the volatile completion-note strip regex"
require_contains "${source_text}" '_last_title, _, _last_msg = (last_notification or "").partition("|")' "Missing last-notification partition for the dedupe key"
require_contains "${source_text}" 'last_key = f"{_last_title}|{_strip_volatile_note(_last_msg)}"' "Missing last dedupe key construction"
require_contains "${source_text}" 'current_key = f"{title}|{_strip_volatile_note(message)}"' "Missing current dedupe key construction"
require_contains "${source_text}" 'and last_key == current_key:' "Missing the fixed dedupe comparison"
require_contains "${source_text}" 'same update set; volatile download note ignored; UPDATES_READY_REMINDER_REPEAT_ENABLED=false' "Missing the updated dedupe skip log text"

# --- 4) Drift guard: the OLD raw comparison must be gone ---
require_not_contains "${source_text}" 'and last_notification == current_notification:' "Old raw dedupe comparison still present (volatile note would defeat dedupe again)"

# --- 5) Repeat default flipped true -> false (template + notifier + schema + drawer) ---
require_contains "${source_text}" 'UPDATES_READY_REMINDER_REPEAT_ENABLED=false' "Missing the false default in the config template"
require_contains "${source_text}" 'UPDATES_READY_REMINDER_REPEAT_ENABLED = _read_bool_from_config("UPDATES_READY_REMINDER_REPEAT_ENABLED", False)' "Missing the False default in the notifier"
require_contains "${source_text}" '"UPDATES_READY_REMINDER_REPEAT_ENABLED": {"type": "bool", "default": "false"}' "Missing the schema row"
require_contains "${source_text}" "key: 'UPDATES_READY_REMINDER_REPEAT_ENABLED', type: 'bool'" "Missing the Settings drawer row"
require_contains "${source_text}" 'KDE Plasma stacks re-shows as duplicates instead of replacing' "Missing the Settings drawer help explaining the new default"

# --- 6) WebUI Rocket worker clears the stale cache after a successful update ---
require_contains "${source_text}" "'  rm -f /var/log/zypper-auto/dry-run-last.txt /var/log/zypper-auto/download-status.txt 2>/dev/null || true'," "Missing the WebUI worker post-update cache clear"
require_contains "${source_text}" "'  echo \"[webui] Cleared stale dry-run/download cache after successful update\" >>\"\$LOG\" || true'," "Missing the WebUI worker cache-clear log line"

# --- 7) Bash syntax sanity of the target file ---
if ! bash -n "${TARGET_FILE}" >/dev/null 2>&1; then
    record_failure "Target file fails bash -n syntax check: ${TARGET_FILE}"
fi

# --- 8) RUNTIME: extract the real helpers from the embedded notifier and prove the logic ---
RT_DIR="$(mktemp -d /tmp/znh_notif_rt.XXXXXX)"
{
    printf '%s\n' '#!/usr/bin/env python3'
    printf '%s\n' 'import os, re, sys, tempfile, time, textwrap'
    printf '%s\n' "SRC = open('${TARGET_FILE}', encoding='utf-8').read()"
    cat <<'PYEOF'
fails = 0


def die(msg):
    global fails
    print("FAIL - " + msg)
    fails = 1


# Extract the module-level helpers (module-level, zero extra deps beyond os).
m1 = re.search(r"def _pm_db_mtime\(\) -> float:\n(?:.*\n)*?    return 0\.0\n", SRC)
m2 = re.search(r"def _cache_stale_after_install\(\) -> bool:\n(?:.*\n)*?    return False\n", SRC)
if not m1 or not m2:
    die("could not extract _pm_db_mtime/_cache_stale_after_install from the embedded notifier")
else:
    ns = {"os": os}
    ns["DRYRUN_OUTPUT_FILE"] = "/nonexistent/znh-rt-no-cache.txt"
    ns["log_info"] = lambda *a, **k: None
    ns["log_debug"] = lambda *a, **k: None
    exec(m1.group(0), ns)
    exec(m2.group(0), ns)
    pm_db_mtime = ns["_pm_db_mtime"]
    stale = ns["_cache_stale_after_install"]

    db = pm_db_mtime()
    if db > 0 and (time.time() - db) < 30 * 86400:
        print("OK   - runtime _pm_db_mtime found a live package DB")
    else:
        die(f"runtime _pm_db_mtime returned {db!r}")

    if stale() is False:
        print("OK   - runtime stale guard: missing cache -> False")
    else:
        die("runtime stale guard: missing cache should be False")

    fd, cache = tempfile.mkstemp(suffix=".txt")
    os.close(fd)
    try:
        now = time.time()
        os.utime(cache, (now - 7200, now - 7200))
        ns["DRYRUN_OUTPUT_FILE"] = cache
        if stale() is True:
            print("OK   - runtime stale guard: cache older than the package DB -> True (install detected)")
        else:
            die("runtime stale guard: old cache should be True")
        os.utime(cache, (now + 3600, now + 3600))
        if stale() is False:
            print("OK   - runtime stale guard: cache newer than the package DB -> False (fresh cache)")
        else:
            die("runtime stale guard: future cache should be False")
    finally:
        os.unlink(cache)

# Extract the nested _strip_volatile_note (8-space nested def in main()).
m3 = re.search(
    r"(        def _strip_volatile_note\(text\):\n(?:.*\n)*?                return \(text or \"\"\)\.strip\(\)\n)",
    SRC,
)
if not m3 or "re.sub" not in m3.group(1):
    die("could not extract the nested _strip_volatile_note from the embedded notifier")
else:
    ns3 = {"re": re}
    exec(textwrap.dedent(m3.group(1)), ns3)
    strip = ns3["_strip_volatile_note"]

    title = "Updates Ready to Install"
    msg_9s = (
        "✅ Downloads complete: downloaded 1 package(s) in 9s. Including: warp-terminal\n\n"
        "1 update is pending.\n\n"
        "Including: warp-terminal\n\n"
        "⚠️ Snapper not installed"
    )
    msg_13s = msg_9s.replace("in 9s", "in 13s")
    if msg_9s == msg_13s:
        die("runtime setup broken: test messages identical before stripping")
    if f"{title}|{strip(msg_9s)}" == f"{title}|{strip(msg_13s)}":
        print("OK   - runtime dedupe: 'in 9s' vs 'in 13s' now compare as IDENTICAL (no re-show)")
    else:
        die("runtime dedupe: volatile-note keys still differ")
    msg_other = msg_13s.replace("warp-terminal", "some-other-package")
    if f"{title}|{strip(msg_other)}" != f"{title}|{strip(msg_13s)}":
        print("OK   - runtime dedupe: a different update set still compares as changed")
    else:
        die("runtime dedupe: different update set wrongly identical")

sys.exit(fails)
PYEOF
} > "${RT_DIR}/runtime.py" 2>/dev/null || true

if python3 "${RT_DIR}/runtime.py" > "${RT_DIR}/runtime.out" 2>&1; then
    cat "${RT_DIR}/runtime.out"
else
    cat "${RT_DIR}/runtime.out" >&2 || true
    record_failure "RUNTIME block failed (see output above)"
fi
rm -rf -- "${RT_DIR}" 2>/dev/null || true

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: notifier updates-ready dedupe + stale-cache regression checks passed"
