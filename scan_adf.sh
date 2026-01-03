#!/bin/bash
SCAN_DIRECTORY=${SCAN_DIRECTORY:-/mnt/scan}
PAPERLESS_CONSUME_DIR=${PAPERLESS_CONSUME_DIR:-/mnt/consume}
PROCESSING_LOCKFILE=/var/lock/.scanlock
SEND_TO_PAPERLESS=${SEND_TO_PAPERLESS:-false}
PAPERLESS_TAGS=${PAPERLESS_TAGS:-""}
PAPERLESS_CORRESPONDENT=${PAPERLESS_CORRESPONDENT:-""}

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

# Scan the document
scanadf --device-name="$SCANNER_DEVICE" --mode "$MODE" --source "$SCANNER_SOURCE" --resolution "$RESOLUTION" 2>>stderr.log 1>>stdout.log || true

if ls image* 1> /dev/null 2>&1; then
    echo "$(date): Scan completed, found images: $(ls image* | wc -l)" >> stderr.log

# Convert to pdf (no OCR - Paperless will handle that)
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
