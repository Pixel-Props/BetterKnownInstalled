#!/system/bin/busybox sh

MODPATH="${0%/*}"
MODNAME="${MODPATH##*/}"

PACKAGES_XML="/data/system/packages.xml"
DB="$MODPATH/metadata.db"
CURRENT_TIMESTAMP=$(date +%s)

[ -z "$MODPATH" ] || ! echo "$MODPATH" | grep -q '/data/adb/modules/' &&
  MODPATH="$(dirname "$(readlink -f "$0")")"

[ -f "$MODPATH/util_functions.sh" ] && . "$MODPATH/util_functions.sh" || abort "! util_functions.sh not found!"

wait_for_data

[ ! -f "$PACKAGES_XML" ] && { ui_print "packages.xml not found. Nothing to restore."; exit 0; }
[ ! -f "$DB" ] && { ui_print "metadata.db not found. Nothing to restore."; exit 0; }

ui_print "BKI v1.6.0 uninstall restore starting..."

# Safety backup before we touch anything
mkdir -p /data/local/tmp/BKI_restore_backups
cp -f "$PACKAGES_XML" "/data/local/tmp/BKI_restore_backups/packages_$(date +%s).xml"
ui_print "Safety backup created in /data/local/tmp/BKI_restore_backups/"

# Determine format
file_type=$(file -b "$PACKAGES_XML")
is_text_xml=false
if echo "$file_type" | grep -q -E "XML .* text|text"; then
  is_text_xml=true
fi

xml_temp="$MODPATH/temp_uninstall_$CURRENT_TIMESTAMP.xml"

if boolval "$is_text_xml"; then
  ui_print "File is text XML. Copying to temp..."
  cp "$PACKAGES_XML" "$xml_temp"
else
  ui_print "Converting ABX to text for restore..."
  if ! abx_to_text "$PACKAGES_XML" "$xml_temp"; then
    ui_print "Error: abx_to_text failed during uninstall!"
    rm "$xml_temp" 2>/dev/null
    exit 1
  fi
fi

# Normalize
sed -i 's/<package /\n<package /g' "$xml_temp"
sed -i '1{/^$/d}' "$xml_temp"

# Restore original values from DB
ui_print "Restoring original values from metadata.db..."
awk -F'|' '
  BEGIN { db = ARGV[1] }
  FILENAME == db {
    if ($0 ~ /^#/) next
    db_installer[$1] = $2
    db_uid[$1] = $3
    db_initiator[$1] = $4
    db_source[$1] = $5
    db_originator[$1] = $6
    db_orphaned[$1] = $7
    db_uninstalled[$1] = $8
    next
  }
  /^<package / {
    name = ""
    if (match($0, /name="[^"]*"/)) name = substr($0, RSTART+6, RLENGTH-7)
    if (name in db_installer) {
      gsub(/ *installer="[^"]*"/, "", $0)
      gsub(/ *installerUid="[^"]*"/, "", $0)
      gsub(/ *installerUid-int="[^"]*"/, "", $0)
      gsub(/ *installInitiator="[^"]*"/, "", $0)
      gsub(/ *packageSource="[^"]*"/, "", $0)
      gsub(/ *installOriginator="[^"]*"/, "", $0)
      gsub(/ *isOrphaned="[^"]*"/, "", $0)
      gsub(/ *installInitiatorUninstalled="[^"]*"/, "", $0)

      inject = ""
      if (db_installer[name] != "") inject = inject " installer=\"" db_installer[name] "\""
      if (db_uid[name] != "") inject = inject " installerUid=\"" db_uid[name] "\""
      if (db_initiator[name] != "") inject = inject " installInitiator=\"" db_initiator[name] "\""
      if (db_source[name] != "") inject = inject " packageSource=\"" db_source[name] "\""
      if (db_originator[name] != "") inject = inject " installOriginator=\"" db_originator[name] "\""
      if (db_orphaned[name] != "") inject = inject " isOrphaned=\"" db_orphaned[name] "\""
      if (db_uninstalled[name] != "") inject = inject " installInitiatorUninstalled=\"" db_uninstalled[name] "\""

      if (inject != "") sub(/<package /, "<package" inject " ", $0)
    }
  }
  { print }
' "$DB" "$xml_temp" > "${xml_temp}.tmp"
mv -f "${xml_temp}.tmp" "$xml_temp"

# Collapse back
tr '\n' ' ' < "$xml_temp" | sed 's/> </></g' > "${xml_temp}.collapsed"
mv -f "${xml_temp}.collapsed" "$xml_temp"

# Convert back if original was ABX
if ! boolval "$is_text_xml"; then
  ui_print "Converting restored text back to ABX..."
  abxml_out="$MODPATH/temp_uninstall_restored_$CURRENT_TIMESTAMP.abxml"
  if ! text_to_abx "$xml_temp" "$abxml_out"; then
    ui_print "Error: text_to_abx failed during uninstall!"
    rm "$xml_temp" "$abxml_out" 2>/dev/null
    exit 1
  fi
  rm -f "$xml_temp"
  xml_temp="$abxml_out"
fi

# Atomic replace
ui_print "Writing restored packages.xml..."
cat "$xml_temp" > "$PACKAGES_XML.tmp" || {
  ui_print "Error: Failed to stage restored file."
  rm "$xml_temp" "$PACKAGES_XML.tmp" 2>/dev/null
  exit 1
}
mv -f "$PACKAGES_XML.tmp" "$PACKAGES_XML" || {
  ui_print "Error: Failed to atomically replace packages.xml."
  rm "$xml_temp" 2>/dev/null
  exit 1
}

# Verify
if ! cmp -s "$PACKAGES_XML" "$xml_temp"; then
  ui_print "Error: Verification failed after restore!"
  rm "$xml_temp" 2>/dev/null
  exit 1
fi

rm -f "$xml_temp" "$DB"

ui_print "Restoring permissions and SELinux context..."
for file in "$PACKAGES_XML"; do
  chown system:system "$file"
  chmod 640 "$file"
  if command_exists restorecon; then
    restorecon "$file"
  fi
done

ui_print "BKI uninstall restore completed successfully."
