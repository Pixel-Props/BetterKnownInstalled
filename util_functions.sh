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
    rotate_log
  fi

  # Write to log file
  echo "$log_entry" >>"$LOG_FILE"
}

rotate_log() {
  i=$MAX_LOG_FILES
  while [ "$i" -gt 1 ]; do
    prev=$((i - 1))
    [ -f "$LOG_FILE.$prev" ] && mv -f "$LOG_FILE.$prev" "$LOG_FILE.$i"
    i=$prev
  done
  [ -f "$LOG_FILE" ] && mv -f "$LOG_FILE" "$LOG_FILE.1"
}

# Wait for /data to be mounted and packages.xml accessible
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

# Get the architecture
get_arch() {
  arch=$(getprop ro.product.cpu.abi | tr -d '\r')

  # Map architectures to binary names
  case "$arch" in
  "armeabi-v7a") echo "armv7aeabi" ;;
  "arm64-v8a") echo "aarch64" ;;
  "x86") echo "i686" ;;
  "x86_64") echo "x86_64" ;;
  "riscv64") echo "riscv64" ;;
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
  abx2xml "$input_file" "$output_file" 2>&1 | while read -r line; do
    ui_print "abx2xml: $line"
  done
  result=$?

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
  xml2abx "$input_file" "$output_file" 2>&1 | while read -r line; do
    ui_print "xml2abx: $line"
  done
  result=$?

  if [ $result -ne 0 ]; then
    ui_print "Error: Failed to convert '$input_file'. Check xml2abx output for potential errors."
  fi

  if [ $result -eq 0 ]; then
    ui_print "Successfully converted '$input_file' at '$output_file'."
  fi

  return "$result"
}
