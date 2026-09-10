#!/system/bin/busybox sh
# BetterKnownInstalled (BKI) — uninstall.sh v1.6.1
# Restores the original installer metadata in packages.xml from metadata.db
# and removes the DB.

MODPATH="${0%/*}"
MODNAME="${MODPATH##*/}"

PACKAGES_XML="/data/system/packages.xml"
DB="$MODPATH/metadata.db"
CURRENT_TIMESTAMP=$(date +%s)

[ -z "$MODPATH" ] || ! echo "$MODPATH" | grep -q '/data/adb/modules/' &&
  MODPATH="$(dirname "$(readlink -f "$0")")"

[ -f "$MODPATH/util_functions.sh" ] && . "$MODPATH/util_functions.sh" || abort "! util_functions.sh not found!"

# ==== BKI UNINSTALL FUNCTIONS START ====

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

# Restore engine: for packages recorded in the DB, strip every installer
# related attribute (all plain/-int/-bool variants) and re-inject the stored
# original values. Packages not in the DB pass through untouched.
# The tag opening is rebuilt by plain concatenation — no sub(), so no
# runtime replacement-string processing can mangle injected values.
AWK_RESTORE_FN=$(cat <<'AWK_EOF'
      function load_db(   line, f) {
        while ((getline line < DB) > 0) {
          if (line ~ /^#/) continue
          split(line, f, "|")
          db_installer[f[1]] = f[2]
          db_uid[f[1]] = f[3]
          db_initiator[f[1]] = f[4]
          db_source[f[1]] = f[5]
          db_originator[f[1]] = f[6]
          db_orphaned[f[1]] = f[7]
          db_uninstalled[f[1]] = f[8]
        }
        close(DB)
      }
      function handle_package(seg,   name, inject, p) {
        if (!match(seg, /name="[^"]*"/)) return seg
        name = substr(seg, RSTART+6, RLENGTH-7)
        if (!(name in db_installer)) return seg

        gsub(/[ \r\n\t]+installer="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+installerUid="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+installerUid-int="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+installInitiator="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+packageSource="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+packageSource-int="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+installOriginator="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+isOrphaned="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+isOrphaned-bool="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+installInitiatorUninstalled="[^"]*"/, "", seg)
        gsub(/[ \r\n\t]+installInitiatorUninstalled-bool="[^"]*"/, "", seg)

        inject = ""
        if (db_installer[name] != "")    inject = inject " installer=\"" db_installer[name] "\""
        if (db_uid[name] != "")          inject = inject " installerUid=\"" db_uid[name] "\""
        if (db_initiator[name] != "")    inject = inject " installInitiator=\"" db_initiator[name] "\""
        if (db_source[name] != "")       inject = inject " packageSource=\"" db_source[name] "\""
        if (db_originator[name] != "")   inject = inject " installOriginator=\"" db_originator[name] "\""
        if (db_orphaned[name] != "")     inject = inject " isOrphaned=\"" db_orphaned[name] "\""
        if (db_uninstalled[name] != "")  inject = inject " installInitiatorUninstalled=\"" db_uninstalled[name] "\""

        if (inject != "") {
          p = index(seg, "<package ")
          if (p > 0) seg = "<package" inject " " substr(seg, p + 9)
        }
        return seg
      }
AWK_EOF
)

safety_backup() {
  mkdir -p /data/local/tmp/BKI_restore_backups
  cp -f "$1" "/data/local/tmp/BKI_restore_backups/packages_$(date +%s).xml"
}

# Create the pre-split text working copy of $1.
# Sets globals: xml_temp, is_text_xml (true/false).
make_work_copy() {
  xml_temp="$MODPATH/temp_uninstall_$CURRENT_TIMESTAMP.xml"

  if file -b "$1" | grep -q -E "XML .* text|text"; then
    is_text_xml=true
    ui_print "File is text XML. Proceeding with restore."
    cp "$1" "$xml_temp"
  else
    is_text_xml=false
    ui_print "Converting ABX to text: $1 -> $xml_temp"
    abx_to_text "$1" "$xml_temp" || return 1
  fi

  sed -i 's|</package>\(.\)|</package>\n\1|g' "$xml_temp"
}

# Restore original attributes from the DB ($2) into the xml ($1), in place.
restore_from_db() {
  awk -v FILE="$1" -v DB="$2" "$AWK_RESTORE_FN
BEGIN {
      load_db()
$AWK_WALKER_PRINT
}" > "$1.tmp" || { rm -f "$1.tmp"; return 1; }
  mv "$1.tmp" "$1"
}

# Convert the working copy back (ABX if needed) and atomically replace $1,
# then verify. Uses globals set by make_work_copy.
write_back() {
  if boolval "$is_text_xml"; then
    ui_print "Original file was text XML. Replacing with restored text XML."
    replacement_source="$xml_temp"
  else
    ui_print "Original file was ABX. Converting restored text back to ABX."
    abxml_out="$MODPATH/temp_uninstall_restored_$CURRENT_TIMESTAMP.abxml"
    text_to_abx "$xml_temp" "$abxml_out" || return 1
    replacement_source="$abxml_out"
  fi

  ui_print "Replacing original file: $1 <- $replacement_source"
  cat "$replacement_source" > "$1.tmp" || return 1
  mv -f "$1.tmp" "$1" || return 1

  ui_print "Verifying replacement: $1 vs $replacement_source"
  cmp -s "$1" "$replacement_source" || return 1
}

# ==== BKI UNINSTALL FUNCTIONS END ====

main() {
  wait_for_data

  [ ! -f "$PACKAGES_XML" ] && { ui_print "packages.xml not found. Nothing to restore."; exit 0; }
  [ ! -f "$DB" ] && { ui_print "metadata.db not found. Nothing to restore."; exit 0; }

  ui_print "BKI v1.6.1 uninstall restore starting..."

  if safety_backup "$PACKAGES_XML"; then
    ui_print "Safety backup created in /data/local/tmp/BKI_restore_backups/"
  else
    ui_print "Warning: safety backup failed — continuing without it."
  fi

  abxml_out=""

  if ! make_work_copy "$PACKAGES_XML"; then
    ui_print "Error: abx_to_text failed during uninstall!"
    rm -f "$xml_temp"
    exit 1
  fi

  ui_print "Restoring original values from metadata.db..."
  if ! restore_from_db "$xml_temp" "$DB"; then
    ui_print "Error: restore failed!"
    rm -f "$xml_temp"
    exit 1
  fi

  if ! write_back "$PACKAGES_XML"; then
    ui_print "Error: Verification failed after restore!"
    diff -u "$PACKAGES_XML" "$replacement_source" >"$MODPATH/diff_uninstall_error_$CURRENT_TIMESTAMP.diff" 2>/dev/null
    rm -f "$xml_temp" "$abxml_out"
    exit 1
  fi

  ui_print "Cleaning up..."
  rm -f "$xml_temp" "$abxml_out" "$DB"

  restore_perms

  ui_print "BKI uninstall restore completed successfully."
  exit 0
}

main "$@"
