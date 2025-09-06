#!/system/bin/busybox sh
MODPATH="${0%/*}"

LOG_FILE="$MODPATH/$MODNAME.log"
MAX_LOG_SIZE=$((1024 * 1024)) # Maximum log file size (1MB)
MAX_LOG_FILES=5               # Maximum number of log files to keep

# Function to check for command existence
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function that normalizes a boolean value and returns 0, 1, or a string
# Usage: boolval "value"
boolval() {
  case "$(printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]')" in
  1 | true | on | enabled) return 0 ;;    # Truely
  0 | false | off | disabled) return 1 ;; # Falsely
  *) return 1 ;;                          # Everything else - return a string
  esac
}

# Function to write to log file with rotation and enhanced debugging
ui_print() {
  message="$1"
  timestamp=$(date +'%Y-%m-%d %H:%M:%S')
  log_entry="[$timestamp] $message"

  # Check log file size and rotate if necessary
  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -ge "$MAX_LOG_SIZE" ]; then
    rotate_files "$LOG_FILE" "$MAX_LOG_FILES"
  fi

  # Write to log file
  echo "$log_entry" >>"$LOG_FILE"
}

# Get the architecture
get_arch() {
  arch=$(getprop ro.product.cpu.abi | tr -d '\r')

  # Map architectures to binary names
  case "$arch" in
  "armeabi-v7a") echo "armv7aeabi" ;;
  "arm64-v8a") echo "aarch64" ;;
  "x86") echo "i686" ;;
  "x86_64") echo "x86_64" ;;
  *)
    # Handle cases where arch is not found or not supported
    ui_print "Error: Could not determine architecture or architecture not supported: $arch"
    return 1
    ;;
  esac
}

# Function to convert binary XML to text XML
abx_to_text() {
  input_file="$1"
  output_file="$2"

  ui_print "Attempting to convert $input_file to text XML"

  # Check if input file exists
  if [ ! -f "$input_file" ]; then
    ui_print "Error: Input file '$input_file' does not exist."
    return 1
  fi

  # If output file is not provided, use the default (input file name with .xml)
  if [ -z "$output_file" ]; then
    output_file="${input_file%.*}.xml"
  fi

  # Check if output directory is writable (only if output is not stdout)
  if [ "$output_file" != "-" ]; then
    output_dir=$(dirname "$output_file")
    if [ ! -w "$output_dir" ]; then
      ui_print "Error: Output directory '$output_dir' is not writable."
      return 1
    fi
  fi

  # Check if the input is likely Android Binary XML using 'file'
  file_type=$(file -b "$input_file")
  if ! echo "$file_type" | grep -q "Binary XML"; then
    ui_print "Error: Input file '$input_file' is not recognized as a valid binary XML. File type: $file_type"
    return 1
  fi

  # Use abx2xml for conversion
  # Pipe stdout directly to a while loop, handling line by line
  # stderr is combined with stdout
  abx2xml "$input_file" "$output_file" 2>&1 | while read -r line; do
    ui_print "abx2xml: $line"
  done
  result=$?

  # Print a generic error message if abx2xml failed
  if [ $result -ne 0 ]; then
    ui_print "Error: Failed to convert '$input_file'. Check abx2xml output for potential errors."
  fi

  if [ $result -eq 0 ]; then
    ui_print "Successfully converted '$input_file' at '$output_file'."
  fi

  return "$result"
}

# Function to convert text XML to binary XML
text_to_abx() {
  input_file="$1"
  output_file="$2"

  ui_print "Attempting to convert '$input_file' to Android Binary XML"

  # Check if input file exists
  if [ ! -f "$input_file" ]; then
    ui_print "Error: Input file '$input_file' does not exist."
    return 1
  fi

  # If output file is not provided, use the default (input file name with .abxml)
  if [ -z "$output_file" ]; then
    output_file="${input_file%.*}.abxml"
  fi

  # Check if output directory is writable (only if output is not stdout)
  if [ "$output_file" != "-" ]; then
    output_dir=$(dirname "$output_file")
    if [ ! -w "$output_dir" ]; then
      ui_print "Error: Output directory '$output_dir' is not writable."
      return 1
    fi
  fi

  # Check if the input is likely text XML using 'file'
  file_type=$(file -b "$input_file")
  if ! echo "$file_type" | grep -q -E "XML .* text|text"; then
    ui_print "Error: Input file '$input_file' is not recognized as a valid text XML file. File type: $file_type"
    return 1
  fi

  # Use xml2abx for conversion
  # Pipe stdout directly to a while loop, handling line by line
  # stderr is combined with stdout
  xml2abx "$input_file" "$output_file" 2>&1 | while read -r line; do
    ui_print "xml2abx: $line"
  done
  result=$?

  # Print a generic error message if xml2abx failed
  if [ $result -ne 0 ]; then
    ui_print "Error: Failed to convert '$input_file'. Check xml2abx output for potential errors."
  fi

  if [ $result -eq 0 ]; then
    ui_print "Successfully converted '$input_file' at '$output_file'."
  fi

  return "$result"
}

# Function to rotate files, keeping the specified number of backups
# This function should be called BEFORE creating a new backup file
rotate_files() {
  file_pattern="$1"
  max_files="$2"

  ui_print "Rotating files matching pattern: $file_pattern, keeping maximum $max_files files."

  # Get list of files sorted by name (oldest first due to timestamp naming)
  files_to_check=$(find "$BACKUP_DIR" -maxdepth 1 -name "$file_pattern" -type f | sort)

  if [ -z "$files_to_check" ]; then
    ui_print "No files found matching the pattern."
    return 0
  fi

  # Count files
  num_files=$(echo "$files_to_check" | wc -l)
  ui_print "Found $num_files files matching the pattern."

  # Calculate how many files to delete, accounting for the new file that will be created
  # We need to keep (max_files - 1) existing files to make room for the new one
  if [ "$num_files" -ge "$max_files" ]; then
    files_to_delete=$((num_files - max_files + 1))
    ui_print "Need to delete $files_to_delete old files to make room for new backup."

    # Delete the oldest files (first in sorted list)
    echo "$files_to_check" | head -n "$files_to_delete" | while IFS= read -r file; do
      if [ -n "$file" ] && [ -f "$file" ]; then
        ui_print "Deleting old backup: $file"
        rm "$file"
      fi
    done
  else
    ui_print "No files to delete. Number of files is within the limit."
  fi
}

# Function to create a timestamped backup of a file using the script's timestamp
backup_file() {
  original_file="$1"
  original_file_basename=$(basename "$original_file")
  original_file_no_ext="${original_file_basename%.*}"
  backup_type="$2"
  backup_file="$BACKUP_DIR/${original_file_no_ext}_$CURRENT_TIMESTAMP.$backup_type"

  ui_print "Preparing to back up '$original_file_basename' to '$backup_file'"

  if [ ! -d "$BACKUP_DIR" ]; then
    ui_print "Backup directory '$BACKUP_DIR' does not exist. Creating..."
    mkdir -p "$BACKUP_DIR"
  fi

  ui_print "Rotating existing backups for $original_file_basename of type (.$backup_type)"
  rotate_files "${original_file_no_ext}_*$backup_type" "$MAX_BACKUP_FILES" # Modified glob pattern

  ui_print "Creating backup..."
  if cp "$original_file" "$backup_file"; then # Check if cp was successful
    ui_print "Backup created at '$backup_file'"
    echo "$backup_file" # Return the backup file path
    return 0            # Indicate success
  else
    ui_print "Error: Failed to create backup!"
    return 1 # Indicate failure
  fi
}
