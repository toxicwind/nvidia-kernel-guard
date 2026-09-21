#!/usr/bin/env bash
# nvidia-kernel-guard test suite. Mock-based: runs anywhere (cell CI + yote).
# Usage: tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NKG="$ROOT/bin/nkg"
MOCKS="$ROOT/tests/mocks/bin"
FIX="$ROOT/tests/fixtures"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $1"; echo "     $2"; }

# fresh sandbox per test: returns via globals T (tmpdir), fixture copy
sandbox() { # $1 = fixture name
  T="$(mktemp -d /tmp/nkg-test-XXXXXX)"
  cp -r "$FIX/$1/." "$T/fx/"
  mkdir -p "$T/state"
  export NKG_TEST_FIXTURE="$T/fx"
  export NKG_MODULES_DIR="$T/fx/modules"
  export NKG_STATE_DIR="$T/state"
  export NKG_CONFIG="$T/nkg.conf"
  export NKG_ALLOW_NONROOT=1
  export MOCK_LOG="$T/mock.log"
  export PATH="$MOCKS:/usr/bin:/bin"
  # The yote bridge sets BASH_ENV to a login-env file that every child bash
  # re-sources, prepending the login PATH ahead of our mock dir. Neutralize it
  # so the mocks win for the whole process tree.
  export BASH_ENV=/dev/null
  : > "$T/nkg.conf"
  : > "$MOCK_LOG"
}
cleanup() { rm -rf "$T"; }

t0=$fail
# --- 1. all covered: exit 0, three OK lines ----------------------------------
sandbox all-covered
out="$("$NKG" audit)"; rc=$?
[[ $rc -eq 0 ]] || bad "all-covered rc" "want 0 got $rc"
echo "$out" | grep -q "OK   linux-cachyos-bore" || bad "all-covered bore" "$out"
[[ "$(echo "$out" | grep -c '^OK')" -eq 3 ]] || bad "all-covered count" "$out"
[[ $fail -eq $t0 ]] && ok "all-covered"
cleanup

t0=$fail
# --- 2. missing driver: GAP, exit 1, fix installs right package --------------
sandbox missing-driver
out="$("$NKG" audit 2>&1)"; rc=$?
[[ $rc -eq 1 ]] || bad "missing-driver rc" "want 1 got $rc: $out"
echo "$out" | grep -qE "GAP +linux-cachyos-bore +-> .*missing-repo" || bad "missing-driver gap" "$out"
"$NKG" fix --yes >/dev/null 2>&1
grep -q "INSTALL linux-cachyos-bore-nvidia-open" "$MOCK_LOG" || bad "missing-driver install" "$(cat "$MOCK_LOG")"
grep -q "^MKINITCPIO -P" "$MOCK_LOG" || bad "missing-driver mkinitcpio" "$(cat "$MOCK_LOG")"
[[ $fail -eq $t0 ]] && ok "missing-driver + fix"
cleanup

t0=$fail
# --- 3. version skew: detected, fix reinstalls -------------------------------
sandbox version-skew
out="$("$NKG" audit 2>&1)"; rc=$?
[[ $rc -eq 1 ]] || bad "skew rc" "want 1 got $rc"
echo "$out" | grep -q "skewed.*7.2.6-1 vs driver 7.1.3-2" || bad "skew detail" "$out"
jout="$("$NKG" audit --json)"
echo "$jout" | grep -q '"kernel":"linux-cachyos-bore".*"state":"skewed"' || bad "skew json" "$jout"
"$NKG" fix --yes >/dev/null 2>&1
grep -q "INSTALL linux-cachyos-bore-nvidia-open" "$MOCK_LOG" || bad "skew reinstall" "$(cat "$MOCK_LOG")"
[[ $fail -eq $t0 ]] && ok "version-skew + fix"
cleanup

t0=$fail
# --- 4. modules-dir enumeration: vmlinuz+pkgbase found, orphan skipped -------
sandbox modules-dir-only
out="$("$NKG" audit 2>&1)"; rc=$?
echo "$out" | grep -q "linux-custom" || bad "modules-dir kernel" "$out"
echo "$out" | grep -q "9.9.9-orphan" && bad "modules-dir orphan" "orphan dir leaked into audit: $out"
echo "$out" | grep -q "missing-repo" || bad "modules-dir repo-probe" "$out"
[[ $fail -eq $t0 ]] && ok "modules-dir enumeration"
cleanup

t0=$fail
# --- 5. unknown kernel: missing-unknown + dkms hint ---------------------------
sandbox unknown-kernel
out="$("$NKG" audit 2>&1)"; rc=$?
echo "$out" | grep -q "missing-unknown" || bad "unknown state" "$out"
fout="$("$NKG" fix --yes 2>&1)"
echo "$fout" | grep -q "nvidia-open-dkms" || bad "unknown dkms hint" "$fout"
grep -q "^INSTALL" "$MOCK_LOG" && bad "unknown no-install" "installed something for unknown kernel"
[[ $fail -eq $t0 ]] && ok "unknown-kernel"
cleanup

t0=$fail
# --- 6. dkms fallback covers everything ---------------------------------------
sandbox dkms-fallback
out="$("$NKG" audit 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || bad "dkms rc" "want 0 got $rc: $out"
echo "$out" | grep -q "covered-dkms" || bad "dkms state" "$out"
[[ $fail -eq $t0 ]] && ok "dkms-fallback"
cleanup

t0=$fail
# --- 7. proprietary flavor mapping -------------------------------------------
sandbox proprietary
echo "DRIVER_FLAVOR=proprietary" > "$NKG_CONFIG"
out="$("$NKG" audit 2>&1)"; rc=$?
echo "$out" | grep -q "linux-cachyos-bore .* linux-cachyos-bore-nvidia " || bad "proprietary map" "$out"
echo "$out" | grep -qE "GAP +linux-cachyos +-> .*missing-repo" || bad "proprietary gap" "$out"
[[ $fail -eq $t0 ]] && ok "proprietary-flavor"
cleanup

t0=$fail
# --- 8. hook: warns + writes pending on gaps; clears when clean ---------------
sandbox missing-driver
"$NKG" hook >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] || bad "hook rc" "want 1 got $rc"
[[ -f "$T/state/pending" ]] || bad "hook pending" "pending file not written"
sandbox all-covered
touch "$T/state/pending"
"$NKG" hook >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] || bad "hook clean rc" "want 0 got $rc"
[[ -f "$T/state/pending" ]] && bad "hook clear" "pending file not cleared"
[[ $fail -eq $t0 ]] && ok "hook warn/clear"
cleanup

t0=$fail
# --- 9. autofix respects HOOK_AUTOFIX ------------------------------------------
sandbox missing-driver
echo "HOOK_AUTOFIX=no" > "$NKG_CONFIG"
"$NKG" autofix >/dev/null 2>&1
grep -q "^INSTALL" "$MOCK_LOG" && bad "autofix disabled" "installed despite HOOK_AUTOFIX=no"
echo "HOOK_AUTOFIX=yes" > "$NKG_CONFIG"
"$NKG" autofix >/dev/null 2>&1
grep -q "INSTALL linux-cachyos-bore-nvidia-open" "$MOCK_LOG" || bad "autofix enabled" "$(cat "$MOCK_LOG")"
[[ $fail -eq $t0 ]] && ok "autofix gate"
cleanup

t0=$fail
# --- 10. boot check: --boot fails without modules, passes with them ----------
sandbox all-covered
NKG_TEST_UNAME="7.2.6-1-cachyos-bore" "$NKG" audit --boot >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 ]] || bad "boot no-modules" "want 3 got $rc"
mkdir -p "$T/fx/modules/7.2.6-1-cachyos-bore/extramodules"
touch "$T/fx/modules/7.2.6-1-cachyos-bore/extramodules/nvidia.ko.zst"
NKG_TEST_UNAME="7.2.6-1-cachyos-bore" "$NKG" audit --boot >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] || bad "boot modules" "want 0 got $rc"
[[ $fail -eq $t0 ]] && ok "boot check"
cleanup

t0=$fail
# --- 11. no kernels: clean error ----------------------------------------------
T2="$(mktemp -d /tmp/nkg-test-XXXXXX)"; mkdir -p "$T2/fx" "$T2/state"
: > "$T2/fx/installed.db"; : > "$T2/fx/repo.db"; : > "$T2/fx/files.db"; : > "$T2/fx/owners.db"; mkdir -p "$T2/fx/modules"
NKG_TEST_FIXTURE="$T2/fx" NKG_MODULES_DIR="$T2/fx/modules" NKG_STATE_DIR="$T2/state" \
  NKG_CONFIG=/dev/null NKG_ALLOW_NONROOT=1 PATH="$MOCKS:/usr/bin:/bin" \
  "$NKG" audit >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] || bad "no-kernels rc" "want 2 got $rc"
[[ $fail -eq $t0 ]] && ok "no-kernels"
rm -rf "$T2"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
