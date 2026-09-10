#!/system/bin/busybox sh
# BetterKnownInstalled (BKI) — post-fs-data.sh v1.6.1
# Patches installer metadata in packages.xml to defeat DroidGuard
# UNKNOWN_INSTALLED verdicts on user apps.
#
# Layout:
#   1. Shared awk fragments — plain text in single-quoted heredocs, assembled
#      into awk programs via "..." concatenation (no eval, no quote juggling;
#      fragments must never contain a literal $ or backtick).
#   2. Shell functions, one job each.
#   3. main().
#
# Every awk program streams the pre-split working copy line by line and hands
# exactly one <package>...</package> segment at a time to handle_package().

MODPATH="${0%/*}"
MODNAME="${MODPATH##*/}"

PACKAGES_XML="/data/system/packages.xml"
DB="$MODPATH/metadata.db"
CURRENT_TIMESTAMP=$(date +%s)

[ -z "$MODPATH" ] || ! echo "$MODPATH" | grep -q '/data/adb/modules/' &&
  MODPATH="$(dirname "$(readlink -f "$0")")"

[ -f "$MODPATH/util_functions.sh" ] && . "$MODPATH/util_functions.sh" || abort "! util_functions.sh not found!"

# ==== BKI FUNCTIONS START ====

# ---------------------------------------------------------------------------
# Shared awk fragments (heredoc-quoted: literal text, no shell expansion).
# ---------------------------------------------------------------------------

# Walker, scanner flavour: discards inter-package text.
# The awk program using it must define handle_package(seg).
AWK_WALKER_SCAN=$(cat <<'AWK_EOF'
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
AWK_EOF
)

# Walker, printer flavour: echoes inter-package text verbatim; handle_package
# must return the (possibly modified) segment. Ends with the trailing flush.
AWK_WALKER_PRINT=$(cat <<'AWK_EOF'
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
AWK_EOF
)

# DB record extractor: prints name|installer|installerUid|installInitiator|
# packageSource|installOriginator|isOrphaned|installInitiatorUninstalled for
# user apps. -v SKIP_SEEN=1 additionally suppresses names present in seen[].
AWK_DB_SCAN=$(cat <<'AWK_EOF'
      function handle_package(seg,   name, codePath, issystem, installer, installerUid, installInitiator, packageSource, installOriginator, isOrphaned, installInitiatorUninstalled) {
        name = ""; codePath = ""; issystem = ""; installer = ""; installerUid = ""
        installInitiator = ""; packageSource = ""; installOriginator = ""; isOrphaned = ""
        installInitiatorUninstalled = ""
        if (match(seg, /name="[^"]*"/))       name = substr(seg, RSTART+6, RLENGTH-7)
        if (match(seg, /codePath="[^"]*"/))    codePath = substr(seg, RSTART+10, RLENGTH-11)
        if (match(seg, /system="[^"]*"/))      issystem = substr(seg, RSTART+8, RLENGTH-9)
        if (match(seg, /installer="[^"]*"/))   installer = substr(seg, RSTART+11, RLENGTH-12)
        if (match(seg, /installerUid="[^"]*"/)) installerUid = substr(seg, RSTART+14, RLENGTH-15)
        else if (match(seg, /installerUid-int="[^"]*"/)) installerUid = substr(seg, RSTART+18, RLENGTH-19)
        if (match(seg, /installInitiator="[^"]*"/)) installInitiator = substr(seg, RSTART+18, RLENGTH-19)
        if (match(seg, /packageSource="[^"]*"/)) packageSource = substr(seg, RSTART+15, RLENGTH-16)
        else if (match(seg, /packageSource-int="[^"]*"/)) packageSource = substr(seg, RSTART+19, RLENGTH-20)
        if (match(seg, /installOriginator="[^"]*"/)) installOriginator = substr(seg, RSTART+19, RLENGTH-20)
        if (match(seg, /isOrphaned="[^"]*"/))  isOrphaned = substr(seg, RSTART+12, RLENGTH-13)
        else if (match(seg, /isOrphaned-bool="[^"]*"/)) isOrphaned = substr(seg, RSTART+17, RLENGTH-18)
        if (match(seg, /installInitiatorUninstalled="[^"]*"/)) installInitiatorUninstalled = substr(seg, RSTART+29, RLENGTH-30)
        else if (match(seg, /installInitiatorUninstalled-bool="[^"]*"/)) installInitiatorUninstalled = substr(seg, RSTART+33, RLENGTH-34)
        if (codePath ~ /\/data\/app\// && issystem != "true" && issystem != "1" && (!SKIP_SEEN || !(name in seen))) {
          print name "|" installer "|" installerUid "|" installInitiator "|" packageSource "|" installOriginator "|" isOrphaned "|" installInitiatorUninstalled
        }
      }
AWK_EOF
)

# Preload seen[] from the DB (used by db_update).
AWK_SEEN_PRELOAD=$(cat <<'AWK_EOF'
      function preload_seen(   line, f) {
        while ((getline line < DB) > 0)
          if (line !~ /^#/) { split(line, f, "|"); seen[f[1]] = 1 }
        close(DB)
      }
AWK_EOF
)

# Prune helpers: collect current package names, then echo DB lines that still
# exist (used by db_prune).
AWK_PRUNE_FNS=$(cat <<'AWK_EOF'
      function handle_package(seg) {
        if (match(seg, /name="[^"]*"/)) {
          n = substr(seg, RSTART+6, RLENGTH-7)
          current[n] = 1
        }
      }
      function finish_prune(   line, f) {
        while ((getline line < DB) > 0) {
          if (line ~ /^#/) continue
          split(line, f, "|")
          if (f[1] in current) print line
        }
        close(DB)
      }
AWK_EOF
)

# vending_uid lookups (used by resolve_vending_uid).
AWK_VENDING_FN=$(cat <<'AWK_EOF'
      function handle_package(seg) {
        if (seg ~ /name="com\.android\.vending"/ && match(seg, /userId(-int)?="[0-9]+"/)) {
          uid = substr(seg, RSTART, RLENGTH)
          gsub(/[^0-9]/, "", uid)
          print uid
          exit
        }
      }
AWK_EOF
)

AWK_VENDING_FALLBACK_FN=$(cat <<'AWK_EOF'
      function handle_package(seg) {
        if (seg ~ /codePath="\/data\/app\// && seg !~ /system="true"/ && seg !~ /system="1"/ \
            && (seg ~ /installer="com\.android\.vending"/ || seg ~ /installInitiator="com\.android\.vending"/) \
            && match(seg, /installerUid(-int)?="[0-9]+"/)) {
          uid = substr(seg, RSTART, RLENGTH)
          gsub(/[^0-9]/, "", uid)
          print uid
          exit
        }
      }
AWK_EOF
)

# The actual UNKNOWN_INSTALLED patch (used by patch_user_apps).
AWK_PATCH_FN=$(cat <<'AWK_EOF'
      function handle_package(seg) {
        # Skip anything that is not a user app in /data/app
        if (seg !~ /codePath="\/data\/app\// || seg ~ /system="true"/ || seg ~ /system="1"/) return seg

        # 1: installer (add if missing, then normalize all to Play Store)
        if (seg !~ /installer=/) sub(/<package /, "<package installer=\"com.android.vending\" ", seg)
        gsub(/installer="[^"]*"/, "installer=\"com.android.vending\"", seg)

        # 2: installInitiator
        if (seg !~ /installInitiator=/) sub(/<package /, "<package installInitiator=\"com.android.vending\" ", seg)
        gsub(/installInitiator="[^"]*"/, "installInitiator=\"com.android.vending\"", seg)

        # 3: installerUid (plain + -int ABX variants)
        if (seg !~ /installerUid(-int)?=/) sub(/<package /, "<package installerUid=\"" VENDING_UID "\" ", seg)
        gsub(/installerUid-int="[^"]*"/, "installerUid-int=\"" VENDING_UID "\"", seg)
        gsub(/installerUid="[^"]*"/, "installerUid=\"" VENDING_UID "\"", seg)

        # 4: remove installOriginator
        gsub(/[ \r\n\t]+installOriginator="[^"]*"/, "", seg)

        # 5: remove isOrphaned if true/1 (plain + -bool)
        gsub(/[ \r\n\t]+isOrphaned(-bool)?="(true|1)"/, "", seg)

        # 6: remove installInitiatorUninstalled if true/1 (plain + -bool)
        gsub(/[ \r\n\t]+installInitiatorUninstalled(-bool)?="(true|1)"/, "", seg)

        # 7: packageSource -> 2 (plain + -int), add if missing
        gsub(/packageSource-int="[^"]*"/, "packageSource-int=\"2\"", seg)
        gsub(/packageSource="[^"]*"/, "packageSource=\"2\"", seg)
        if (seg !~ /packageSource(-int)?=/) sub(/<package /, "<package packageSource=\"2\" ", seg)

        return seg
      }
AWK_EOF
)

# ---------------------------------------------------------------------------
# XML pipeline helpers
# ---------------------------------------------------------------------------

# Create the pre-split text working copy of $1.
# Sets globals: xml_temp, is_text_xml (true/false).
# The sed split is idempotent: it inserts a newline after any </package>
# directly followed by another character, which keeps awk buffers small on
# single-line files without growing the file on repeated boots.
make_work_copy() {
  xml_temp="$MODPATH/temp_${base_name_no_ext}_$CURRENT_TIMESTAMP.xml"

  if file -b "$1" | grep -q -E "XML .* text|text"; then
    is_text_xml=true
    ui_print "File is text XML. Proceeding with modifications."
    cp "$1" "$xml_temp"
  else
    is_text_xml=false
    ui_print "Converting ABX to text: $1 -> $xml_temp"
    abx_to_text "$1" "$xml_temp" || return 1
  fi

  sed -i 's|</package>\(.\)|</package>\n\1|g' "$xml_temp"
}

# Echo the numeric userId of com.android.vending, or nothing on failure.
# Method 1: vending's own <package> element. Method 2 (fallback): steal
# installerUid from any user app installed by the Play Store.
resolve_vending_uid() {
  local uid

  uid=$(awk -v FILE="$1" "$AWK_VENDING_FN
BEGIN {
$AWK_WALKER_SCAN
}")

  if [ -z "$uid" ]; then
    ui_print "  Fallback: extracting installerUid from existing Play Store app..."
    uid=$(awk -v FILE="$1" "$AWK_VENDING_FALLBACK_FN
BEGIN {
$AWK_WALKER_SCAN
}")
  fi

  [ -n "$uid" ] && printf '%s' "$uid"
}

safety_backup() {
  cp -f "$1" "$MODPATH/packages.xml.safety"
}

# ---------------------------------------------------------------------------
# metadata.db maintenance ($1 = pre-split xml file; uses global $DB)
# ---------------------------------------------------------------------------

# First boot: build the DB from scratch.
db_build() {
  awk -v FILE="$1" -v SKIP_SEEN=0 "$AWK_DB_SCAN
BEGIN {
$AWK_WALKER_SCAN
}" > "$DB.tmp" || { rm -f "$DB.tmp"; return 1; }
  mv -f "$DB.tmp" "$DB"
}

# Subsequent boot: drop entries for packages that no longer exist.
db_prune() {
  awk -v FILE="$1" -v DB="$DB" "$AWK_PRUNE_FNS
BEGIN {
$AWK_WALKER_SCAN
      finish_prune()
}" > "$DB.tmp" || { rm -f "$DB.tmp"; return 1; }
  mv -f "$DB.tmp" "$DB"
}

# Subsequent boot: append entries for user apps not yet in the DB.
db_update() {
  awk -v FILE="$1" -v DB="$DB" -v SKIP_SEEN=1 "$AWK_DB_SCAN
$AWK_SEEN_PRELOAD
BEGIN {
      preload_seen()
$AWK_WALKER_SCAN
}" >> "$DB" || return 1
}

# ---------------------------------------------------------------------------
# The actual patch (single streaming pass, in place)
# ---------------------------------------------------------------------------

# Rewrite installer/installerUid/installInitiator to com.android.vending,
# strip originator/orphan flags, force packageSource=2 on user apps only.
patch_user_apps() {
  awk -v VENDING_UID="$2" -v FILE="$1" "$AWK_PATCH_FN
BEGIN {
$AWK_WALKER_PRINT
}" > "$1.tmp" || { rm -f "$1.tmp"; return 1; }
  mv "$1.tmp" "$1"
}

# Convert the working copy back (ABX if needed) and atomically replace $1,
# then verify. Uses globals set by make_work_copy/patch_user_apps.
write_back() {
  if boolval "$is_text_xml"; then
    ui_print "Original file was text XML. Replacing with modified text XML."
    replacement_source="$xml_temp"
  else
    ui_print "Original file was ABX. Converting text to ABX before replacing."
    abxml_out="$MODPATH/temp_${base_name_no_ext}_restored_$CURRENT_TIMESTAMP.abxml"
    text_to_abx "$xml_temp" "$abxml_out" || return 1
    replacement_source="$abxml_out"
  fi

  ui_print "Replacing original file: $1 <- $replacement_source"
  cat "$replacement_source" > "$1.tmp" || return 1
  mv -f "$1.tmp" "$1" || return 1

  ui_print "Verifying replacement: $1 vs $replacement_source"
  cmp -s "$1" "$replacement_source" || return 1
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

process_xml() {
  xml_file="$1"
  base_name=$(basename "$xml_file")
  base_name_no_ext="${base_name%.*}"
  abxml_out=""

  ui_print "Starting to process XML file: $xml_file"

  if ! make_work_copy "$xml_file"; then
    ui_print "Error: abx_to_text failed!"
    cat "$xml_file" >"$MODPATH/abx_to_text_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.abx" 2>/dev/null
    rm -f "$xml_temp"
    return 1
  fi

  ui_print "Finding userId for com.android.vending in $xml_temp..."
  vending_uid=$(resolve_vending_uid "$xml_temp")
  ui_print "  Resolved vending_uid: '$vending_uid'"

  case "$vending_uid" in
    ''|*[!0-9]*)
      ui_print "Error: Could not find userId for com.android.vending in $xml_temp"
      rm -f "$xml_temp"
      return 1
      ;;
  esac

  if [ "$vending_uid" -eq 0 ] 2>/dev/null; then
    ui_print "Warning: vending_uid resolved to 0, which is suspicious. Aborting."
    rm -f "$xml_temp"
    return 1
  fi

  ui_print "Found userId for com.android.vending: $vending_uid"

  if [ ! -f "$DB" ]; then
    ui_print "First boot detected. Building metadata.db..."
    safety_backup "$xml_temp"
    db_build "$xml_temp" || { ui_print "Error: db_build failed!"; rm -f "$xml_temp"; return 1; }
    ui_print "Metadata DB built with $(grep -c -v '^#' "$DB" 2>/dev/null || echo 0) entries."
  else
    ui_print "Subsequent boot. Pruning and updating metadata.db..."
    db_prune "$xml_temp" || { ui_print "Error: db_prune failed!"; rm -f "$xml_temp"; return 1; }
    ui_print "DB pruned. Entries: $(grep -c -v '^#' "$DB" 2>/dev/null || echo 0)"
    db_update "$xml_temp" || { ui_print "Error: db_update failed!"; rm -f "$xml_temp"; return 1; }
    ui_print "New packages scanned. Total DB entries: $(grep -c -v '^#' "$DB" 2>/dev/null || echo 0)"
  fi

  ui_print "Patching installer metadata (single awk pass)..."
  patch_user_apps "$xml_temp" "$vending_uid" || {
    ui_print "Error: awk modification failed!"
    rm -f "$xml_temp"
    return 1
  }

  if ! write_back "$xml_file"; then
    ui_print "Error: Verification failed after replacement!"
    diff -u "$xml_file" "$replacement_source" >"$MODPATH/diff_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.diff" 2>/dev/null
    rm -f "$xml_temp" "$abxml_out"
    return 1
  fi

  ui_print "Cleaning up temporary files..."
  rm -f "$xml_temp" "$abxml_out"

  ui_print "Successfully processed XML file: $xml_file"
  return 0
}

# ==== BKI FUNCTIONS END ====

main() {
  ensure_abx_tools || exit 1

  wait_for_data

  if [ -f "$PACKAGES_XML" ]; then
    ui_print "Processing $PACKAGES_XML..."
    process_xml "$PACKAGES_XML"
  fi

  restore_perms

  ui_print "----------------------------------------"
  ui_print "Process completed successfully."
  ui_print "It is recommended to reboot your device for changes to take effect."
  ui_print "by @T3SL4"
  ui_print "----------------------------------------"
}

main "$@"
