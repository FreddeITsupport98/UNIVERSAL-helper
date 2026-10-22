#!/bin/bash
# Live smoke for the --arch-repos module (real UNI-auto.sh module flow).
#
# MANUAL smoke (NOT part of the auto-discovered regression suite — the suite
# only picks up regressions/test_*.sh): run as root against /tmp fixtures:
#   sudo -n bash scripts/smoke_arch_repos_live.sh </dev/null
# Every file path is a /tmp fixture (os-release, pacman.conf, cpuinfo, a fake
# pacman binary, the ALHP mirrorlist) — no network, nothing real is touched.
# Covers all ten failchecks end-to-end plus enable/disable/disable-all/health
# (--auto-disable failsafe)/ALHP/history and the state/health TSV logs.
set -uo pipefail

REPO="/home/fb/Dokument/GitHub/UNIVERSAL-helper/UNI-auto.sh"
T="$(mktemp -d /tmp/znh-arch-smoke.XXXXXX)"
trap 'rm -rf -- "$T"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "OK   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

# --- fixtures ---
printf 'ID=arch\nID_LIKE=archlinux\n' >"$T/os-arch"
printf 'ID=fedora\n' >"$T/os-fedora"
printf 'flags\t\t: fpu cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave\n' >"$T/cpu-v3"
printf 'flags\t\t: fpu cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3\n' >"$T/cpu-v2"
{ printf '[options]\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n\n'; } >"$T/conf"
printf '# fake ALHP mirrorlist\nServer = https://alhp.dev/$repo/$arch\n' >"$T/alhp-mirrorlist"
cat >"$T/pacman-ok" <<'EOF'
#!/bin/bash
echo "synchronizing package databases... done"
exit 0
EOF
cat >"$T/pacman-broken" <<'EOF'
#!/bin/bash
echo ":: Synchronizing package databases..."
echo "error: failed to synchronize some databases"
echo "error: failed retrieving 'chaotic-aur.db' : Could not resolve host"
exit 1
EOF
cat >"$T/pacman-sigfail" <<'EOF'
#!/bin/bash
echo "error: GPGME: No data (from 'https://geo-mirror.chaotic.cx/chaotic-aur/x86_64/chaotic-aur.db')"
echo "error: failed to synchronize some databases"
exit 1
EOF
chmod +x "$T/pacman-ok" "$T/pacman-broken" "$T/pacman-sigfail"

run_arch() {
    ZNH_OS_RELEASE_FILE="$T/os-arch" \
    ZNH_ARCH_PACMAN_CONF="$T/conf" \
    ZNH_ARCH_CPUINFO_FILE="$T/cpu-v3" \
    ZNH_ARCH_STATE_DIR="$T/state" \
    ZNH_ARCH_SUDO_MODE=never \
    ZNH_ARCH_ALHP_MIRRORLIST="$T/alhp-mirrorlist" \
    bash "$REPO" --arch-repos "$@" 2>&1
}

# 1) FC1: Fedora host -> clean exit, nothing changed, rc=0.
out="$(ZNH_OS_RELEASE_FILE="$T/os-fedora" ZNH_ARCH_PACMAN_CONF="$T/conf" ZNH_ARCH_STATE_DIR="$T/state" ZNH_ARCH_SUDO_MODE=never bash "$REPO" --arch-repos list 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "targets Arch-family systems only" <<<"$out" && ok "FC1 clean exit on non-Arch family (rc=0 + message)" || bad "FC1 non-Arch clean exit (rc=$rc)"
grep -q '\[chaotic-aur\]' "$T/conf" 2>/dev/null && bad "FC1 changed the fixture conf on non-Arch" || ok "FC1 no conf change on non-Arch"
# 1b) FC1 + --json on non-Arch emits machine-readable supported:false.
jout="$(ZNH_OS_RELEASE_FILE="$T/os-fedora" ZNH_ARCH_PACMAN_CONF="$T/conf" ZNH_ARCH_STATE_DIR="$T/state" ZNH_ARCH_SUDO_MODE=never bash "$REPO" --arch-repos list --json 2>/dev/null | grep '^{' | head -n1)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["supported"] is False and d["repos"]==[]' "$jout" 2>/dev/null && ok "FC1 non-Arch --json clean exit (supported:false)" || bad "FC1 non-Arch --json output"

# 2) Arch fixture list: catalog + verbatim warning, rc=0.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch list)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "The official Arch Linux developers and the Package Maintainers do not perform tests" <<<"$out" && grep -q "chaotic-aur" <<<"$out" && grep -q "Repositories shown: 69 of 69" <<<"$out" && ok "Arch fixture list (catalog 69 + verbatim warning, rc=0)" || bad "Arch fixture list (rc=$rc)"

# 3) --json on Arch fixture: supported:true + 69 repos + chaotic-aur row.
jout="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch list --json 2>/dev/null | grep '^{' | head -n1)"
python3 - "$jout" <<'PY' 2>/dev/null && ok "Arch --json listing (supported:true + 69 repos + cpu level 3)" || bad "Arch --json listing"
import json, sys
d = json.loads(sys.argv[1])
assert d["supported"] is True and len(d["repos"]) == 69 and d["cpu_level"] == 3
chaotic = [r for r in d["repos"] if r["name"] == "chaotic-aur"][0]
assert chaotic["signed"] is True and chaotic["url"].endswith("$repo/$arch") and chaotic["key"] == "FBA220DFC880C036" and chaotic["enabled"] is False
PY

# 4) FC2: enable ada from catalog (http URL) -> refused, rc=1, conf untouched.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable ada --assume-yes --key-verified)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FAILCHECK (HTTPS-only)" <<<"$out" && ! grep -q '\[ada\]' "$T/conf" && ok "FC2 HTTP catalog URL refused (ada), conf untouched" || bad "FC2 HTTPS failcheck (rc=$rc)"

# 5) FC6: non-interactive enable without confirm flags -> refused.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable chaotic-aur --assume-yes)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FAILCHECK (key confirmation)" <<<"$out" && ! grep -q '\[chaotic-aur\]' "$T/conf" && ok "FC6 non-interactive missing --key-verified refused" || bad "FC6 no-silent-defaults failcheck (rc=$rc)"
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable mesa-git https://example.org/mesa --assume-yes)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FAILCHECK (unsigned re-confirm)" <<<"$out" && ok "FC6 unsigned missing --unsigned-accepted refused" || bad "FC6 unsigned re-confirm failcheck (rc=$rc)"

# 6) FC8: two repos in one enable run -> refused.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable chaotic-aur arch4edu --assume-yes --key-verified)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FAILCHECK (one repository per run)" <<<"$out" && ok "FC8 one-repo-per-run refusal" || bad "FC8 one-repo-per-run failcheck (rc=$rc)"

# 7) --dry-run: prints the exact block + would-run commands, writes NOTHING.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable chaotic-aur --dry-run)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "\[dry-run\] Would append this managed block" <<<"$out" && grep -q "SigLevel = PackageRequired" <<<"$out" && ! grep -q '\[chaotic-aur\]' "$T/conf" && ok "dry-run preview (no writes, rc=0)" || bad "dry-run behavior (rc=$rc)"

# 8) Successful enable: managed block + state log + pacman -Sy validated.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable chaotic-aur --assume-yes --key-verified)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^\[chaotic-aur\]' "$T/conf" && grep -q "SigLevel = PackageRequired" "$T/conf" && grep -q $'chaotic-aur\tenabled' "$T/state/arch-repos-state.tsv" && ok "enable chaotic-aur (managed block + state log + validated, rc=0)" || bad "enable chaotic-aur (rc=$rc)"
grep -q ">>> zypper-auto-helper arch-repos" "$T/conf" && ok "enable wrote the managed block markers" || bad "managed block markers missing"

# 9) FC3: re-enable -> duplicate refused.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable chaotic-aur --assume-yes --key-verified)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FAILCHECK (duplicate)" <<<"$out" && ok "FC3 duplicate refusal on re-enable" || bad "FC3 duplicate failcheck (rc=$rc)"

# 10) FC9: pacman -Sy fails (unreachable) -> rollback + rc=1 + rolled-back state.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-broken" run_arch enable arch4edu --assume-yes --key-verified)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FAILCHECK (post-add validation)" <<<"$out" && grep -q "rolling the change back" <<<"$out" && ! grep -q '^\[arch4edu\]' "$T/conf" && grep -q $'arch4edu\trolled-back' "$T/state/arch-repos-state.tsv" && ok "FC9 unreachable repo rolled back (conf restored + state log)" || bad "FC9 post-add validation rollback (rc=$rc)"

# 10b) FC9 with a signature failure (key not yet imported) -> rollback + guidance.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-sigfail" run_arch enable archlinuxcn --assume-yes --key-verified)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "If you have not imported the repository key yet" <<<"$out" && ! grep -q '^\[archlinuxcn\]' "$T/conf" && ok "FC9 signature-failure rollback + key-import guidance" || bad "FC9 signature-failure rollback (rc=$rc)"

# 11) health (enabled chaotic-aur now broken via pacman-broken) -> report + auto-disable failsafe.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-broken" run_arch health --auto-disable --yes)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "UNREACHABLE / FAULTY" <<<"$out" && grep -q "Auto-disabled (removed" <<<"$out" && ! grep -q '^\[chaotic-aur\]' "$T/conf" && grep -q $'chaotic-aur\tauto-disabled' "$T/state/arch-repos-state.tsv" && ok "health --auto-disable removed the faulty repo (state log, rc=0)" || bad "health --auto-disable failsafe (rc=$rc)"
grep -q "unreachable" "$T/state/arch-repos-health.tsv" && ok "health TSV recorded the unreachable state" || bad "health TSV missing unreachable entry"
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch health)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "No catalog-listed unofficial Arch repositories are enabled" <<<"$out" && ok "health with none enabled -> clean no-op" || bad "health no-op (rc=$rc)"

# 12) ALHP: cpu-v3 fixture -> enable v3 sections; cpu-v2 + --level v3 -> FC4 refusal.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable ALHP --assume-yes --key-verified)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^\[core-x86-64-v3\]' "$T/conf" && grep -q '^\[extra-x86-64-v3\]' "$T/conf" && grep -q '^\[multilib-x86-64-v3\]' "$T/conf" && grep -q $'ALHP\tenabled' "$T/state/arch-repos-state.tsv" && ok "ALHP enable for detected level v3 (3 sections + state log)" || bad "ALHP enable v3 (rc=$rc)"
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch disable ALHP --yes)"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'x86-64-v3\]' "$T/conf" && ok "ALHP disable removed the 3 level sections" || bad "ALHP disable (rc=$rc)"
ZNH_OS_RELEASE_FILE="$T/os-arch" ZNH_ARCH_PACMAN_CONF="$T/conf" ZNH_ARCH_CPUINFO_FILE="$T/cpu-v2" ZNH_ARCH_STATE_DIR="$T/state" ZNH_ARCH_SUDO_MODE=never ZNH_ARCH_ALHP_MIRRORLIST="$T/alhp-mirrorlist" ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" bash "$REPO" --arch-repos enable ALHP --level v3 --assume-yes --key-verified >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'x86-64-v3\]' "$T/conf" && ok "FC4 ALHP level v3 on a v2 CPU refused" || bad "FC4 ALHP CPU level failcheck (rc=$rc)"

# 13) unsigned repo: SigLevel forced to PackageOptional.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch enable mesa-git https://example.org/mesa-git --assume-yes --unsigned-accepted)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^\[mesa-git\]' "$T/conf" && grep -q "SigLevel = PackageOptional" "$T/conf" && ok "unsigned enable forces SigLevel = PackageOptional" || bad "unsigned enable SigLevel (rc=$rc)"

# 14) disable: preview + --yes removes the section.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch disable mesa-git --yes)"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^\[mesa-git\]' "$T/conf" && grep -q $'mesa-git\tdisabled' "$T/state/arch-repos-state.tsv" && ok "disable mesa-git (removed + state log)" || bad "disable mesa-git (rc=$rc)"

# 15) history: newest-first listing of the state log.
out="$(ZNH_ARCH_PACMAN_BIN="$T/pacman-ok" run_arch history)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "Arch unofficial repository history" <<<"$out" && grep -q "auto-disabled" <<<"$out" && grep -q "rolled-back" <<<"$out" && ok "history lists enable/disable/auto-disable/rolled-back entries" || bad "history listing (rc=$rc)"

# 16) backups were written for every change (FC9 rollback source).
ls "$T"/conf.znh-backup-* >/dev/null 2>&1 && ok "pre-write backups exist (conf.znh-backup-*)" || bad "pre-write backups missing"

echo ""
echo "SMOKE RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
