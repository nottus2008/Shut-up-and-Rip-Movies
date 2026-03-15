#!/bin/bash
# =============================================================================
# suarip.sh - Shut Up And Rip
# Automatic DVD/Blu-ray Ripping and Transcoding Script
# =============================================================================
# Dependencies:
#   Core:      makemkv (native), HandBrake CLI, curl, python3, ddrescue
#   Optional:  dvdbackup (DVD fallback), libnotify (desktop notifications)
#
# Install on Fedora/Nobara:
#   sudo dnf install HandBrake-cli curl python3 libnotify ddrescue dvdbackup
#   sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
#   Install MakeMKV: https://forum.makemkv.com/forum/viewtopic.php?f=3&t=224
#
# Install on Ubuntu/Debian:
#   sudo add-apt-repository ppa:stebbins/handbrake-releases
#   sudo apt install handbrake-cli curl python3 libnotify-bin gddrescue dvdbackup
#   sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
#   sudo apt install libdvd-pkg && sudo dpkg-reconfigure libdvd-pkg
#   Install MakeMKV: https://forum.makemkv.com/forum/viewtopic.php?f=3&t=224
#
# Install on Arch/Endeavour/CachyOS:
#   sudo pacman -S handbrake-cli curl python3 libnotify ddrescue dvdbackup
#   sudo pacman -S libdvdcss libdvdread libdvdnav
#   sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
#   Install MakeMKV via AUR or source build
#
# Drive notes:
#   - Internal drives: ddrescue/dvdbackup used (some internal drives are
#     incompatible with MakeMKV's SCSI interface e.g. HL-DT-ST GH50N)
#   - USB/external drives: MakeMKV used (better SCSI compatibility)
#   - Blu-ray: always requires MakeMKV regardless of drive
#
# Setup:
#   1. Edit the CONFIG section below
#   2. Make executable: chmod +x suarip.sh
#   3. Run manually: ./suarip.sh
#      Or automatically on disc insert via udev (see bottom of script)
# =============================================================================

# =============================================================================
# CONFIG - Edit these values
# =============================================================================
INTERNAL_DRIVE="/dev/sr0"               # Internal optical drive
USB_DRIVE="/dev/sr1"                    # USB/external optical drive
                                        # Leave empty if no USB drive
TEMP_DIR="/mnt/scratch/suarip_temp"     # Scratch space for temp rip files
OUTPUT_DIR="$HOME/Videos/Movies"        # Final output directory (pre-NAS)
NAS_DIR="/mnt/nas/Media/Movies"         # NAS path (leave empty to skip)
OMDB_API_KEY="8f823ae7"                 # OMDB API key
DVD_PRESET="HQ 720p30 Surround"        # HandBrake preset for DVD
BLURAY_PRESET="HQ 1080p30 Surround"    # HandBrake preset for Blu-ray
RF_QUALITY="19"                         # RF quality (lower=better, 18-22 is good)
LOG_DIR="$HOME/.local/share/suarip"     # Log directory
NOTIFY=true                             # Desktop notifications (true/false)
AUTO_EJECT=true                         # Eject disc when done (true/false)
CONFIRM_METADATA=false                  # Prompt to confirm metadata (true/false)
                                        # false = fully headless/unattended
MIN_TITLE_SECONDS=3600                  # Min title length for MakeMKV (seconds)
MAKEMKV_TIMEOUT=1800                    # MakeMKV timeout in seconds (30 min)
DDRESCUE_RETRIES=3                      # ddrescue bad sector retry count
# =============================================================================
# END CONFIG
# =============================================================================

# =============================================================================
# INIT
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/suarip_$TIMESTAMP.log"

# State
IS_BLURAY=false
PRESET="$DVD_PRESET"
ACTIVE_DRIVE=""
USE_MAKEMKV=false
RIP_FILE=""
OUTPUT_NAME=""
OUTPUT_FILE=""

# Lock file - prevents multiple instances
LOCK_FILE="/tmp/suarip.lock"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

notify() {
    local title="$1"
    local message="$2"
    log "${BLUE}[NOTIFY]${NC} $title: $message"
    if [ "$NOTIFY" = true ] && command -v notify-send &>/dev/null; then
        notify-send "$title" "$message" --icon=media-optical 2>/dev/null || true
    fi
}

error_exit() {
    log "${RED}[ERROR]${NC} $1"
    log "${YELLOW}[INFO]${NC} Temp files preserved in $TEMP_DIR for manual recovery"
    notify "SuaRip Failed" "$1"
    rm -f "$LOCK_FILE"
    exit 1
}

cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        log "${YELLOW}[INFO]${NC} Cleaning up temp files..."
        rm -rf "$TEMP_DIR"
    fi
    # Clean up ISO log file if ddrescue was used
    rm -f "$TEMP_DIR"/../suarip_ddrescue_*.log 2>/dev/null || true
}

eject_disc() {
    if [ "$AUTO_EJECT" = true ]; then
        log "${YELLOW}[INFO]${NC} Ejecting disc from $ACTIVE_DRIVE..."
        eject "$ACTIVE_DRIVE" 2>/dev/null || true
    fi
}

monitor_scratch() {
    # Background monitor - logs temp dir size every 60 seconds
    local pid=$1
    while kill -0 "$pid" 2>/dev/null; do
        SIZE=$(du -sh "$TEMP_DIR" 2>/dev/null | cut -f1)
        log "${YELLOW}[INFO]${NC} Temp dir size: $SIZE"
        sleep 60
    done
}

check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        OLD_PID=$(cat "$LOCK_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "SuaRip already running (PID $OLD_PID) - exiting"
            exit 1
        else
            log "${YELLOW}[WARN]${NC} Stale lock found (PID $OLD_PID), removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

check_space() {
    local dir="$1"
    local needed="$2"
    local available
    available=$(df -BG "$dir" | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$available" -lt "$needed" ]; then
        error_exit "Not enough space in $dir (need ${needed}GB, have ${available}GB)"
    fi
}

# MakeMKV command - handles native and Flatpak
detect_makemkv() {
    if command -v makemkvcon &>/dev/null; then
        MAKEMKV="makemkvcon"
    elif flatpak list 2>/dev/null | grep -q "com.makemkv.MakeMKV"; then
        MAKEMKV="flatpak run --command=makemkvcon --device=all com.makemkv.MakeMKV"
    else
        MAKEMKV=""
    fi
}

# =============================================================================
# STEP 1: Detect disc and select drive/tool
# =============================================================================
detect_disc() {
    log "\n${BLUE}========================================${NC}"
    log "${BLUE}  SuaRip - $(date)${NC}"
    log "${BLUE}========================================${NC}"

    detect_makemkv

    # Find which drive has a disc
    local found_drive=""
    for drive in "$INTERNAL_DRIVE" "$USB_DRIVE"; do
        [ -z "$drive" ] && continue
        [ ! -b "$drive" ] && continue
        if blkid "$drive" &>/dev/null; then
            found_drive="$drive"
            log "${GREEN}[INFO]${NC} Disc found in $drive"
            break
        fi
    done

    if [ -z "$found_drive" ]; then
        error_exit "No disc found in any configured drive"
    fi

    ACTIVE_DRIVE="$found_drive"

    # Get disc label
    RAW_LABEL=$(blkid -o value -s LABEL "$ACTIVE_DRIVE" 2>/dev/null | tr -d '<>')
    if [ -z "$RAW_LABEL" ]; then
        RAW_LABEL="UNKNOWN_DISC_$TIMESTAMP"
        log "${YELLOW}[WARN]${NC} Could not read disc label, using: $RAW_LABEL"
    else
        log "${GREEN}[INFO]${NC} Disc label: $RAW_LABEL"
    fi

    DISC_TYPE=$(blkid -o value -s TYPE "$ACTIVE_DRIVE" 2>/dev/null)
    log "${YELLOW}[INFO]${NC} Disc filesystem type: $DISC_TYPE"

    # Detect Blu-ray by checking for BDMV structure
    local mnt="/tmp/suarip_mount_$$"
    mkdir -p "$mnt"
    if mount "$ACTIVE_DRIVE" "$mnt" 2>/dev/null; then
        if [ -d "$mnt/BDMV" ]; then
            IS_BLURAY=true
            PRESET="$BLURAY_PRESET"
            log "${GREEN}[INFO]${NC} Blu-ray disc detected"
        fi
        umount "$mnt" 2>/dev/null
    fi
    rmdir "$mnt" 2>/dev/null

    # Decide rip tool:
    # - Blu-ray always needs MakeMKV
    # - USB drive uses MakeMKV (better SCSI compatibility)
    # - Internal drive uses ddrescue/dvdbackup (avoids SCSI issues)
    if [ "$IS_BLURAY" = true ]; then
        if [ -z "$MAKEMKV" ]; then
            error_exit "Blu-ray detected but MakeMKV not found - install MakeMKV"
        fi
        USE_MAKEMKV=true
        log "${GREEN}[INFO]${NC} Blu-ray: using MakeMKV | Preset: $PRESET"
    elif [ "$ACTIVE_DRIVE" = "$USB_DRIVE" ]; then
        if [ -z "$MAKEMKV" ]; then
            log "${YELLOW}[WARN]${NC} USB drive detected but MakeMKV not found - falling back to ddrescue"
            USE_MAKEMKV=false
        else
            USE_MAKEMKV=true
            log "${GREEN}[INFO]${NC} USB drive: using MakeMKV | Preset: $PRESET"
        fi
    else
        USE_MAKEMKV=false
        log "${GREEN}[INFO]${NC} Internal drive: using ddrescue | Preset: $PRESET"
    fi
}

# =============================================================================
# STEP 2: Metadata lookup via OMDB (multi-strategy)
# =============================================================================

clean_label_base() {
    echo "$1" \
        | tr '_' ' ' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/\bdisc[0-9]*\b//gi' \
        | sed 's/\bdisk[0-9]*\b//gi' \
        | sed 's/\bse\b//gi' \
        | sed 's/\bws\b//gi' \
        | sed 's/\bfs\b//gi' \
        | sed 's/\bsce\b//gi' \
        | sed 's/\bce\b//gi' \
        | sed 's/\bus\b//gi' \
        | sed 's/\buk\b//gi' \
        | sed 's/\bcan\b//gi' \
        | sed 's/\bntsc\b//gi' \
        | sed 's/\bpal\b//gi' \
        | sed 's/\bregion[0-9]*\b//gi' \
        | sed 's/\bbd\b//gi' \
        | sed 's/\bfrench\b//gi' \
        | sed 's/\bmarvels\b/marvel/gi' \
        | sed 's/[0-9]*$//' \
        | sed 's/ \+/ /g' \
        | sed 's/^ //;s/ $//'
}

omdb_query() {
    local query="$1"
    local year="$2"
    local encoded
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null)
    local url="http://www.omdbapi.com/?t=${encoded}&apikey=${OMDB_API_KEY}&type=movie"
    [ -n "$year" ] && url="${url}&y=${year}"
    curl -s "$url" 2>/dev/null
}

omdb_field() {
    echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$2',''))" 2>/dev/null
}

lookup_metadata() {
    log "\n${YELLOW}[INFO]${NC} Looking up movie metadata..."

    local base_query
    base_query=$(clean_label_base "$RAW_LABEL")

    # Extract year from label if present (e.g. MOVIE_2006_SE)
    local label_year
    label_year=$(echo "$RAW_LABEL" | grep -o '\b[12][0-9]\{3\}\b' | head -1)

    # Build search strategies
    local s3
    s3=$(echo "$base_query" \
        | sed 's/\b\(extended\|theatrical\|directors\|director\|special\|ultimate\|collectors\|collection\|edition\|cut\|version\|remastered\|anniversary\|unrated\|uncut\)\b.*//i' \
        | sed 's/ *$//')
    local s4
    s4=$(echo "$base_query" | awk '{print $1" "$2" "$3}' | sed 's/ *$//')
    local s5
    s5=$(echo "$base_query" | awk '{print $1" "$2}' | sed 's/ *$//')

    declare -a STRATEGIES
    if [ -n "$label_year" ]; then
        STRATEGIES=("$base_query|$label_year" "$base_query|" "$s3|" "$s4|" "$s5|")
    else
        STRATEGIES=("$base_query|" "$s3|" "$s4|" "$s5|")
    fi

    local OMDB_RESPONSE=""
    local OMDB_STATUS="False"
    local used_query=""

    for strategy in "${STRATEGIES[@]}"; do
        local q="${strategy%%|*}"
        local y="${strategy##*|}"
        [ -z "$q" ] && continue
        [ "$q" = "$used_query" ] && continue
        used_query="$q"

        log "${YELLOW}[INFO]${NC} Trying OMDB: '$q'$([ -n "$y" ] && echo " (year: $y)")"
        OMDB_RESPONSE=$(omdb_query "$q" "$y")
        OMDB_STATUS=$(omdb_field "$OMDB_RESPONSE" "Response")

        if [ "$OMDB_STATUS" = "True" ]; then
            log "${GREEN}[INFO]${NC} Match found on: '$q'"
            break
        else
            local err
            err=$(omdb_field "$OMDB_RESPONSE" "Error")
            log "${YELLOW}[INFO]${NC} No match: $err"
        fi
    done

    if [ "$OMDB_STATUS" = "True" ]; then
        MOVIE_TITLE=$(omdb_field "$OMDB_RESPONSE" "Title")
        MOVIE_YEAR=$(omdb_field "$OMDB_RESPONSE" "Year")
        MOVIE_RATED=$(omdb_field "$OMDB_RESPONSE" "Rated")
        MOVIE_GENRE=$(omdb_field "$OMDB_RESPONSE" "Genre")
        MOVIE_PLOT=$(omdb_field "$OMDB_RESPONSE" "Plot")
        MOVIE_YEAR=$(echo "$MOVIE_YEAR" | grep -o '[0-9]\{4\}' | head -1)

        log "${GREEN}[INFO]${NC} Found: $MOVIE_TITLE ($MOVIE_YEAR)"
        log "${GREEN}[INFO]${NC} Rated: $MOVIE_RATED | Genre: $MOVIE_GENRE"
        log "${GREEN}[INFO]${NC} Plot: $MOVIE_PLOT"

        if [ "$CONFIRM_METADATA" = true ]; then
            echo ""
            read -p "$(echo -e "${YELLOW}Is '$MOVIE_TITLE ($MOVIE_YEAR)' correct? (y/n): ${NC}")" CONFIRM
            if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
                read -p "$(echo -e "${YELLOW}Enter correct title: ${NC}")" MOVIE_TITLE
                read -p "$(echo -e "${YELLOW}Enter correct year: ${NC}")" MOVIE_YEAR
                log "${GREEN}[INFO]${NC} Using corrected metadata: $MOVIE_TITLE ($MOVIE_YEAR)"
            fi
        fi

        OUTPUT_NAME="$MOVIE_TITLE ($MOVIE_YEAR)"
    else
        log "${YELLOW}[WARN]${NC} All OMDB strategies exhausted"
        log "${YELLOW}[INFO]${NC} Disc label: '$RAW_LABEL' | Cleaned: '$base_query'"

        if [ "$CONFIRM_METADATA" = true ]; then
            echo ""
            read -p "$(echo -e "${YELLOW}Enter movie title (or Enter to use disc label): ${NC}")" MANUAL_TITLE
            if [ -n "$MANUAL_TITLE" ]; then
                read -p "$(echo -e "${YELLOW}Enter year: ${NC}")" MANUAL_YEAR
                OUTPUT_NAME="$MANUAL_TITLE ($MANUAL_YEAR)"
                log "${GREEN}[INFO]${NC} Using manual entry: $OUTPUT_NAME"
            else
                OUTPUT_NAME=$(echo "$base_query" | sed 's/\b\(.\)/\u\1/g')
                log "${YELLOW}[WARN]${NC} Using cleaned disc label: $OUTPUT_NAME"
            fi
        else
            # Fully unattended - use cleaned title-cased label
            OUTPUT_NAME=$(echo "$base_query" | sed 's/\b\(.\)/\u\1/g')
            log "${YELLOW}[WARN]${NC} Unattended: using disc label as filename: $OUTPUT_NAME"
        fi
    fi

    OUTPUT_NAME=$(echo "$OUTPUT_NAME" | tr -d '/:*?"<>|\\')
    log "${GREEN}[INFO]${NC} Output filename: $OUTPUT_NAME.mkv"
}

# =============================================================================
# STEP 3A: Rip with ddrescue (internal drive)
# =============================================================================
rip_ddrescue() {
    log "\n${YELLOW}[INFO]${NC} Ripping with ddrescue..."
    notify "SuaRip" "Ripping $OUTPUT_NAME (ddrescue)..."

    mkdir -p "$TEMP_DIR" || error_exit "Could not create temp dir: $TEMP_DIR"
    check_space "$TEMP_DIR" 10

    local ISO_FILE="$TEMP_DIR/disc.iso"
    local DDRESCUE_LOG="$TEMP_DIR/ddrescue.log"

    log "${YELLOW}[INFO]${NC} Output ISO: $ISO_FILE"
    log "${YELLOW}[INFO]${NC} Retries per bad sector: $DDRESCUE_RETRIES"

    ddrescue -d -r"$DDRESCUE_RETRIES" "$ACTIVE_DRIVE" "$ISO_FILE" "$DDRESCUE_LOG" \
        >> "$LOG_FILE" 2>&1

    if [ ! -f "$ISO_FILE" ] || [ ! -s "$ISO_FILE" ]; then
        log "${YELLOW}[WARN]${NC} ddrescue failed or produced empty ISO - trying dvdbackup fallback..."
        rip_dvdbackup
        return
    fi

    local ISO_SIZE
    ISO_SIZE=$(du -sh "$ISO_FILE" | cut -f1)
    log "${GREEN}[INFO]${NC} ISO created: $ISO_SIZE"

    # Check for errors in ddrescue log
    local ERRORS
    ERRORS=$(grep -c "error" "$DDRESCUE_LOG" 2>/dev/null || echo "0")
    if [ "$ERRORS" -gt 0 ]; then
        log "${YELLOW}[WARN]${NC} ddrescue reported $ERRORS error(s) - ISO may be incomplete"
    else
        log "${GREEN}[INFO]${NC} ddrescue completed with no errors"
    fi

    RIP_FILE="$ISO_FILE"
}

# =============================================================================
# STEP 3B: dvdbackup fallback (internal drive)
# =============================================================================
rip_dvdbackup() {
    if ! command -v dvdbackup &>/dev/null; then
        error_exit "dvdbackup not found and ddrescue failed - cannot rip disc"
    fi

    log "${YELLOW}[INFO]${NC} Trying dvdbackup fallback..."

    local DVD_DIR="$TEMP_DIR/dvd"
    mkdir -p "$DVD_DIR"

    dvdbackup -M -i "$ACTIVE_DRIVE" -o "$DVD_DIR" >> "$LOG_FILE" 2>&1

    # Find the VIDEO_TS folder
    local VIDEO_TS
    VIDEO_TS=$(find "$DVD_DIR" -type d -name "VIDEO_TS" 2>/dev/null | head -1)

    if [ -z "$VIDEO_TS" ]; then
        error_exit "dvdbackup also failed - check disc for damage"
    fi

    local DVD_SIZE
    DVD_SIZE=$(du -sh "$DVD_DIR" | cut -f1)
    log "${GREEN}[INFO]${NC} dvdbackup complete: $DVD_SIZE"

    RIP_FILE="$DVD_DIR"
}

# =============================================================================
# STEP 3C: Rip with MakeMKV (USB/Blu-ray drive)
# =============================================================================
rip_makemkv() {
    log "\n${YELLOW}[INFO]${NC} Ripping with MakeMKV..."
    notify "SuaRip" "Ripping $OUTPUT_NAME (MakeMKV)..."

    mkdir -p "$TEMP_DIR" || error_exit "Could not create temp dir: $TEMP_DIR"
    local MIN_SPACE=10
    [ "$IS_BLURAY" = true ] && MIN_SPACE=50
    check_space "$TEMP_DIR" $MIN_SPACE

    log "${YELLOW}[INFO]${NC} MakeMKV timeout: ${MAKEMKV_TIMEOUT}s"

    timeout "$MAKEMKV_TIMEOUT" $MAKEMKV mkv dev:"$ACTIVE_DRIVE" all "$TEMP_DIR" \
        --minlength=$MIN_TITLE_SECONDS \
        >> "$LOG_FILE" 2>&1 &
    MAKEMKV_PID=$!

    monitor_scratch $MAKEMKV_PID &
    MONITOR_PID=$!

    wait $MAKEMKV_PID
    MAKEMKV_EXIT=$?
    kill $MONITOR_PID 2>/dev/null

    if [ $MAKEMKV_EXIT -eq 124 ]; then
        error_exit "MakeMKV timed out after ${MAKEMKV_TIMEOUT}s - disc may be incompatible"
    elif [ $MAKEMKV_EXIT -ne 0 ]; then
        error_exit "MakeMKV failed (exit $MAKEMKV_EXIT) - check log: $LOG_FILE"
    fi

    local MKV_COUNT
    MKV_COUNT=$(find "$TEMP_DIR" -maxdepth 1 -name "*.mkv" | wc -l)
    if [ "$MKV_COUNT" -eq 0 ]; then
        error_exit "MakeMKV produced no output - check log: $LOG_FILE"
    fi

    log "${GREEN}[INFO]${NC} MakeMKV produced $MKV_COUNT title(s)"

    # Find largest MKV = main feature
    RIP_FILE=$(find "$TEMP_DIR" -maxdepth 1 -name "*.mkv" -printf '%s %p\n' \
        | sort -rn | head -1 | awk '{$1=""; print $0}' | sed 's/^ //')

    local RIP_SIZE
    RIP_SIZE=$(du -sh "$RIP_FILE" | cut -f1)
    log "${GREEN}[INFO]${NC} Main feature: $(basename "$RIP_FILE") ($RIP_SIZE)"

    if [ "$MKV_COUNT" -gt 1 ]; then
        log "${YELLOW}[INFO]${NC} Additional titles in $TEMP_DIR (available for manual transcode):"
        find "$TEMP_DIR" -maxdepth 1 -name "*.mkv" | while read -r f; do
            [ "$f" != "$RIP_FILE" ] && log "  $(basename "$f") ($(du -sh "$f" | cut -f1))"
        done
    fi
}

# =============================================================================
# STEP 4: Transcode with HandBrake
# =============================================================================
transcode() {
    log "\n${YELLOW}[INFO]${NC} Starting transcode..."
    notify "SuaRip" "Transcoding $OUTPUT_NAME..."

    mkdir -p "$OUTPUT_DIR/$OUTPUT_NAME" || error_exit "Could not create output directory"
    OUTPUT_FILE="$OUTPUT_DIR/$OUTPUT_NAME/$OUTPUT_NAME.mkv"

    # Handle existing file - headless: auto-timestamp, interactive: prompt
    if [ -f "$OUTPUT_FILE" ]; then
        log "${YELLOW}[WARN]${NC} Output file already exists: $OUTPUT_FILE"
        if [ "$CONFIRM_METADATA" = true ]; then
            read -p "$(echo -e "${YELLOW}Overwrite? (y/n): ${NC}")" OVERWRITE
            if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
                OUTPUT_FILE="$OUTPUT_DIR/$OUTPUT_NAME/$OUTPUT_NAME-$TIMESTAMP.mkv"
            fi
        else
            OUTPUT_FILE="$OUTPUT_DIR/$OUTPUT_NAME/$OUTPUT_NAME-$TIMESTAMP.mkv"
            log "${YELLOW}[INFO]${NC} Unattended: saving as $OUTPUT_FILE"
        fi
    fi

    log "${YELLOW}[INFO]${NC} Output: $OUTPUT_FILE"
    log "${YELLOW}[INFO]${NC} Preset: $PRESET | Quality: RF$RF_QUALITY"
    log "${YELLOW}[INFO]${NC} Source: $RIP_FILE"
    log "${YELLOW}[INFO]${NC} This will take a while..."

    local START_TIME
    START_TIME=$(date +%s)

    if ! HandBrakeCLI \
        -i "$RIP_FILE" \
        -o "$OUTPUT_FILE" \
        --preset "$PRESET" \
        -q "$RF_QUALITY" \
        --subtitle scan -F \
        >> "$LOG_FILE" 2>&1; then
        error_exit "HandBrake failed - check log: $LOG_FILE"
    fi

    local END_TIME ELAPSED ELAPSED_MIN OUTPUT_SIZE
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    OUTPUT_SIZE=$(du -sh "$OUTPUT_FILE" | cut -f1)

    log "${GREEN}[INFO]${NC} Transcode complete in ${ELAPSED_MIN} minutes"
    log "${GREEN}[INFO]${NC} Output size: $OUTPUT_SIZE"
}

# =============================================================================
# STEP 5: Copy to NAS
# =============================================================================
copy_to_nas() {
    if [ -z "$NAS_DIR" ]; then
        log "\n${YELLOW}[INFO]${NC} NAS copy skipped (NAS_DIR not configured)"
        return
    fi

    # Check NAS is mounted
    if ! mountpoint -q "$(dirname "$NAS_DIR")" 2>/dev/null && [ ! -d "$NAS_DIR" ]; then
        log "${YELLOW}[WARN]${NC} NAS not accessible: $NAS_DIR - skipping copy"
        log "${YELLOW}[WARN]${NC} File available locally: $OUTPUT_FILE"
        notify "SuaRip Warning" "NAS unavailable - $OUTPUT_NAME saved locally only"
        return
    fi

    log "\n${YELLOW}[INFO]${NC} Copying to NAS: $NAS_DIR/$OUTPUT_NAME/"
    notify "SuaRip" "Copying $OUTPUT_NAME to NAS..."

    mkdir -p "$NAS_DIR/$OUTPUT_NAME"
    if ! cp "$OUTPUT_FILE" "$NAS_DIR/$OUTPUT_NAME/"; then
        log "${YELLOW}[WARN]${NC} NAS copy failed - file still at $OUTPUT_FILE"
        notify "SuaRip Warning" "NAS copy failed - $OUTPUT_NAME saved locally"
    else
        local NAS_SIZE
        NAS_SIZE=$(du -sh "$NAS_DIR/$OUTPUT_NAME/$(basename "$OUTPUT_FILE")" | cut -f1)
        log "${GREEN}[INFO]${NC} NAS copy complete: $NAS_SIZE"
    fi
}

# =============================================================================
# CORE - Run all steps
# =============================================================================
run() {
    trap 'log "${RED}[ERROR]${NC} Script interrupted"; rm -f "$LOCK_FILE"; exit 1' INT TERM

    check_lock

    detect_disc
    lookup_metadata

    if [ "$USE_MAKEMKV" = true ]; then
        rip_makemkv
    else
        rip_ddrescue
    fi

    transcode
    copy_to_nas
    cleanup
    eject_disc

    rm -f "$LOCK_FILE"

    log "\n${GREEN}========================================${NC}"
    log "${GREEN}  Done! $OUTPUT_NAME is ready${NC}"
    log "${GREEN}  Location: $OUTPUT_DIR/$OUTPUT_NAME/${NC}"
    if [ -n "$NAS_DIR" ]; then
        log "${GREEN}  NAS: $NAS_DIR/$OUTPUT_NAME/${NC}"
    fi
    log "${GREEN}  Log: $LOG_FILE${NC}"
    log "${GREEN}========================================${NC}"

    notify "SuaRip Complete" "$OUTPUT_NAME is ready!"
}

# =============================================================================
# MAIN - Inhibit sleep then run
# =============================================================================
if [ "$1" = "--no-inhibit" ]; then
    shift
    run "$@"
elif command -v systemd-inhibit &>/dev/null; then
    exec systemd-inhibit \
        --what=sleep:idle \
        --who="SuaRip" \
        --why="Ripping and transcoding disc" \
        --mode=block \
        "$0" --no-inhibit "$@"
else
    run "$@"
fi


# =============================================================================
# UDEV RULES - Auto-trigger on disc insert
# =============================================================================
# Create /etc/udev/rules.d/99-suarip.rules with the following content.
# Replace 'vegatron5' with your username in both places.
#
# Trigger on internal drive (sr0):
#   ACTION=="change", KERNEL=="sr0", ENV{ID_CDROM_MEDIA_DVD}=="1", \
#   RUN+="/bin/su vegatron5 -c '/home/vegatron5/suarip.sh'"
#
# Trigger on USB drive (sr1) - also catches Blu-ray:
#   ACTION=="change", KERNEL=="sr1", ENV{ID_CDROM_MEDIA}=="1", \
#   RUN+="/bin/su vegatron5 -c '/home/vegatron5/suarip.sh'"
#
# Reload udev rules after creating the file:
#   sudo udevadm control --reload-rules
# =============================================================================
