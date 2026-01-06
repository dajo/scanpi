#!/bin/bash
SCAN_DIRECTORY=${SCAN_DIRECTORY:-/mnt/scan}
PAPERLESS_CONSUME_DIR=${PAPERLESS_CONSUME_DIR:-/mnt/consume}
PROCESSING_LOCKFILE=/var/lock/.scanlock
SEND_TO_PAPERLESS=${SEND_TO_PAPERLESS:-false}
PAPERLESS_TAGS=${PAPERLESS_TAGS:-""}
PAPERLESS_CORRESPONDENT=${PAPERLESS_CORRESPONDENT:-""}

# Output format: "pdf" (direct to Paperless) or "raw" (images for scan-to-paperless)
OUTPUT_FORMAT=${OUTPUT_FORMAT:-"pdf"}
# Directory for raw images when using scan-to-paperless
SCAN_TO_PAPERLESS_DIR=${SCAN_TO_PAPERLESS_DIR:-"/mnt/scan-to-paperless"}

touch "$PROCESSING_LOCKFILE"

detect_scanner() {
    SCANNER_DEVICE=$(scanimage -L | grep -o "net:[^']*" | head -1)

    if [ -z "$SCANNER_DEVICE" ]; then
        SCANNER_DEVICE=$(scanimage -L | grep -o "epjitsu:[^']*" | head -1)
    fi

    echo "$(date): Detected scanner device: $SCANNER_DEVICE" >> /mnt/scan/scan.log

    if [ -z "$SCANNER_DEVICE" ]; then
        echo "$(date): ERROR - No scanner found" >> stderr.log
        echo "Available devices:" >> stderr.log
        scanimage -L >> stderr.log 2>&1
        return 1
    fi

    return 0
}

map_source_option() {
    case "$SOURCE" in
        "Single-sided")
            SCANNER_SOURCE="ADF Front"
            ;;
        "Duplex")
            SCANNER_SOURCE="ADF Duplex"
            ;;
        *)
            SCANNER_SOURCE="$SOURCE"  # Fallback to original
            ;;
    esac
}

create_paperless_filename() {
    local base_filename="$1"
    local final_filename="$base_filename.pdf"

    # Add paperless metadata to filename if specified
    if [ "$PAPERLESS_CORRESPONDENT" != "" ]; then
        final_filename="${PAPERLESS_CORRESPONDENT}__${final_filename}"
    fi

    if [ "$PAPERLESS_TAGS" != "" ]; then
        # Convert comma-separated tags to paperless format
        local tags_formatted=$(echo "$PAPERLESS_TAGS" | sed 's/,/__tag-/g' | sed 's/^/__tag-/')
        final_filename="${final_filename%.*}${tags_formatted}.pdf"
    fi

    echo "$final_filename"
}

exec 4<"$PROCESSING_LOCKFILE"
flock 4

pushd $SCAN_DIRECTORY
mkdir -p "$FILENAME"
pushd "$FILENAME"

if ! detect_scanner; then
    echo "$(date): Failed to detect scanner, aborting scan" >> stderr.log
    exec 4<&-
    popd && popd
    exit 1
fi

echo "$(date): Starting scan - Device: $SCANNER_DEVICE, Mode: $MODE, Source: $SOURCE, Resolution: $RESOLUTION" >> stderr.log

# Map user-friendly source names to scanner commands
case "$SOURCE" in
    "Single-sided")
        SCANNER_SOURCE="ADF Front"
        ;;
    "Duplex")
        SCANNER_SOURCE="ADF Duplex"
        ;;
    *)
        SCANNER_SOURCE="$SOURCE"  # Fallback to original
        ;;
esac

echo "$(date): Mapped source: $SOURCE -> $SCANNER_SOURCE" >> stderr.log

echo "$(date): Paperless integration: $SEND_TO_PAPERLESS, Tags: $PAPERLESS_TAGS, Correspondent: $PAPERLESS_CORRESPONDENT" >> stderr.log

echo "$(date): Waiting for scanner to wake up (load paper if not already loaded)" >> stderr.log

# Wait up to 60 seconds for scanner to wake
for i in {1..30}; do
    POWER_STATE=$(timeout 3s scanimage -A 2>/dev/null | grep "power-save" | grep -o "\[yes\]\|\[no\]")
    if [ "$POWER_STATE" = "[no]" ]; then
        echo "$(date): Scanner is awake and ready" >> stderr.log
        break
    fi
    echo "$(date): Scanner sleeping, waiting for paper to be loaded... (${i}/30)" >> stderr.log
    sleep 2
done

if [ "$POWER_STATE" != "[no]" ]; then
    echo "$(date): ERROR - Scanner did not wake up. Please ensure paper is loaded in the ADF." >> stderr.log
    exec 4<&-
    popd && popd
    exit 1
fi

# Scan the document (--page-height 0 enables auto-detection of document length)
scanadf --device-name="$SCANNER_DEVICE" --mode "$MODE" --source "$SCANNER_SOURCE" --resolution "$RESOLUTION" --page-height 0 2>>stderr.log 1>>stdout.log || true

if ls image* 1> /dev/null 2>&1; then
    echo "$(date): Scan completed, found images: $(ls image* | wc -l)" >> stderr.log
    echo "$(date): Output format: $OUTPUT_FORMAT" >> stderr.log

    if [ "$OUTPUT_FORMAT" = "raw" ]; then
        # Raw output for scan-to-paperless: create folder with PNG images
        mkdir -p "$SCAN_TO_PAPERLESS_DIR"

        # Build folder name with paperless metadata for scan-to-paperless
        if [ "$PAPERLESS_CORRESPONDENT" != "" ]; then
            RAW_FOLDER_NAME="${PAPERLESS_CORRESPONDENT}__${FILENAME}"
        else
            RAW_FOLDER_NAME="$FILENAME"
        fi
        if [ "$PAPERLESS_TAGS" != "" ]; then
            TAGS_FORMATTED=$(echo "$PAPERLESS_TAGS" | sed 's/,/__tag-/g' | sed 's/^/__tag-/')
            RAW_FOLDER_NAME="${RAW_FOLDER_NAME}${TAGS_FORMATTED}"
        fi

        OUTPUT_DIR="${SCAN_TO_PAPERLESS_DIR}/${RAW_FOLDER_NAME}"
        mkdir -p "$OUTPUT_DIR"

        # Convert images to PNG and move to scan-to-paperless directory
        PAGE_NUM=1
        IMAGE_LIST=""
        for img in image*; do
            PNG_NAME="page_$(printf '%04d' $PAGE_NUM).png"
            convert "$img" "${OUTPUT_DIR}/${PNG_NAME}" 2>>stderr.log
            IMAGE_LIST="${IMAGE_LIST}  - ${PNG_NAME}
"
            ((PAGE_NUM++))
        done

        # Create config.yaml for scan-to-paperless (extends global config)
        cat > "${OUTPUT_DIR}/config.yaml" << 'EOF'
extends: /root/.config/scan-to-paperless.yaml
images:
EOF
        # Append image list (already has proper formatting with newlines)
        echo -n "${IMAGE_LIST}" >> "${OUTPUT_DIR}/config.yaml"
        # Add args with no_remove_to_continue (required settings that must be in job config)
        # Disable auto_mask/auto_cut for web scans (full documents don't need cropping)
        cat >> "${OUTPUT_DIR}/config.yaml" << 'EOF'
args:
  no_remove_to_continue: true
  tesseract:
    enabled: false
  auto_mask:
    enabled: false
  auto_cut:
    enabled: false
EOF
        chmod 644 "${OUTPUT_DIR}/config.yaml"

        echo "$(date): Raw images sent to scan-to-paperless: $OUTPUT_DIR ($(( PAGE_NUM - 1 )) pages)" >> stderr.log

        # Also save PDF locally for archive
        convert image* "$FILENAME.pdf" 2>>stderr.log 1>>stdout.log
        echo "$(date): Local PDF archive saved: $FILENAME.pdf" >> stderr.log
    else
        # PDF output mode (original behavior)
        # Convert to PDF (no OCR - Paperless will handle that)
        convert image* "$FILENAME.pdf" 2>>stderr.log 1>>stdout.log

        # Send to paperless if requested
        if [ "$SEND_TO_PAPERLESS" = "true" ] && [ -d "$PAPERLESS_CONSUME_DIR" ]; then
            PAPERLESS_FILENAME=$(create_paperless_filename "$FILENAME")
            cp "$FILENAME.pdf" "$PAPERLESS_CONSUME_DIR/$PAPERLESS_FILENAME" 2>>stderr.log

            if [ $? -eq 0 ]; then
                echo "$(date): Document sent to Paperless: $PAPERLESS_FILENAME" >> stderr.log
            else
                echo "$(date): ERROR - Failed to send document to Paperless" >> stderr.log
            fi
        else
            echo "$(date): Document saved locally only" >> stderr.log
        fi
    fi

    # Cleanup intermediate files
    rm image* 2>>stderr.log 1>>stdout.log

    echo "$(date): Processing completed successfully" >> stderr.log
else
    echo "$(date): ERROR - No images were created by scan" >> stderr.log
fi

# Ensure permissions allow users to access the scans
chmod -R u+rwX,g+rwX,o+rwX  "$FILENAME"

# Give a break between scan jobs of 15 seconds to allow loading a queued job
sleep 15s

exec 4<&-
popd # FILENAME

popd # SCAN_DIRECTORY
