#!/system/bin/busybox sh
# bki_debug.sh — regression harness for BetterKnownInstalled.
#
# It dot-sources the REAL functions and awk fragments from post-fs-data.sh
# and uninstall.sh (sibling files, or set BKI_PFD / BKI_PFD_UN) and exercises
# them against a packages.xml of your choice. Your input file is never
# modified; everything happens inside a temp work dir. Every step is timed,
# and the awk in use is reported, so any future slowness points at its
# culprit immediately.
#
# Usage:
#   sh bki_debug.sh /path/to/packages.xml [--keep]
#   sh bki_debug.sh --sample [--keep]
#   BKI_PFD=/path/to/post-fs-data.sh BKI_PFD_UN=/path/to/uninstall.sh sh bki_debug.sh ...

set -u

PASS=0; FAIL=0; KEEP=0
SAMPLE_MODE=0
SRC=""

ok()   { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
info() { printf '  [INFO] %s\n' "$1"; }
hdr()  { printf '\n== %s ==\n' "$1"; }
now()  { date +%s%N 2>/dev/null || date +%s; }

usage() {
  printf 'Usage: %s { /path/to/packages.xml | --sample } [--keep]\n' "$0"
  exit 2
}

for arg in "$@"; do
  case "$arg" in
    --sample)  SAMPLE_MODE=1 ;;
    --keep)    KEEP=1 ;;
    -h|--help) usage ;;
    *)         [ -z "$SRC" ] && SRC="$arg" ;;
  esac
done

WORK="${BKI_WORK:-$(mktemp -d)}"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup 0

# None of the steps read user input. awk programs that consist only of
# BEGIN/END rules would otherwise block forever on an interactive stdin.
exec </dev/null

# --- load the module code under test (dot-source, no eval) -------------------
PFD="${BKI_PFD:-$(dirname "$0")/post-fs-data.sh}"
[ -f "$PFD" ] || { printf 'Error: post-fs-data.sh not found: %s (set BKI_PFD)\n' "$PFD"; exit 2; }

# Stubs for module helpers (the module top-level is NOT executed).
ui_print() { printf '%s\n' "$*" >> "$WORK/module.log"; }
abort()    { printf 'abort: %s\n' "$*" >&2; exit 1; }
boolval()  { [ "$1" = "true" ]; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
abx_to_text() { cat "$1" > "$2"; }   # passthrough stubs for the debug env
text_to_abx() { cat "$1" > "$2"; }

MODPATH="$WORK"
DB="$WORK/metadata.db"
CURRENT_TIMESTAMP=$(date +%s)

sed -n '/# ==== BKI FUNCTIONS START ====/,/# ==== BKI FUNCTIONS END ====/p' "$PFD" > "$WORK/module_funcs.sh"
# shellcheck disable=SC1090
. "$WORK/module_funcs.sh" || { printf 'Error: failed to source functions from %s\n' "$PFD"; exit 2; }
info "Loaded module code from: $PFD"
info "awk in use: $(command -v awk)"

# --- synthetic sample --------------------------------------------------------
gen_sample() {
  cat > "$WORK/sample_packages.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<packages>
<last-platform-version sdk="34" />
<package name="com.android.vending" codePath="/data/app/~~v/com.android.vending" system="false" installer="com.android.vending" installerUid="10128" installInitiator="com.android.vending" packageSource="2" userId="10128"><sigs count="1" /></package>
<package name="com.example.normal" codePath="/data/app/~~x/com.example.normal" system="false" installer="com.miui.packageinstaller" installerUid="10127" installInitiator="com.miui.packageinstaller" packageSource="1" installOriginator="com.shell" isOrphaned="false" installInitiatorUninstalled="false" userId="10201"><sigs count="1" /></package>
<package name="com.example.abxvars" codePath="/data/app/~~y/com.example.abxvars" system="false"
    installer="com.android.shell" installerUid-int="2000" installInitiator="com.android.shell"
    packageSource-int="0" isOrphaned-bool="true" installInitiatorUninstalled-bool="true" userId="10202">
    <sigs count="1" />
</package>
<package name="com.example.sideloaded" codePath="/data/app/~~z/com.example.sideloaded" system="false" userId="10203"><sigs count="1" /></package>
<package name="com.example.multi" codePath="/data/app/~~m/com.example.multi" system="false" installer="com.amazon.venezia" installerUid="10255" packageSource="1" isOrphaned="true" userId="10204"
    installInitiator="com.amazon.venezia" installOriginator="com.amazon.venezia"
    installInitiatorUninstalled="true">
    <sigs count="1" />
    <perms />
</package>
<package name="com.android.sysapp" codePath="/system/app/Sysapp" system="true" installer="com.android.vending" installerUid="10128" installInitiator="com.android.vending" packageSource="2" isOrphaned="false" userId="10300"><sigs count="1" /></package>
</packages>
EOF
}

if [ "$SAMPLE_MODE" -eq 1 ]; then
  gen_sample
  SRC="$WORK/sample_packages.xml"
  info "Generated synthetic sample: $SRC"
fi

[ -n "$SRC" ] && [ -f "$SRC" ] || { printf 'Error: file not found: %s\n' "$SRC"; usage; }
info "Input: $SRC ($(wc -c < "$SRC") bytes)"

# Reference copy split the same way make_work_copy does (byte-fair comparison).
sed 's|</package>\(.\)|</package>\n\1|g' "$SRC" > "$WORK/live_ref.xml"

# Split working copy for the granular steps (mirrors make_work_copy).
cp "$SRC" "$WORK/input.xml"
sed -i 's|</package>\(.\)|</package>\n\1|g' "$WORK/input.xml"

# ==============================================================================
hdr "Step A: resolve_vending_uid"
# ==============================================================================
t0=$(now)
VU=$(resolve_vending_uid "$WORK/input.xml")
t1=$(now)
[ ${#t0} -gt 10 ] && info "elapsed: $(( (t1 - t0) / 1000000 )) ms" || info "elapsed: $(( t1 - t0 )) s"

case "$VU" in
  ''|*[!0-9]*) bad "vending_uid not numeric (got '$VU')" ;;
  0)           bad "vending_uid resolved to 0" ;;
  *)           ok "vending_uid = $VU" ;;
esac

# ==============================================================================
hdr "Step B: db_build (first boot)"
# ==============================================================================
rm -f "$DB"
t0=$(now)
db_build "$WORK/input.xml"
rc=$?
t1=$(now)
[ ${#t0} -gt 10 ] && info "elapsed: $(( (t1 - t0) / 1000000 )) ms" || info "elapsed: $(( t1 - t0 )) s"
[ $rc -eq 0 ] && ok "db_build ran cleanly" || bad "db_build returned failure"
db_lines=$(wc -l < "$DB")

userpkgs=$(awk -v FILE="$WORK/input.xml" '
  function handle_package(seg) {
    if (seg ~ /codePath="\/data\/app\// && seg !~ /system="true"/ && seg !~ /system="1"/) n++
  }
  BEGIN {
      while ((getline line < FILE) > 0) {
        buf = buf line "\n"
        while (1) {
          s = index(buf, "<package ")
          if (s == 0) { buf = ""; break }
          e = index(buf, "</package>")
          if (e == 0 || e < s) break
          handle_package(substr(buf, s, e + 10 - s))
          buf = substr(buf, e + 10)
        }
      }
      print n + 0
  }')

if [ "$db_lines" -gt 0 ] && [ "$db_lines" = "$userpkgs" ]; then
  ok "DB entries ($db_lines) == user packages in XML ($userpkgs)"
else
  bad "DB entries ($db_lines) != user packages (${userpkgs:-0})"
fi
bad_fields=$(awk -F'|' 'NF != 8 { b++ } END { print b + 0 }' "$DB")
[ "$bad_fields" -eq 0 ] && ok "all DB lines have 8 fields" || bad "$bad_fields DB lines have wrong field count"
dupnames=$(awk -F'|' '{ print $1 }' "$DB" | sort | uniq -d | wc -l)
[ "$dupnames" -eq 0 ] && ok "no duplicate package names in DB" || bad "$dupnames duplicate names in DB"

# ==============================================================================
hdr "Step C: patch_user_apps"
# ==============================================================================
cp "$WORK/input.xml" "$WORK/output.xml"
t0=$(now)
patch_user_apps "$WORK/output.xml" "$VU"
rc=$?
t1=$(now)
[ ${#t0} -gt 10 ] && info "elapsed: $(( (t1 - t0) / 1000000 )) ms" || info "elapsed: $(( t1 - t0 )) s"
if [ $rc -eq 0 ]; then
  ok "patch_user_apps ran cleanly"
else
  bad "patch_user_apps failed (rc=$rc)"
fi

# ==============================================================================
hdr "Step D: validation of patched XML"
# ==============================================================================
if [ $rc -eq 0 ]; then
  open_tags=$(grep -o '<package ' "$WORK/output.xml" | wc -l)
  close_tags=$(grep -o '</package>' "$WORK/output.xml" | wc -l)
  [ "$open_tags" = "$close_tags" ] && ok "<package> tags balanced ($open_tags)" \
    || bad "unbalanced tags: $open_tags open vs $close_tags close"

  dupattrs=$(awk -v FILE="$WORK/output.xml" '
    function dup(seg,   rest, a, seen, d) {
      d = 0
      rest = substr(seg, 1, index(seg, ">"))
      while (match(rest, /[A-Za-z0-9_.:-]+="/)) {
        a = substr(rest, RSTART, RLENGTH - 2)
        if (a in seen) d++
        seen[a] = 1
        rest = substr(rest, RSTART + RLENGTH)
      }
      return d
    }
    function handle_package(seg) { total += dup(seg) }
    BEGIN {
      while ((getline line < FILE) > 0) {
        buf = buf line "\n"
        while (1) {
          s = index(buf, "<package ")
          if (s == 0) { buf = ""; break }
          e = index(buf, "</package>")
          if (e == 0 || e < s) break
          handle_package(substr(buf, s, e + 10 - s))
          buf = substr(buf, e + 10)
        }
      }
      print total + 0
    }')
  [ "${dupattrs:-1}" = "0" ] && ok "no duplicate attributes in any <package> tag" \
    || bad "${dupattrs:-?} duplicate attribute(s) found"

  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$WORK/output.xml" 2>"$WORK/xmllint.err" \
      && ok "xmllint: output is well-formed XML" \
      || { bad "xmllint: malformed output"; sed 's/^/    /' "$WORK/xmllint.err"; }
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import xml.etree.ElementTree as ET; ET.parse('$WORK/output.xml')" 2>"$WORK/py.err" \
      && ok "python3: output is well-formed XML" \
      || { bad "python3: malformed output"; sed 's/^/    /' "$WORK/py.err"; }
  else
    info "no xmllint/python3 available — skipping full XML parse"
  fi

  awk -v IN="$WORK/input.xml" -v OUT="$WORK/output.xml" -v VU="$VU" '
    function name_of(seg,   n) { if (match(seg, /name="[^"]*"/)) n = substr(seg, RSTART+6, RLENGTH-7); return n "" }
    function isuser(seg) { return (seg ~ /codePath="\/data\/app\// && seg !~ /system="true"/ && seg !~ /system="1"/) }
    function patched(seg) {
      if (seg !~ /installer="com\.android\.vending"/) return "installer"
      if (seg !~ /installInitiator="com\.android\.vending"/) return "installInitiator"
      if (seg !~ ("installerUid(-int)?=\"" VU "\"")) return "installerUid"
      if (seg ~ /installOriginator=/) return "installOriginator-present"
      if (seg ~ /isOrphaned(-bool)?="(true|1)"/) return "isOrphaned-true"
      if (seg ~ /installInitiatorUninstalled(-bool)?="(true|1)"/) return "initiatorUninstalled-true"
      if (seg !~ /packageSource(-int)?="2"/) return "packageSource"
      return ""
    }
    function load(f, arr,   line, buf, s, e, seg, started) {
      while ((getline line < f) > 0) {
        buf = buf line "\n"
        while (1) {
          s = index(buf, "<package ")
          if (s == 0) {
            if (!started) pre[f] = pre[f] buf
            buf = ""
            break
          }
          e = index(buf, "</package>")
          if (e == 0 || e < s) break
          if (!started) { started = 1; pre[f] = pre[f] substr(buf, 1, s - 1) }
          seg = substr(buf, s, e + 10 - s)
          arr[name_of(seg)] = seg
          counts[f]++
          buf = substr(buf, e + 10)
        }
      }
      suf[f] = buf
    }
    BEGIN {
      load(IN, A); load(OUT, B)
      if (counts[IN] != counts[OUT]) {
        printf "FAIL package count changed: %d -> %d\n", counts[IN], counts[OUT]
        fails++
      }
      for (n in A) {
        if (!(n in B)) { printf "FAIL missing in output: %s\n", n; fails++; continue }
        if (isuser(A[n])) {
          r = patched(B[n])
          if (r != "") { if (shown < 10) { printf "FAIL %s: %s\n", n, r; shown++ } fails++ }
        } else if (A[n] != B[n]) {
          if (shown < 10) { printf "FAIL system app modified: %s\n", n; shown++ }
          fails++
        }
        total++
      }
      for (n in B) if (!(n in A)) { printf "FAIL unexpected package in output: %s\n", n; fails++ }
      if (pre[IN] != pre[OUT]) { printf "FAIL header changed\n"; fails++ }
      if (suf[IN] != suf[OUT]) { printf "FAIL footer changed\n"; fails++ }
      printf "SUMMARY checked=%d fails=%d\n", total, fails
    }' > "$WORK/report.txt" 2>&1
  grep '^SUMMARY' "$WORK/report.txt" >/dev/null 2>&1 \
    && ok "$(grep '^SUMMARY' "$WORK/report.txt")" \
    || bad "semantic comparison awk did not produce a report"
  grep '^FAIL' "$WORK/report.txt" 2>/dev/null | sed 's/^/    /'
  grep -q 'fails=0' "$WORK/report.txt" 2>/dev/null \
    && ok "all user apps patched; system apps & header/footer byte-identical" \
    || bad "semantic comparison failed (see FAIL lines above)"
else
  bad "output.xml missing — skipping Step D"
fi

# ==============================================================================
hdr "Step E: subsequent-boot simulation (db_prune + db_update)"
# ==============================================================================
if [ "$db_lines" -gt 0 ] && [ $rc -eq 0 ]; then
  DROP=$(head -n 1 "$DB" | cut -d'|' -f1)
  info "dropping package from simulated new boot: $DROP"

  # input2 = input minus $DROP, plus a fake new sideloaded app
  awk -v FILE="$WORK/input.xml" -v DROP="$DROP" '
    function handle_package(seg) {
      if (match(seg, /name="[^"]*"/)) {
        n = substr(seg, RSTART+6, RLENGTH-7)
        if (n == DROP) return ""
      }
      return seg
    }
    BEGIN {
      while ((getline line < FILE) > 0) {
        buf = buf line "\n"
        while (1) {
          s = index(buf, "<package ")
          if (s == 0) { printf "%s", buf; buf = ""; break }
          e = index(buf, "</package>")
          if (e == 0 || e < s) break
          printf "%s", substr(buf, 1, s - 1)
          printf "%s", handle_package(substr(buf, s, e + 10 - s))
          buf = substr(buf, e + 10)
        }
      }
      printf "%s", buf
    }' > "$WORK/input2.xml"
  sed 's|</packages>|<package name="com.bki.debugnew" codePath="/data/app/~~dbg/com.bki.debugnew" system="false" installer="com.android.shell" installerUid="2000" userId="10999"><sigs count="1" /></package></packages>|' \
    "$WORK/input2.xml" > "$WORK/input2.xml.tmp" && mv "$WORK/input2.xml.tmp" "$WORK/input2.xml"

  DB2="$WORK/metadata2.db"
  cp "$DB" "$DB2"
  DB="$DB2"
  t0=$(now)
  db_prune "$WORK/input2.xml"
  prc=$?
  t1=$(now)
  [ ${#t0} -gt 10 ] && info "db_prune elapsed: $(( (t1 - t0) / 1000000 )) ms" || info "db_prune elapsed: $(( t1 - t0 )) s"
  [ $prc -eq 0 ] && ok "db_prune ran cleanly" || bad "db_prune returned failure"

  grep -q "^$DROP|" "$DB2" && bad "pruned DB still contains dropped package $DROP" \
    || ok "prune removed $DROP"
  [ "$(wc -l < "$DB2")" = "$((db_lines - 1))" ] && ok "pruned DB has exactly one entry less" \
    || bad "pruned DB line count wrong: $(wc -l < "$DB2") vs $((db_lines - 1))"

  t0=$(now)
  db_update "$WORK/input2.xml"
  urc=$?
  t1=$(now)
  [ ${#t0} -gt 10 ] && info "db_update elapsed: $(( (t1 - t0) / 1000000 )) ms" || info "db_update elapsed: $(( t1 - t0 )) s"
  [ $urc -eq 0 ] && ok "db_update ran cleanly" || bad "db_update returned failure"
  newcount=$(grep -c '^com.bki.debugnew|' "$DB2")
  [ "$newcount" -eq 1 ] && ok "new package detected and appended exactly once" \
    || bad "new package appears $newcount times (expected 1)"
  dup2=$(awk -F'|' '{ print $1 }' "$DB2" | sort | uniq -d | wc -l)
  [ "$dup2" -eq 0 ] && ok "no duplicate names after scan-append" || bad "$dup2 duplicate names after scan-append"
  [ "$(wc -l < "$DB2")" = "$db_lines" ] && ok "final DB entry count restored to $db_lines" \
    || bad "final DB count $(wc -l < "$DB2") != $db_lines"
else
  bad "Step E skipped (DB empty or patch failed)"
fi

# ==============================================================================
hdr "Step F: end-to-end process_xml (real module entry point)"
# ==============================================================================
DB="$WORK/db_f.db"
rm -f "$DB"
cp "$SRC" "$WORK/live_in.xml"

t0=$(now)
if process_xml "$WORK/live_in.xml"; then
  ok "process_xml completed (log: $WORK/module.log)"
else
  bad "process_xml failed (log: $WORK/module.log)"
  sed 's/^/    | /' "$WORK/module.log" 2>/dev/null | tail -20
fi
t1=$(now)
[ ${#t0} -gt 10 ] && info "process_xml elapsed: $(( (t1 - t0) / 1000000 )) ms" || info "process_xml elapsed: $(( t1 - t0 )) s"

awk -v IN="$WORK/live_ref.xml" -v OUT="$WORK/live_in.xml" -v VU="$VU" '
  function name_of(seg,   n) { if (match(seg, /name="[^"]*"/)) n = substr(seg, RSTART+6, RLENGTH-7); return n "" }
  function isuser(seg) { return (seg ~ /codePath="\/data\/app\// && seg !~ /system="true"/ && seg !~ /system="1"/) }
  function patched(seg) {
    if (seg !~ /installer="com\.android\.vending"/) return "installer"
    if (seg !~ /installInitiator="com\.android\.vending"/) return "installInitiator"
    if (seg !~ ("installerUid(-int)?=\"" VU "\"")) return "installerUid"
    if (seg ~ /installOriginator=/) return "installOriginator-present"
    if (seg ~ /isOrphaned(-bool)?="(true|1)"/) return "isOrphaned-true"
    if (seg ~ /installInitiatorUninstalled(-bool)?="(true|1)"/) return "initiatorUninstalled-true"
    if (seg !~ /packageSource(-int)?="2"/) return "packageSource"
    return ""
  }
  function load(f, arr,   line, buf, s, e, seg, started) {
    while ((getline line < f) > 0) {
      buf = buf line "\n"
      while (1) {
        s = index(buf, "<package ")
        if (s == 0) {
          if (!started) pre[f] = pre[f] buf
          buf = ""
          break
        }
        e = index(buf, "</package>")
        if (e == 0 || e < s) break
        if (!started) { started = 1; pre[f] = pre[f] substr(buf, 1, s - 1) }
        seg = substr(buf, s, e + 10 - s)
        arr[name_of(seg)] = seg
        counts[f]++
        buf = substr(buf, e + 10)
      }
    }
    suf[f] = buf
  }
  BEGIN {
    load(IN, A); load(OUT, B)
    for (n in A) {
      if (!(n in B)) { printf "FAIL missing: %s\n", n; fails++; continue }
      if (isuser(A[n])) {
        r = patched(B[n])
        if (r != "") { printf "FAIL %s: %s\n", n, r; fails++ }
      } else if (A[n] != B[n]) { printf "FAIL system app modified: %s\n", n; fails++ }
      total++
    }
    for (n in B) if (!(n in A)) { printf "FAIL unexpected: %s\n", n; fails++ }
    if (pre[IN] != pre[OUT]) { printf "FAIL header changed\n"; fails++ }
    if (suf[IN] != suf[OUT]) { printf "FAIL footer changed\n"; fails++ }
    printf "SUMMARY checked=%d fails=%d\n", total, fails
  }' > "$WORK/report_f.txt" 2>&1
grep '^FAIL' "$WORK/report_f.txt" 2>/dev/null | sed 's/^/    /'
grep -q 'fails=0' "$WORK/report_f.txt" 2>/dev/null \
  && ok "process_xml output is semantically correct" \
  || bad "process_xml output failed validation"

# Idempotency: a second full run must be a byte-for-byte fixed point.
cp "$WORK/live_in.xml" "$WORK/first_run.xml"
t0=$(now)
process_xml "$WORK/live_in.xml" >/dev/null 2>&1
t1=$(now)
[ ${#t0} -gt 10 ] && info "second run elapsed: $(( (t1 - t0) / 1000000 )) ms" || info "second run elapsed: $(( t1 - t0 )) s"
if cmp -s "$WORK/first_run.xml" "$WORK/live_in.xml"; then
  ok "second process_xml run is byte-identical (idempotent)"
else
  bad "second run changed the file — split or patch is not idempotent"
fi

# ==============================================================================
hdr "Step G: uninstall restore (restore_from_db)"
# ==============================================================================
PFD_UN="${BKI_PFD_UN:-$(dirname "$0")/uninstall.sh}"
if [ -f "$PFD_UN" ] && [ $rc -eq 0 ] && [ "${db_lines:-0}" -gt 0 ]; then
  sed -n '/# ==== BKI UNINSTALL FUNCTIONS START ====/,/# ==== BKI UNINSTALL FUNCTIONS END ====/p' "$PFD_UN" > "$WORK/uninstall_funcs.sh"
  # shellcheck disable=SC1090
  if . "$WORK/uninstall_funcs.sh"; then
    cp "$WORK/output.xml" "$WORK/restored.xml"
    t0=$(now)
    if restore_from_db "$WORK/restored.xml" "$WORK/metadata.db"; then
      ok "restore_from_db ran cleanly"
    else
      bad "restore_from_db failed"
    fi
    t1=$(now)
    [ ${#t0} -gt 10 ] && info "restore elapsed: $(( (t1 - t0) / 1000000 )) ms" || info "restore elapsed: $(( t1 - t0 )) s"

    # Semantic check: DB-known packages must match ORIGINAL attributes,
    # everything else must keep the patched state.
    if command -v python3 >/dev/null 2>&1; then
      RESTORE_REPORT=$(ORIG="$WORK/input.xml" PATCHED="$WORK/output.xml" RESTORED="$WORK/restored.xml" DB="$WORK/metadata.db" python3 - 2>&1 <<'PYEOF'
import os, sys
import xml.etree.ElementTree as ET
def load(path):
    return {p.get('name'): dict(p.attrib) for p in ET.parse(path).getroot().iter('package')}
orig = load(os.environ['ORIG'])
patched = load(os.environ['PATCHED'])
restored = load(os.environ['RESTORED'])
dbnames = set()
with open(os.environ['DB']) as fh:
    for line in fh:
        s = line.strip()
        if s and not s.startswith('#'):
            dbnames.add(s.split('|', 1)[0])
mism = []
for name in set(orig) | set(patched) | set(restored):
    r = restored.get(name)
    if r is None:
        mism.append(name + ' : missing-in-restored')
        continue
    want = orig.get(name) if name in dbnames else patched.get(name)
    if r != want:
        mism.append(name + ' : attrs-differ')
print(len(mism))
for m in mism[:10]:
    print(m)
PYEOF
)
      nmis=$(printf '%s\n' "$RESTORE_REPORT" | sed -n '1p')
      case "$nmis" in
        0) ok "restored attributes == original (DB-known) or patched (unknown)" ;;
        *[!0-9]*) bad "restore check crashed"; printf '%s\n' "$RESTORE_REPORT" | sed 's/^/    /' ;;
        *) bad "$nmis package(s) restored incorrectly"; printf '%s\n' "$RESTORE_REPORT" | tail -n +2 | sed 's/^/    /' ;;
      esac
    else
      info "python3 unavailable — skipping restore semantic check"
    fi

    # Restore idempotency: a second pass must be a byte-identical fixed point.
    cp "$WORK/restored.xml" "$WORK/restored_once.xml"
    restore_from_db "$WORK/restored.xml" "$WORK/metadata.db" >/dev/null 2>&1
    if cmp -s "$WORK/restored_once.xml" "$WORK/restored.xml"; then
      ok "second restore run is byte-identical (idempotent)"
    else
      bad "second restore changed the file"
    fi
  else
    bad "failed to source uninstall functions"
  fi
else
  info "Step G skipped (uninstall.sh not found, or earlier steps failed)"
fi

# ==============================================================================
hdr "Summary"
# ==============================================================================
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$KEEP" -eq 1 ]; then
  printf 'Work dir kept: %s\n' "$WORK"
  printf '  input : %s\n  output: %s\n  db    : %s\n' "$WORK/input.xml" "$WORK/output.xml" "$WORK/metadata.db"
fi
[ "$FAIL" -eq 0 ]
