#!/system/bin/busybox sh

MODPATH="${0%/*}"
MODNAME="${MODPATH##*/}"

PACKAGES_XML="/data/system/packages.xml"
DB="$MODPATH/metadata.db"
CURRENT_TIMESTAMP=$(date +%s)

[ -z "$MODPATH" ] || ! echo "$MODPATH" | grep -q '/data/adb/modules/' &&
 MODPATH="$(dirname "$(readlink -f "$0")")"

[ -f "$MODPATH/util_functions.sh" ] && . "$MODPATH/util_functions.sh" || abort "! util_functions.sh not found!"

process_xml() {
  xml_file="$1"
  base_name=$(basename "$xml_file")
  base_name_no_ext="${base_name%.*}"

  xml_temp="$MODPATH/temp_${base_name_no_ext}_$CURRENT_TIMESTAMP.xml"

  ui_print "Starting to process XML file: $xml_file"

  # Determine format
  file_type=$(file -b "$xml_file")
  is_text_xml=false
  if echo "$file_type" | grep -q -E "XML .* text|text"; then
    is_text_xml=true
  fi

  if boolval "$is_text_xml"; then
    ui_print "File is text XML. Proceeding with modifications."
    cp "$xml_file" "$xml_temp"
  else
    ui_print "Converting ABX to text: $xml_file -> $xml_temp"
    if ! abx_to_text "$xml_file" "$xml_temp"; then
      ui_print "Error: abx_to_text failed!"
      cat "$xml_file" >"$MODPATH/abx_to_text_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.abx"
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

  # Normalize: split single-line XML so each <package ...> sits on its own line
  sed -i 's/<package /\n<package /g' "$xml_temp"
  sed -i '1{/^$/d}' "$xml_temp"

  # --- v1.6.0 DB logic -------------------------------------------------------
  if [ ! -f "$DB" ]; then
    ui_print "First boot detected. Building metadata.db..."

    # Safety: keep one text backup in case of corruption
    cp -f "$xml_temp" "$MODPATH/packages.xml.safety"

    awk '
      /^<package / {
        name = ""; codePath = ""; issystem = ""; installer = ""; installerUid = ""
        installInitiator = ""; packageSource = ""; installOriginator = ""; isOrphaned = ""
        installInitiatorUninstalled = ""

        if (match($0, /name="[^"]*"/))       name = substr($0, RSTART+6, RLENGTH-7)
        if (match($0, /codePath="[^"]*"/))    codePath = substr($0, RSTART+10, RLENGTH-11)
        if (match($0, /system="[^"]*"/))      issystem = substr($0, RSTART+8, RLENGTH-9)
        if (match($0, /installer="[^"]*"/))   installer = substr($0, RSTART+11, RLENGTH-12)
        if (match($0, /installerUid="[^"]*"/)) installerUid = substr($0, RSTART+14, RLENGTH-15)
        else if (match($0, /installerUid-int="[^"]*"/)) installerUid = substr($0, RSTART+18, RLENGTH-19)
        if (match($0, /installInitiator="[^"]*"/)) installInitiator = substr($0, RSTART+18, RLENGTH-19)
        if (match($0, /packageSource="[^"]*"/)) packageSource = substr($0, RSTART+15, RLENGTH-16)
        if (match($0, /installOriginator="[^"]*"/)) installOriginator = substr($0, RSTART+19, RLENGTH-20)
        if (match($0, /isOrphaned="[^"]*"/))  isOrphaned = substr($0, RSTART+12, RLENGTH-13)
        if (match($0, /installInitiatorUninstalled="[^"]*"/)) installInitiatorUninstalled = substr($0, RSTART+29, RLENGTH-30)

        if (codePath ~ /\/data\/app\// && issystem != "true" && issystem != "1") {
          print name "|" installer "|" installerUid "|" installInitiator "|" packageSource "|" installOriginator "|" isOrphaned "|" installInitiatorUninstalled
        }
      }
    ' "$xml_temp" > "$DB.tmp"
    mv -f "$DB.tmp" "$DB"

    db_entries=$(grep -c -v '^#' "$DB" 2>/dev/null || echo 0)
    ui_print "Metadata DB built with $db_entries entries."
  else
    ui_print "Subsequent boot. Pruning and updating metadata.db..."

    # Prune: remove DB entries for packages no longer in packages.xml
    grep -E '^<package ' "$xml_temp" | grep -oE 'name="[^"]*"' | cut -d'"' -f2 | sort -u > "$MODPATH/.current_pkgs"
    awk -F'|' '
      BEGIN { pkgs = ARGV[1] }
      FILENAME == pkgs { current[$1] = 1; next }
      !/^#/ && ($1 in current)
    ' "$MODPATH/.current_pkgs" "$DB" > "$DB.tmp"
    mv -f "$DB.tmp" "$DB"
    rm -f "$MODPATH/.current_pkgs"

    pruned=$(grep -c -v '^#' "$DB" 2>/dev/null || echo 0)
    ui_print "DB pruned. Entries: $pruned"

    # Detect new packages and append to DB
    awk -F'|' '
      BEGIN { db = ARGV[1] }
      FILENAME == db { if ($0 !~ /^#/) seen[$1] = 1; next }
      /^<package / {
        name = ""; codePath = ""; issystem = ""; installer = ""; installerUid = ""
        installInitiator = ""; packageSource = ""; installOriginator = ""; isOrphaned = ""
        installInitiatorUninstalled = ""

        if (match($0, /name="[^"]*"/))       name = substr($0, RSTART+6, RLENGTH-7)
        if (match($0, /codePath="[^"]*"/))    codePath = substr($0, RSTART+10, RLENGTH-11)
        if (match($0, /system="[^"]*"/))      issystem = substr($0, RSTART+8, RLENGTH-9)
        if (match($0, /installer="[^"]*"/))   installer = substr($0, RSTART+11, RLENGTH-12)
        if (match($0, /installerUid="[^"]*"/)) installerUid = substr($0, RSTART+14, RLENGTH-15)
        else if (match($0, /installerUid-int="[^"]*"/)) installerUid = substr($0, RSTART+18, RLENGTH-19)
        if (match($0, /installInitiator="[^"]*"/)) installInitiator = substr($0, RSTART+18, RLENGTH-19)
        if (match($0, /packageSource="[^"]*"/)) packageSource = substr($0, RSTART+15, RLENGTH-16)
        if (match($0, /installOriginator="[^"]*"/)) installOriginator = substr($0, RSTART+19, RLENGTH-20)
        if (match($0, /isOrphaned="[^"]*"/))  isOrphaned = substr($0, RSTART+12, RLENGTH-13)
        if (match($0, /installInitiatorUninstalled="[^"]*"/)) installInitiatorUninstalled = substr($0, RSTART+29, RLENGTH-30)

        if (codePath ~ /\/data\/app\// && issystem != "true" && issystem != "1" && !(name in seen)) {
          print name "|" installer "|" installerUid "|" installInitiator "|" packageSource "|" installOriginator "|" isOrphaned "|" installInitiatorUninstalled
        }
      }
    ' "$DB" "$xml_temp" >> "$DB"

    total=$(grep -c -v '^#' "$DB" 2>/dev/null || echo 0)
    ui_print "New packages scanned. Total DB entries: $total"
  fi
  # --- End DB logic ----------------------------------------------------------

  ui_print "Starting to modify XML with sed..."

  # DRY: only process user apps in /data/app/, skip everything else
  SYS_SKIP='
    /^<package /!b
    /codePath="\/data\/app\//!b
    /system="true"/b
    /system="1"/b
  '

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

  if boolval "$is_text_xml"; then
    ui_print "Original file was text XML. Replacing with modified text XML."
    replacement_source="$xml_temp"
  else
    ui_print "Original file was ABX. Converting text to ABX before replacing."
    abxml_out="$MODPATH/temp_${base_name_no_ext}_restored_$CURRENT_TIMESTAMP.abxml"
    if ! text_to_abx "$xml_temp" "$abxml_out"; then
      ui_print "Error: text_to_abx failed!"
      rm "$xml_temp" "$abxml_out" 2>/dev/null
      return 1
    fi
    replacement_source="$abxml_out"
  fi

  ui_print "Replacing original file: $xml_file <- $replacement_source"
  cat "$replacement_source" > "$xml_file.tmp" || {
    ui_print "Error: Failed to stage modified file."
    rm "$xml_temp" "$xml_file.tmp" "$abxml_out" 2>/dev/null
    return 1
  }
  mv -f "$xml_file.tmp" "$xml_file" || {
    ui_print "Error: Failed to atomically replace $xml_file."
    rm "$xml_temp" "$abxml_out" 2>/dev/null
    return 1
  }

  ui_print "Verifying replacement: $xml_file vs $replacement_source"
  if ! cmp -s "$xml_file" "$replacement_source"; then
    ui_print "Error: Verification failed after replacement!"
    diff -u "$xml_file" "$replacement_source" >"$MODPATH/diff_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.diff"
    rm "$xml_temp" "$abxml_out" 2>/dev/null
    return 1
  fi

  ui_print "Cleaning up temporary files..."
  rm "$xml_temp" "$abxml_out" 2>/dev/null

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
ui_print "It is recommended to reboot your device for changes to take effect."
ui_print "by @T3SL4"
ui_print "----------------------------------------"
