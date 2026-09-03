#!/system/bin/busybox sh

MODPATH="${0%/*}"
MODNAME="${MODPATH##*/}"

PACKAGES_XML="/data/system/packages.xml"
BACKUP_DIR="$MODPATH/backup"
MAX_BACKUP_FILES=4
CURRENT_TIMESTAMP=$(date +%s)

[ -z "$MODPATH" ] || ! echo "$MODPATH" | grep -q '/data/adb/modules/' &&
 MODPATH="$(dirname "$(readlink -f "$0")")"

[ -f "$MODPATH/util_functions.sh" ] && . "$MODPATH/util_functions.sh" || abort "! util_functions.sh not found!"

wait_for_data() {
 max_wait_time=30
 wait_interval=1
 i=0
 while [ "$i" -lt "$max_wait_time" ]; do
   if mount | grep -q "/data " && [ -f "$PACKAGES_XML" ]; then
     ui_print "/data is mounted and accessible."
     return 0
   fi
   ui_print "Waiting for /data to become accessible..."
   sleep "$wait_interval"
   i=$((i + wait_interval))
 done
 ui_print "Error: /data or $PACKAGES_XML did not become accessible within $max_wait_time seconds."
 return 1
}

process_xml() {
  xml_file="$1"
  base_name=$(basename "$xml_file")
  base_name_no_ext="${base_name%.*}"

  xml_temp="$MODPATH/temp_${base_name_no_ext}_$CURRENT_TIMESTAMP.xml"
  xml_backup_file="$BACKUP_DIR/${base_name_no_ext}_$CURRENT_TIMESTAMP.xml"
  abxml_backup_file="$BACKUP_DIR/${base_name_no_ext}_$CURRENT_TIMESTAMP.abxml"

  ui_print "Starting to process XML file: $xml_file"

  ui_print "Creating backup of $xml_file..."
  backup_file_path=$(backup_file "$xml_file" "bak")
  backup_status=$?

  if [ $backup_status -eq 0 ]; then
    ui_print "Backup file path: $backup_file_path"
    abxml_original_backup_file="$backup_file_path"
  else
    ui_print "Error: backup_file failed."
    return 1
  fi

  file_type=$(file -b "$abxml_original_backup_file")
  is_text_xml=false
  if echo "$file_type" | grep -q -E "XML .* text|text"; then
    is_text_xml=true
  fi

  ui_print "abxml_original_backup_file is: Text XML"

  if boolval "$is_text_xml"; then
    ui_print "File is already text XML. Proceeding with modifications."
    cp "$abxml_original_backup_file" "$xml_temp"
  else
    ui_print "Converting ABX to text: $abxml_original_backup_file -> $xml_temp"
    if ! abx_to_text "$abxml_original_backup_file" "$xml_temp"; then
      ui_print "Error: abx_to_text failed!"
      cat "$abxml_original_backup_file" >"$MODPATH/abx_to_text_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.abx"
      rm "$xml_temp" 2>/dev/null
      return 1
    fi
  fi

  ui_print "Finding userId for com.android.vending in $xml_temp..."

  # Method 1: vending's own <package> line
  vending_uid=$(grep -oE '<package [^>]*name="com\.android\.vending"[^>]*>' "$xml_temp" | grep -oE 'userId="[0-9]+"' | head -1 | cut -d'"' -f2)

  # Method 2 (fallback): steal installerUid from any existing Play Store app
  if [ -z "$vending_uid" ]; then
    ui_print "  Fallback: extracting installerUid from existing Play Store app..."
    vending_uid=$(grep -oE '<package [^>]*installer="com\.android\.vending"[^>]*>' "$xml_temp" | grep -oE 'installerUid="[0-9]+"' | head -1 | cut -d'"' -f2)
  fi

  ui_print "  Resolved vending_uid: '$vending_uid'"

  if [ -z "$vending_uid" ]; then
    ui_print "Error: Could not find userId for com.android.vending in $xml_temp"
    rm "$xml_temp"
    return 1
  fi

  if [ "$vending_uid" -eq 0 ] 2>/dev/null; then
    ui_print "Warning: vending_uid resolved to 0, which is suspicious. Aborting."
    rm "$xml_temp"
    return 1
  fi

  ui_print "Found userId for com.android.vending: $vending_uid"

  ui_print "Starting to modify XML with sed..."

  # DRY: only process user apps in /data/app/, skip everything else
  SYS_SKIP='
    /^<package /!b
    /codePath="\/data\/app\//!b
    /system="true"/b
    /system="1"/b
  '

  # Normalize: split single-line XML so each <package ...> sits on its own line
  sed -i 's/<package /\n<package /g' "$xml_temp"
  sed -i '1{/^$/d}' "$xml_temp"

  # Pass 1: dedup installer, installInitiator, installerUid
  sed -i -E \
    -e "$SYS_SKIP" \
    -e ':begin' \
    -e 's/(( *installer="[^"]*")+)(.*)( *installer="[^"]*")+/\1\3/g' \
    -e 't begin' \
    -e ':begin2' \
    -e 's/(( *installInitiator="[^"]*")+)(.*)( *installInitiator="[^"]*")+/\1\3/g' \
    -e 't begin2' \
    -e ':begin3' \
    -e 's/(( *installerUid(-int)?="[^"]*")+)(.*)( *installerUid(-int)?="[^"]*")+/\1\3/g' \
    -e 't begin3' \
    "$xml_temp"

  # Pass 2: replace or add installer
  sed -i -E \
    -e "$SYS_SKIP" \
    -e '/installer=/ { s/(installer=")[^"]*/\1com.android.vending/g }' \
    -e '/installer=/! s/(<package [^>]*)/ \1 installer="com.android.vending"/g' \
    "$xml_temp"

  # Pass 3: replace or add installInitiator
  sed -i -E \
    -e "$SYS_SKIP" \
    -e '/installInitiator=/ { s/(installInitiator=")[^"]*/\1com.android.vending/g }' \
    -e '/installInitiator=/! s/(<package [^>]*)/ \1 installInitiator="com.android.vending"/g' \
    "$xml_temp"

  # Pass 4: replace or add installerUid
  sed -i -E \
    -e "$SYS_SKIP" \
    -e '/installerUid(-int)?=/ { s/(installerUid(-int)?=")[^"]*/\1'"$vending_uid"'/g }' \
    -e '/installerUid(-int)?=/! s/(<package [^>]*)/ \1 installerUid="'"$vending_uid"'"/g' \
    "$xml_temp"

  # Pass 5: remove installOriginator
  sed -i -E -e "$SYS_SKIP" -e 's/ *installOriginator="[^"]*"//g' "$xml_temp"

  # Pass 6: remove isOrphaned if true or 1
  sed -i -E -e "$SYS_SKIP" -e 's/isOrphaned="(true|1)"//g' "$xml_temp"

  # Pass 7: remove installInitiatorUninstalled if true or 1
  sed -i -E -e "$SYS_SKIP" -e 's/installInitiatorUninstalled="(true|1)"//g' "$xml_temp"


  # Pass 8: set packageSource to 2 (replace or add)
  sed -i -E -e "$SYS_SKIP" \
    -e 's/packageSource="[^2]"/packageSource="2"/g' \
    -e '/packageSource=/! s/(<package [^>]*)/ \1 packageSource="2"/g' \
    "$xml_temp"

  # Collapse back to single line (preserves original format)
  tr '\n' ' ' < "$xml_temp" | sed 's/> </></g' > "${xml_temp}.tmp"
  mv "${xml_temp}.tmp" "$xml_temp"

  ui_print "Rotating backups..."
  rotate_files "${base_name_no_ext}_*.xml" "$MAX_BACKUP_FILES"
  rotate_files "${base_name_no_ext}_*.abxml" "$MAX_BACKUP_FILES"

  if boolval "$is_text_xml"; then
    ui_print "Original file was text XML. Replacing with modified text XML."
    cp "$xml_temp" "$xml_backup_file"
    replacement_source="$xml_backup_file"
  else
    ui_print "Original file was ABX. Converting text to ABX before replacing."
    text_to_abx "$xml_temp" "$abxml_backup_file"
    replacement_source="$abxml_backup_file"
  fi

  ui_print "Replacing original file: $xml_file <- $replacement_source"
  if ! cp -f "$replacement_source" "$xml_file"; then
    ui_print "Error: Failed to copy modified file. Permissions issue?"
    rm "$xml_temp" 2>/dev/null
    return 1
  fi

  ui_print "Verifying replacement: $xml_file vs $replacement_source"
  if ! cmp -s "$xml_file" "$replacement_source"; then
    ui_print "Error: Verification failed after replacement!"
    diff -u "$xml_file" "$replacement_source" >"$MODPATH/diff_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.diff"
    rm "$xml_temp" 2>/dev/null
    return 1
  fi

  ui_print "Cleaning up temporary files..."
  rm "$xml_temp" 2>/dev/null

  ui_print "Successfully processed XML file: $xml_file"
  return 0
}

if ! command_exists abx2xml || ! command_exists xml2abx; then
 ui_print "Error: abx2xml and xml2abx are required. Installing from addons..."
 for addon in "$MODPATH"/common/addon/*/install.sh; do
   if [ -f "$addon" ]; then
     addon_basedirname=$(basename "$(dirname "$addon")")
     ui_print "Running $addon_basedirname addon..."
     . "$addon"
     if [ $? -ne 0 ]; then
       ui_print "Error: Addon $addon_basedirname failed to install."
       exit 1
     fi
   fi
 done
 if ! command_exists abx2xml || ! command_exists xml2abx; then
   ui_print "Error: abx2xml and xml2abx are still missing after running addons."
   exit 1
 fi
fi

wait_for_data

ui_print "Processing $PACKAGES_XML..."
process_xml "$PACKAGES_XML"

ui_print "Restoring permissions and SELinux context..."
for file in "$PACKAGES_XML"; do
 chown system:system "$file"
 chmod 640 "$file"
 if command_exists restorecon; then
   restorecon "$file"
 fi
done

ui_print "----------------------------------------"
ui_print "Process completed successfully."
ui_print "Original and modified files backed up to: $BACKUP_DIR"
ui_print "It is recommended to reboot your device for changes to take effect."
ui_print "by @T3SL4"
ui_print "----------------------------------------"
