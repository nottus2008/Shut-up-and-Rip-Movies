#!/bin/bash
# =============================================================================
# suarip.sh - Shut Up And Rip
# Automatic DVD/Blu-ray Ripping and Transcoding Script
# =============================================================================
# Version: 1.9.4-beta
# Dependencies: makemkvcon, HandBrakeCLI, curl, python3, ddrescue, dvdbackup
# =============================================================================

# =============================================================================
# CONFIG - Edit these values
# =============================================================================
INTERNAL_DRIVE="/dev/sr0"               # Internal optical drive
USB_DRIVE="/dev/sr1"                    # USB/external optical drive
TEMP_DIR="/mnt/scratch/suarip_temp"     # Scratch space for temp rip files
OUTPUT_DIR="$HOME/Videos/Suarip_Local"  # Local staging
NAS_DIR="/mnt/nas/Media/Movies"         # NAS Movie Library
NAS_TV_DIR="/mnt/nas/Media/TV Shows"    # NAS TV Library (Jellyfin/Plex)
OMDB_API_KEY="8f823ae7"                         # ⚠️ FILL THIS IN

DVD_PRESET="HQ 720p30 Surround"         # HandBrake preset for DVD
BLURAY_PRESET="HQ 1080p30 Surround"     # HandBrake preset for Blu-ray
RF_QUALITY="19"                         # RF quality (18-22 is good)
LOG_DIR="$HOME/.local/share/suarip"      # Log directory
NOTIFY=true                             # Desktop notifications
AUTO_EJECT=true                         # Eject disc when done
CONFIRM_METADATA=false                  # false = fully headless
MIN_TITLE_SECONDS=900                   # Min title length (15m for TV episodes)
MAKEMKV_TIMEOUT=3600                    # MakeMKV timeout (60 min)
DDRESCUE_RETRIES=3                      # ddrescue bad sector retry count
EPISODE_START=6

# Hardware Acceleration (VAAPI)
USE_VAAPI=true                          # Use VAAPI GPU encoding
VAAPI_ENCODER="vaapi_h264"              # HandBrake encoder flag
VAAPI_DETECT="h264_vaapi"               # ffmpeg codec name
VAAPI_QUALITY="22"                      # VAAPI quality

# Remote Notifications
NTFY_TOPIC="suarip-vegatron5"                           # ⚠️ FILL THIS IN for push notifications
NTFY_SERVER="ntfy.sh"                   # ntfy server
RESCUE_PROMPT_TIMEOUT=20                # Seconds to wait for startup prompt
# =============================================================================

VERSION="1.9.4-beta"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# State
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/suarip_$TIMESTAMP.log"
IS_BLURAY=false
IS_TV_SERIES=false
SERIES_NAME=""
SEASON_NUM="01"
PRESET="$DVD_PRESET"
ACTIVE_DRIVE=""
USE_MAKEMKV=false
RESCUE_MODE=false
OUTPUT_NAME=""
LOCK_FILE="/tmp/suarip.lock"
MAKEMKV_CMD=()

# =============================================================================
# WEB UI OVERRIDES - ripgui.py sets these env vars instead of stdin prompts
# Must come AFTER State init above so they aren't reset
# =============================================================================
[ "${SUARIP_TYPE:-}"    = "tv" ]  && IS_TV_SERIES=true
[ -n "${SUARIP_SERIES:-}" ]       && SERIES_NAME="$SUARIP_SERIES"
[ -n "${SUARIP_SEASON:-}" ]       && SEASON_NUM=$(printf "%02d" "${SUARIP_SEASON#0}")
[ -n "${SUARIP_EP_START:-}" ]     && EPISODE_START="$SUARIP_EP_START"
[ -n "${SUARIP_RESCUE:-}" ]       && RESCUE_MODE=true
[ -n "${SUARIP_DRIVE:-}" ]        && INTERNAL_DRIVE="$SUARIP_DRIVE"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
log() { echo -e "$1" | tee -a "$LOG_FILE"; }

notify() {
    local title="$1" message="$2"
    log "${BLUE}[NOTIFY]${NC} $title: $message"
    if [ "$NOTIFY" = true ] && command -v notify-send &>/dev/null; then
        notify-send "$title" "$message" --icon=media-optical 2>/dev/null || true
    fi
}

ntfy() {
    if [ -n "$NTFY_TOPIC" ]; then
        curl -s -H "Priority: ${2:-default}" -H "Tags: movie,dvd" -d "$1" "https://${NTFY_SERVER}/${NTFY_TOPIC}" >> "$LOG_FILE" 2>&1 || true
    fi
}

error_exit() {
    log "${RED}[ERROR]${NC} $1"
    log "${YELLOW}[INFO]${NC} Temp files preserved for debugging: $TEMP_DIR"
    log "${YELLOW}[INFO]${NC} Log file: $LOG_FILE"
    notify "SuaRip Failed" "$1"
    ntfy "❌ SuaRip Failed: $1" "high"
    rm -f "$LOCK_FILE"
    exit 1
}

check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        OLD_PID=$(cat "$LOCK_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Already running (PID $OLD_PID)"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

detect_makemkv() {
    if command -v makemkvcon &>/dev/null; then
        MAKEMKV="makemkvcon"
        MAKEMKV_CMD=(makemkvcon)
    elif flatpak list 2>/dev/null | grep -q "com.makemkv.MakeMKV"; then
        MAKEMKV="flatpak"
        MAKEMKV_CMD=(flatpak run --command=makemkvcon --device=all com.makemkv.MakeMKV)
    else
        MAKEMKV=""
        error_exit "MakeMKV not found! Please install it."
    fi
}

# =============================================================================
# LOGIC STEPS
# =============================================================================

prompt_startup_options() {
    [ ! -t 0 ] && return
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         SuaRip v${VERSION} Options         ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"

    echo -e "${YELLOW}[1] Content Type:${NC}"
    echo "    (m) Movie [Default]"
    echo "    (t) TV Series"
    read -t "$RESCUE_PROMPT_TIMEOUT" -n 1 -p "Selection: " type_key
    echo ""
    [[ "$type_key" == "t" || "$type_key" == "T" ]] && IS_TV_SERIES=true

    echo -e "${YELLOW}[2] Rip Mode:${NC}"
    echo "    (n) Normal (MakeMKV) [Default]"
    echo "    (r) Rescue (ddrescue for damaged discs)"
    read -t "$RESCUE_PROMPT_TIMEOUT" -n 1 -p "Selection: " rescue_key
    echo ""
    [[ "$rescue_key" == "r" || "$rescue_key" == "R" ]] && RESCUE_MODE=true
}

detect_disc() {
    log "\n${BLUE}=== SuaRip v${VERSION} ===${NC}"
    detect_makemkv

    for drive in "$INTERNAL_DRIVE" "$USB_DRIVE"; do
        if [ -n "$drive" ] && blkid "$drive" &>/dev/null; then
            ACTIVE_DRIVE="$drive"
            break
        fi
    done

    [ -z "$ACTIVE_DRIVE" ] && error_exit "No disc found in configured drives."

    RAW_LABEL=$(blkid -o value -s LABEL "$ACTIVE_DRIVE" 2>/dev/null | tr -d '<>' | tr ' ' '_')
    [ -z "$RAW_LABEL" ] && RAW_LABEL="UNKNOWN_$TIMESTAMP"

    # Check for Blu-ray
    local mnt="/tmp/suarip_mnt_$$"; mkdir -p "$mnt"
    if mount "$ACTIVE_DRIVE" "$mnt" 2>/dev/null; then
        if [ -d "$mnt/BDMV" ]; then
            IS_BLURAY=true
            PRESET="$BLURAY_PRESET"
            log "${BLUE}[INFO]${NC} Blu-ray detected."
        else
            log "${BLUE}[INFO]${NC} DVD detected."
        fi
        umount "$mnt" 2>/dev/null
    fi
    rmdir "$mnt"

    # Decide Pipeline
    if [ "$RESCUE_MODE" = true ]; then
        USE_MAKEMKV=false
    elif [ "$IS_BLURAY" = true ]; then
        USE_MAKEMKV=true
    else
        USE_MAKEMKV=$([ -n "$MAKEMKV" ] && echo true || echo false)
    fi
}

lookup_metadata() {
    if [ "$IS_TV_SERIES" = true ]; then
      echo -e "${YELLOW}[TV MODE]${NC} Meta-data Input Required:"
      output_dir="${OUTPUT_DIR:-/path/to/default}"  # Use default or CLI argument
      output_dir="${OUTPUT_DIR:-/path/to/default}"  # Use default or CLI argument
      SEASON_NUM=$(printf "%02d" "${SEASON_NUM#0}")
      output_dir="${OUTPUT_DIR:-/path/to/default}"  # Use default or CLI argument
      EPISODE_START=${ep_start:-1}
      OUTPUT_NAME="$SERIES_NAME"
    fi

    # Movie OMDB Logic
    local base=$(echo "$RAW_LABEL" | tr '_' ' ' | tr '[:upper:]' '[:lower:]' | sed 's/\bdisc[0-9]*\b//gi' | sed 's/ \+/ /g')
    if [ -n "$OMDB_API_KEY" ]; then
        log "${YELLOW}[INFO]${NC} Querying OMDB for Movie metadata..."
        local encoded=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" -- "$base")
        local resp=$(curl -s "https://www.omdbapi.com/?t=${encoded}&apikey=${OMDB_API_KEY}&type=movie")
        if [ "$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Response',''))")" = "True" ]; then
            local title=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Title',''))")
            local year=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Year',''))" | grep -o '[0-9]\{4\}')
            OUTPUT_NAME="$title ($year)"
            log "${GREEN}[INFO]${NC} Found: $OUTPUT_NAME"
        fi
    fi
    [ -z "$OUTPUT_NAME" ] && OUTPUT_NAME="$base"
}

rip() {
    mkdir -p "$TEMP_DIR"

    if [ "$USE_MAKEMKV" = true ]; then
        log "${GREEN}[RIP]${NC} Ripping with MakeMKV (MinLength: ${MIN_TITLE_SECONDS}s)..."
        "${MAKEMKV_CMD[@]}" mkv dev:"$ACTIVE_DRIVE" all "$TEMP_DIR" --minlength=$MIN_TITLE_SECONDS >> "$LOG_FILE" 2>&1

        # Verify output
        if [ -z "$(ls -A "$TEMP_DIR"/*.mkv 2>/dev/null)" ]; then
            error_exit "MakeMKV produced no titles. Check disc or lower MIN_TITLE_SECONDS."
        fi
    else
        log "${RED}[RESCUE]${NC} Using ddrescue to image damaged disc..."
        ddrescue -d -r"$DDRESCUE_RETRIES" "$ACTIVE_DRIVE" "$TEMP_DIR/disc.iso" "$TEMP_DIR/rescue.log" >> "$LOG_FILE" 2>&1
        # Rescue mode usually requires manual follow-up or mounting the ISO
        log "${YELLOW}[INFO]${NC} Rescue ISO created at $TEMP_DIR/disc.iso"
    fi
}

transcode() {
    log "\n${YELLOW}[INFO]${NC} Starting Transcode Pipeline..."

    # Detect VAAPI once before the loop - never blindly trust USE_VAAPI=true
    local USE_HW=false
    if [ "$USE_VAAPI" = true ]; then
        if HandBrakeCLI -e list 2>&1 | grep -qi "$VAAPI_DETECT"; then
            USE_HW=true
            log "${GREEN}[INFO]${NC} VAAPI available - using ${VAAPI_ENCODER}"
        else
            log "${YELLOW}[WARN]${NC} VAAPI not available - falling back to software (x264)"
        fi
    fi

    local files=()
    mapfile -t files < <(find "$TEMP_DIR" -maxdepth 1 -name "*.mkv" | sort)

    if [ ${#files[@]} -eq 0 ]; then
        error_exit "No MKV files found in temp dir to transcode."
    fi

    # Movie mode: only encode the largest MKV (main feature, not extras)
    if [ "$IS_TV_SERIES" = false ]; then
        local largest
        largest=$(find "$TEMP_DIR" -maxdepth 1 -name "*.mkv" -printf '%s %p\n' | sort -rn | head -1 | awk '{print $2}')
        files=("$largest")
        log "${YELLOW}[INFO]${NC} Movie mode: using largest title: $(basename "$largest")"
    else
        log "${YELLOW}[INFO]${NC} TV mode: found ${#files[@]} episode(s) to encode"
    fi

    local count=${EPISODE_START:-1}
    for f in "${files[@]}"; do
        local final_name rel_path nas_root local_out

        if [ "$IS_TV_SERIES" = true ]; then
            local ep
            ep=$(printf "%02d" $count)
            final_name="${SERIES_NAME} - S${SEASON_NUM}E${ep}"
            rel_path="${SERIES_NAME}/Season ${SEASON_NUM}/${final_name}.mkv"
            nas_root="$NAS_TV_DIR"
        else
            final_name="$OUTPUT_NAME"
            rel_path="${OUTPUT_NAME}/${OUTPUT_NAME}.mkv"
            nas_root="$NAS_DIR"
        fi

        local_out="$OUTPUT_DIR/$rel_path"
        mkdir -p "$(dirname "$local_out")"

        log "${GREEN}[ENCODE]${NC} $(basename "$f") -> ${final_name}"

        # Build HandBrake command.
        # Audio: grab up to 3 tracks, copy passthrough, fall back to AAC.
        # This prevents the no-audio issue caused by missing audio flags.
        # Quality: VAAPI uses --encoder-quality, software uses -q (RF).
        # Never mix the two - they are different scales.
        local hb_cmd=(
            HandBrakeCLI
            -i "$f"
            -o "$local_out"
            --preset "$PRESET"
            -a "1,2,3"
            --aencoder "copy"
            --audio-fallback "av_aac"
            --subtitle scan -F
        )

        if [ "$USE_HW" = true ]; then
            hb_cmd+=(--encoder "$VAAPI_ENCODER" --encoder-quality "$VAAPI_QUALITY")
            log "${YELLOW}[INFO]${NC} VAAPI encode | quality: $VAAPI_QUALITY"
        else
            hb_cmd+=(-q "$RF_QUALITY")
            log "${YELLOW}[INFO]${NC} Software encode | RF: $RF_QUALITY"
        fi

        # Tee HandBrake output to both the log file and stdout so ripgui.py
        # can parse live progress lines while the log file is also preserved.
        "${hb_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
        HB_EXIT=${PIPESTATUS[0]}

        if [ "$HB_EXIT" -eq 0 ]; then
            log "${GREEN}[INFO]${NC} Encode complete: $final_name ($(du -sh "$local_out" | cut -f1))"
        else
            log "${RED}[ERROR]${NC} HandBrake failed on $(basename "$f") - check $LOG_FILE"
            if [ "$USE_HW" = true ]; then
                log "${YELLOW}[WARN]${NC} Retrying with software encoding..."
                HandBrakeCLI -i "$f" -o "$local_out" --preset "$PRESET" \
                    -a "1,2,3" --aencoder "copy" --audio-fallback "av_aac" \
                    --subtitle scan -F -q "$RF_QUALITY" 2>&1 | tee -a "$LOG_FILE"
                if [ "${PIPESTATUS[0]}" -eq 0 ]; then
                    log "${GREEN}[INFO]${NC} Software fallback succeeded: $final_name"
                else
                    log "${RED}[ERROR]${NC} Software fallback also failed - skipping"
                    ((count++)); continue
                fi
            else
                log "${RED}[ERROR]${NC} Skipping this title"
                ((count++)); continue
            fi
        fi

        # Sync to NAS
        if [ -n "$nas_root" ] && [ -d "$nas_root" ]; then
            local nas_final="$nas_root/$rel_path"
            mkdir -p "$(dirname "$nas_final")"
            if cp "$local_out" "$nas_final"; then
                log "${BLUE}[NAS]${NC} Synced to $nas_final"
            else
                log "${YELLOW}[WARN]${NC} NAS copy failed - kept locally at $local_out"
            fi
        fi

        ((count++))
    done
}

run() {
    trap 'rm -f "$LOCK_FILE"; log "${RED}[ABORT]${NC} Script Interrupted - temp files preserved: $TEMP_DIR"; exit 1' INT TERM
    check_lock

    # Clean up previous run's temp files now (not after current run)
    # so they are available for inspection after any failure or success
    if [ -d "$TEMP_DIR" ]; then
        log "${YELLOW}[INFO]${NC} Clearing temp files from previous run: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi

    prompt_startup_options
    detect_disc
    lookup_metadata
    rip
    transcode

    [ "$AUTO_EJECT" = true ] && eject "$ACTIVE_DRIVE"
    rm -f "$LOCK_FILE"

    notify "SuaRip Complete" "$OUTPUT_NAME has been processed."
    ntfy "✅ $OUTPUT_NAME processed and synced to NAS." "default"
    log "\n${GREEN}COMPLETE!${NC} Enjoy your media."
    log "${YELLOW}[INFO]${NC} Temp files kept at $TEMP_DIR until next run"
    log "${YELLOW}[INFO]${NC} Log: $LOG_FILE"
}

# =============================================================================
# MAIN - Systemd Inhibit Logic
# =============================================================================
if [ "$1" = "--no-inhibit" ]; then
    shift
    run "$@"
elif command -v systemd-inhibit &>/dev/null && systemd-inhibit --list &>/dev/null 2>&1; then
    exec systemd-inhibit \
        --what=sleep:idle \
        --who="SuaRip" \
        --why="Ripping and transcoding media" \
        --mode=block \
        "$0" --no-inhibit "$@"
else
    run "$@"
fi
