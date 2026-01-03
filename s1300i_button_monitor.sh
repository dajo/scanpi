#!/bin/bash

# S1300i Button Monitor - Simple single-sided scanner
LOCKFILE="/tmp/s1300i_button.lock"
CONSUME_DIR="/mnt/consume"
LOG_TAG="S1300i-Button"

# Load config if exists
[ -f /etc/s1300i_button.conf ] && source /etc/s1300i_button.conf

# Use config values with defaults
RESOLUTION=${BUTTON_RESOLUTION:-300}
MODE=${BUTTON_MODE:-"Color"}
SOURCE=${BUTTON_SOURCE:-"ADF Front"}  # Always single-sided
TAG=${BUTTON_TAG:-"inbox"}

# Exit if already running
if [ -f "$LOCKFILE" ]; then
    exit 0
fi
echo $$ > "$LOCKFILE"

# Cleanup on exit
trap 'rm -f "$LOCKFILE"; exit' INT TERM EXIT

logger -t "$LOG_TAG" "Starting S1300i button monitor (single-sided mode)"

# Function to detect scanner device dynamically
detect_scanner() {
    local device=$(scanimage -L 2>/dev/null | grep -o "net:[^']*" | head -1)
    if [ -z "$device" ]; then
        device=$(scanimage -L 2>/dev/null | grep -o "epjitsu:[^']*" | head -1)
    fi
    echo "$device"
}

# Function to check if button was pressed
check_button_pressed() {
    local scanner_device=$(detect_scanner)
    if [ -z "$scanner_device" ]; then
        return 1
    fi
    
    local state=$(timeout 3s scanimage --device-name="$scanner_device" -A 2>/dev/null | grep "scan\[" | grep -o "\[yes\]\|\[no\]")
    
    if [ "$state" = "[yes]" ]; then
        return 0
    else
        return 1
    fi
}

# Function to perform scan
do_scan() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local temp_dir="/tmp/scan_$$"
    local scanner_device=$(detect_scanner)
    
    if [ -z "$scanner_device" ]; then
        logger -t "$LOG_TAG" "ERROR: Scanner not detected"
        return 1
    fi
    
    # Build filename with tag
    if [ -n "$TAG" ]; then
        local output_file="${CONSUME_DIR}/button_scan_${timestamp}__tag-${TAG}.pdf"
    else
        local output_file="${CONSUME_DIR}/button_scan_${timestamp}.pdf"
    fi
    
    logger -t "$LOG_TAG" "Button pressed - starting single-sided scan"
    logger -t "$LOG_TAG" "Settings: ${RESOLUTION}dpi, ${MODE}, ${SOURCE}"
    
    # Create directories
    mkdir -p "$temp_dir"
    mkdir -p "$CONSUME_DIR"
    
    # Wait for scanner to be ready
    sleep 3
    
    # Perform scan
    if timeout 60s scanadf \
        --device-name="$scanner_device" \
        --resolution "$RESOLUTION" \
        --mode "$MODE" \
        --source "$SOURCE" \
        --output-file "${temp_dir}/page_%04d.pnm" 2>/dev/null; then
        
        if ls "${temp_dir}"/page_*.pnm > /dev/null 2>&1; then
            if convert "${temp_dir}"/page_*.pnm "$output_file" 2>/dev/null; then
                chmod 644 "$output_file"
                logger -t "$LOG_TAG" "Scan completed: $(basename "$output_file")"
            else
                logger -t "$LOG_TAG" "PDF conversion failed"
            fi
        else
            logger -t "$LOG_TAG" "No pages scanned - ensure paper is loaded"
        fi
    else
        logger -t "$LOG_TAG" "Scan failed"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    # Cooldown
    logger -t "$LOG_TAG" "Cooldown period"
    sleep 10
}

# Initial scanner check
initial_device=$(detect_scanner)
if [ -z "$initial_device" ]; then
    logger -t "$LOG_TAG" "WARNING: No scanner detected at startup"
else
    logger -t "$LOG_TAG" "Scanner detected: $initial_device"
    logger -t "$LOG_TAG" "Mode: Single-sided, ${RESOLUTION}dpi, ${MODE}"
    if [ -n "$TAG" ]; then
        logger -t "$LOG_TAG" "Auto-tagging with: $TAG"
    fi
fi

# Main monitoring loop
while true; do
    if ! pgrep -f "scanimage\|scanadf" > /dev/null 2>&1; then
        if check_button_pressed; then
            do_scan
        fi
    fi
    
    sleep 2
done
