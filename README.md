# Shut Up And Rip Movies 🎬

![Version](https://img.shields.io/badge/version-1.9.5--beta-blue)
![License](https://img.shields.io/badge/license-MIT-green)

**Automatic DVD/Blu-ray ripping and transcoding — because ARM made my head hurt.**

`suarip.sh` is a single bash script that handles the full pipeline: detect disc → look up metadata → rip → transcode → copy to NAS → eject. Insert a disc, walk away, find a properly named MKV waiting for you on your media server.

New in 1.9.x: a Flask web UI (`ripgui.py` + `index.html`) with real-time log streaming, a live HandBrake progress bar, and a falling domino animation because why not.

---

## Features

- **Fully headless/unattended operation** — designed for a dedicated ripper box you SSH into or forget about entirely
- **Web UI** — browser-based interface with real-time log streaming, live encode progress bar, and drive/mode selection. No SSH required
- **TV series support** — rips multi-episode discs and outputs Jellyfin/Plex-compatible `Show - S01E01.mkv` naming
- **Dual drive routing** — configure separate internal and USB drives; the script detects which one has the disc
- **Blu-ray support** — MakeMKV handles BD+ and AACS encryption automatically
- **Smart metadata lookup** — multi-strategy OMDB search cleans disc labels and tries progressively simpler queries until it finds a match. Outputs `Movie Title (Year).mkv` compatible with Plex, Jellyfin, and Emby
- **VAAPI hardware encoding** — offloads transcoding to GPU for dramatically faster encodes (300-400+ fps vs ~25fps software)
- **Rescue mode** — ddrescue pipeline for damaged or scratched discs that MakeMKV can't handle
- **VAAPI → software fallback** — if hardware encoding fails mid-encode, automatically retries in software
- **Lock file** — prevents multiple instances from running simultaneously
- **NAS copy** — copies finished MKV to a network share automatically, with separate paths for Movies and TV Shows
- **Sleep inhibition** — prevents the system from sleeping during a rip/transcode via `systemd-inhibit`
- **Push notifications** — ntfy.sh push notifications to your phone at every pipeline stage
- **Desktop notifications** — `notify-send` alerts at each pipeline stage
- **Preserves temp files on failure** — so you can manually recover a partial rip

---

## Requirements

### Hardware
- Optical drive (DVD or Blu-ray)
- Enough disk space for temp files: ~10GB for DVD, ~50GB for Blu-ray
- A scratch/temp directory (a separate drive is recommended to avoid I/O contention)

### Software
| Tool | Purpose | Required |
|------|---------|----------|
| MakeMKV | Blu-ray ripping, DVD ripping | Yes (for Blu-ray) |
| HandBrake CLI | Transcoding | Yes |
| ddrescue | Rescue mode for damaged discs | Optional |
| libdvdcss | CSS decryption for commercial DVDs | Yes |
| curl + python3 | OMDB metadata lookup + ntfy notifications | Yes |
| python3 + flask | Web UI | Optional |
| libnotify | Desktop notifications | Optional |

---

## Installation

### Ubuntu / Ubuntu Server (Recommended)

Ubuntu Server 24.04 LTS is the recommended OS for a dedicated ripper — PPA compatibility is best-in-class, LTS support runs to 2029, and no desktop overhead during long encodes.

```bash
sudo add-apt-repository ppa:stebbins/handbrake-releases
sudo apt install handbrake-cli curl python3 python3-pip libnotify-bin gddrescue
sudo apt install libdvd-pkg && sudo dpkg-reconfigure libdvd-pkg
sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
sudo usermod -aG cdrom $USER
pip3 install flask
```

Install MakeMKV from source: https://forum.makemkv.com/forum/viewtopic.php?f=3&t=224

Or via PPA:
```bash
sudo add-apt-repository ppa:heyarje/makemkv-beta
sudo apt update
sudo apt install makemkv-bin makemkv-oss
```

### Fedora / Nobara

> **Important:** `libdvdcss` is not in the default Fedora/Nobara repos due to legal restrictions. Enable the RPM Fusion **tainted** repo first:

```bash
sudo dnf install \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

sudo dnf install rpmfusion-free-release-tainted
sudo dnf install libdvdcss HandBrake-cli curl python3 python3-pip libnotify ddrescue
sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
sudo usermod -aG cdrom $USER
pip3 install flask
```

Install MakeMKV from source: https://forum.makemkv.com/forum/viewtopic.php?f=3&t=224

Or install MakeMKV as a Flatpak (see Flatpak section below).

### Arch / Endeavour / CachyOS
```bash
sudo pacman -S handbrake-cli curl python3 python-pip libnotify ddrescue
sudo pacman -S libdvdcss libdvdread libdvdnav
sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
sudo usermod -aG optical $USER
pip install flask
```

Install MakeMKV via AUR (`yay -S makemkv`) or from source.

> **Note:** On Arch-based systems the optical drive group is `optical`, not `cdrom`. Log out and back in after adding yourself to the group.

---

## MakeMKV as a Flatpak

If you install MakeMKV via Flatpak rather than native, grant it device access so it can see your optical drives:

```bash
flatpak install flathub com.makemkv.MakeMKV
flatpak override --user --device=all com.makemkv.MakeMKV
```

The script detects MakeMKV automatically whether installed natively or as a Flatpak.

---

## sudoers Entry

The script uses `sudo mount` and `sudo umount` for disc detection. To allow passwordless operation (required for unattended/udev use):

```bash
sudo visudo
```

Add this line, replacing `yourusername` with your actual username:

```
yourusername ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount
```

---

## Setup

1. Clone the repo or download the files into a folder:
```
suarip-beta1_9_5.sh
ripgui.py
index.html
```

2. Make the script executable:
```bash
chmod +x suarip-beta1_9_5.sh
```

3. Edit the CONFIG section at the top of the script:
```bash
INTERNAL_DRIVE="/dev/sr0"               # Your internal optical drive
USB_DRIVE="/dev/sr1"                    # Your USB/external drive (leave empty if none)
TEMP_DIR="/mnt/scratch/suarip_temp"     # Scratch space (separate drive recommended)
OUTPUT_DIR="$HOME/Videos/Suarip_Local"  # Local staging before NAS copy
NAS_DIR="/mnt/nas/Media/Movies"         # NAS Movies library
NAS_TV_DIR="/mnt/nas/Media/TV Shows"    # NAS TV library
OMDB_API_KEY="your_key_here"            # Free key from https://www.omdbapi.com/
NTFY_TOPIC="your-topic-here"            # ntfy.sh topic (leave empty to skip)
```

4. Get a free OMDB API key at https://www.omdbapi.com/apikey.aspx

5. (Optional) Set up ntfy.sh push notifications at https://ntfy.sh

6. Test it manually first:
```bash
./suarip-beta1_9_5.sh
```

---

## Usage

### Interactive CLI

Insert a disc and run the script. On startup it prompts for content type (Movie or TV) and rip mode (Normal or Rescue). Prompts time out automatically and default to Movie + Normal, so you can walk away.

```bash
./suarip-beta1_9_5.sh
```

### Web UI

All three files (`suarip-beta1_9_5.sh`, `ripgui.py`, `index.html`) must be in the same directory.

```bash
python3 ripgui.py
```

Then open `http://localhost:5000` (or `http://your-ripper-ip:5000` from another machine on your network).

The web UI lets you select drive, content type, TV series details, and rip mode — then streams the full log output in real time. When HandBrake starts encoding, a live progress bar and falling domino animation appear.

### Headless via Environment Variables

The script accepts configuration via environment variables, bypassing interactive prompts entirely. Useful for scripting or automation:

```bash
# Rip a movie (default)
./suarip-beta1_9_5.sh

# Rip a TV series disc
SUARIP_TYPE=tv \
SUARIP_SERIES="Breaking Bad" \
SUARIP_SEASON=2 \
SUARIP_EP_START=6 \
./suarip-beta1_9_5.sh

# Rescue mode for a damaged disc
SUARIP_RESCUE=1 ./suarip-beta1_9_5.sh
```

| Variable | Values | Description |
|----------|--------|-------------|
| `SUARIP_TYPE` | `movie` / `tv` | Content type |
| `SUARIP_SERIES` | string | TV series name |
| `SUARIP_SEASON` | number | Season number |
| `SUARIP_EP_START` | number | First episode number on this disc |
| `SUARIP_RESCUE` | `1` | Enable ddrescue rescue mode |
| `SUARIP_DRIVE` | `/dev/sr0` etc. | Override drive device |

### Automatic on disc insert (udev)

Create `/etc/udev/rules.d/99-suarip.rules` — replace `yourusername` in both places:

```
# Internal drive (sr0)
ACTION=="change", KERNEL=="sr0", ENV{ID_CDROM_MEDIA_DVD}=="1", \
RUN+="/bin/su yourusername -c '/home/yourusername/suarip-beta1_9_5.sh'"

# USB/external drive (sr1) - also catches Blu-ray
ACTION=="change", KERNEL=="sr1", ENV{ID_CDROM_MEDIA}=="1", \
RUN+="/bin/su yourusername -c '/home/yourusername/suarip-beta1_9_5.sh'"
```

Reload udev rules:
```bash
sudo udevadm control --reload-rules
```

> **Note:** The script includes an eject guard — when a rip finishes and the drive ejects, udev fires a second `change` event. The script detects no disc is present and exits silently, preventing spurious error notifications.

### Monitoring a running CLI rip

```bash
tail -f ~/.local/share/suarip/suarip_*.log
```

### Running CLI headless (survives SSH disconnect)

```bash
tmux new -s rip
./suarip-beta1_9_5.sh
# Detach: Ctrl+B D
# Reattach: tmux attach -t rip
```

---

## TV Series Mode

When ripping a TV series disc, the script names output files in Jellyfin/Plex/Emby-compatible format:

```
Show Name/
  Season 01/
    Show Name - S01E01.mkv
    Show Name - S01E02.mkv
    ...
```

Set `MIN_TITLE_SECONDS=900` (15 minutes) in the config to ensure episode-length titles are included while short extras are filtered out. The default 900s works well for most TV releases.

When using the web UI, expand the TV Series fields after selecting "TV Series" to enter the series name, season number, and the first episode number on the disc (useful when a season spans multiple discs).

---

## Configuration Reference

| Setting | Default | Description |
|---------|---------|-------------|
| `INTERNAL_DRIVE` | `/dev/sr0` | Internal optical drive device |
| `USB_DRIVE` | `/dev/sr1` | USB/external drive (empty to disable) |
| `TEMP_DIR` | `/mnt/scratch/suarip_temp` | Scratch directory for temp files |
| `OUTPUT_DIR` | `~/Videos/Suarip_Local` | Local output directory |
| `NAS_DIR` | *(your path)* | NAS Movies library path |
| `NAS_TV_DIR` | *(your path)* | NAS TV Shows library path |
| `OMDB_API_KEY` | *(your key)* | OMDB API key for metadata |
| `DVD_PRESET` | `HQ 720p30 Surround` | HandBrake preset for DVDs |
| `BLURAY_PRESET` | `HQ 1080p30 Surround` | HandBrake preset for Blu-ray |
| `RF_QUALITY` | `19` | RF quality (18-22 recommended, lower=better) |
| `NOTIFY` | `true` | Desktop notifications |
| `AUTO_EJECT` | `true` | Eject disc when done |
| `CONFIRM_METADATA` | `false` | Prompt to confirm/correct movie title |
| `MIN_TITLE_SECONDS` | `900` | MakeMKV minimum title length in seconds |
| `MAKEMKV_TIMEOUT` | `3600` | MakeMKV timeout in seconds |
| `DDRESCUE_RETRIES` | `3` | Bad sector retries for ddrescue |
| `EPISODE_START` | `1` | Default starting episode number |
| `USE_VAAPI` | `true` | Enable VAAPI GPU hardware encoding |
| `VAAPI_ENCODER` | `vaapi_h264` | HandBrake encoder flag name |
| `VAAPI_DETECT` | `h264_vaapi` | ffmpeg codec name used for VAAPI detection |
| `VAAPI_QUALITY` | `22` | VAAPI quality (higher=better, unlike RF) |
| `NTFY_TOPIC` | *(empty)* | ntfy.sh topic — leave empty to disable |
| `NTFY_SERVER` | `ntfy.sh` | ntfy server (change for self-hosted) |
| `RESCUE_PROMPT_TIMEOUT` | `20` | Seconds to wait at startup prompt |

> **VAAPI note:** `VAAPI_ENCODER` and `VAAPI_DETECT` are intentionally different values. HandBrake uses `vaapi_h264` as its `--encoder` flag, but the ffmpeg codec name shown in `HandBrakeCLI -e list` output is `h264_vaapi`. The script uses `VAAPI_DETECT` to check availability and `VAAPI_ENCODER` to invoke it.

---

## How It Works

### Drive routing
```
Disc inserted
     │
     ├─ Rescue mode? ──────────────────► ddrescue → ISO (manual follow-up)
     │
     ├─ Blu-ray? ──────────────────────► MakeMKV → HandBrake
     │
     └─ DVD? ──────────────────────────► MakeMKV → HandBrake
```

### Metadata lookup (movies)
The script tries up to 5 progressively simpler OMDB searches before giving up:
1. Cleaned disc label + year hint (if year found in label)
2. Cleaned disc label, no year
3. Label with edition words stripped (Director's Cut, Special Edition, etc.)
4. First 3 words of label
5. First 2 words of label

On failure with `CONFIRM_METADATA=false` it uses the cleaned disc label title-cased. All attempted searches are logged for debugging.

### VAAPI hardware encoding
When `USE_VAAPI=true` the script checks whether VAAPI is available before each transcode. If available it uses GPU hardware encoding (100-200+ fps on supported hardware). If VAAPI fails mid-encode it automatically retries in software. Software encoding remains the fallback on systems without GPU support.

### Push notifications (ntfy.sh)
When `NTFY_TOPIC` is set, the script sends push notifications at every major stage: ripping started, transcoding started, copying to NAS, done, and on any error. Works with the free ntfy.sh service or a self-hosted ntfy instance.

---

## Known Limitations

- **Generic disc labels** — some discs have unhelpful labels like `SONY` or `COLUMBIA` rather than the movie title. OMDB will match incorrectly or not at all. Rename the output file manually after the rip. This is a disc mastering quirk, not something the script can reliably detect.
- **Single-word labels** — disc labels that are just one word are too ambiguous for reliable OMDB lookup. Common offenders: `SONY`, `COLUMBIA`, `WARNER`, `UNIVERSAL`.
- **Title detection** — HandBrake's longest title detection may default to title 1 on some discs. This is usually correct but edge cases exist. Check the output if a rip looks wrong.
- **Multi-disc TV sets** — each disc must be ripped separately. Use `EPISODE_START` (or the web UI "First Episode #" field) to set the correct starting episode number for disc 2, 3, etc.

---

## Drive Compatibility Notes

Hard-won knowledge from real-world testing:

**Internal drives and MakeMKV:** Some older internal drives have compatibility issues with MakeMKV's SCSI generic (`sg`) interface and will hang silently. If MakeMKV hangs on disc detection but `dvdbackup` works fine, this is likely the cause. Try rescue mode as a workaround.

**Known problematic drives with MakeMKV:**
- HL-DT-ST DVD+-RW GH50N (firmware B103) — hangs at SDF lookup stage

**USB drives:** USB optical drives tend to work well with MakeMKV. Use MakeMKV mode (Normal) for USB drives.

**libdvdcss:** Make sure it's installed and up to date. An outdated libdvdcss will fail silently on some discs. On Fedora/Nobara this requires the RPM Fusion tainted repo (see Installation above).

**sg module:** MakeMKV requires the SCSI generic kernel module. Verify it's loaded:
```bash
lsmod | grep sg
# If not loaded:
sudo modprobe sg
# To persist across reboots:
echo "sg" | sudo tee /etc/modules-load.d/sg.conf
```

---

## Tested Hardware

| Machine | CPU | GPU | OS | Notes |
|---------|-----|-----|----|-------|
| Custom build | AMD Ryzen 5 5600G | Radeon RX 6600 | Nobara Linux | VAAPI working, 300-400+ fps transcode |
| Mac Mini 5,1 | Intel Core i5-2520M | Intel HD 3000 | Ubuntu | Works, ~25fps software transcode |
| Custom AM1 build | AMD Athlon 5350 | AMD GCN | Endeavour OS | Works with ddrescue, ~25fps transcode |

---

## Troubleshooting

**MakeMKV hangs silently on disc scan:**
- Check `sg` module is loaded: `lsmod | grep sg`
- Try `makemkvcon f -l` to see if the drive is detected
- Try with explicit device path: `makemkvcon -r info dev:/dev/sr0`
- If the disc is scratched or damaged, switch to Rescue mode

**VAAPI not activating:**
- Check VAAPI is working: `vainfo`
- Check `/dev/dri/` exists and your user has access
- Run `HandBrakeCLI -e list 2>&1 | grep vaapi` — look for `h264_vaapi: err 0`
- Verify `VAAPI_DETECT="h264_vaapi"` and `VAAPI_ENCODER="vaapi_h264"` in config

**Disc label not found / OMDB returns wrong movie:**
- Check what the script logged for its search attempts
- Set `CONFIRM_METADATA=true` to manually correct titles
- Rename the output file manually and re-add to Jellyfin/Plex
- See Known Limitations above for generic label cases

**HandBrake error / invalid encoder:**
- Check `VAAPI_ENCODER` and `VAAPI_DETECT` values match your HandBrake version
- Check the full log for the actual error
- Verify the source file is valid: `ffprobe /path/to/source.mkv`

**Web UI: can't connect to server:**
- Confirm Flask is installed: `pip3 show flask`
- Run from the directory containing all three files: `cd /path/to/ripgui && python3 ripgui.py`
- Check the port isn't in use: `ss -tlnp | grep 5000`
- On macOS, port 5000 may be taken by AirPlay Receiver — disable it in System Settings or change the port in `ripgui.py`

**Web UI: TV series fields don't appear:**
- Click the "TV Series" segment button and the fields should slide down
- If not, hard refresh the browser (Ctrl+Shift+R) to clear any cached old version of index.html

**sudo password prompt during unattended run:**
- Add the sudoers entry for mount/umount (see sudoers section above)

**Permission denied on temp directory:**
- Check ownership: `ls -la /mnt/scratch`
- Fix: `sudo chown $USER:$USER /mnt/scratch`

**NAS copy fails:**
- Verify the share is mounted: `mountpoint /mnt/nas`
- Check credentials file permissions: `chmod 600 ~/.nascredentials`
- The script saves locally and warns if NAS is unavailable

**Multiple MakeMKV processes running:**
- Kill them: `sudo killall makemkvcon`
- The lock file prevents this in normal operation but manual runs can stack up

---

## Roadmap

- [x] Hardware encoding support (VAAPI) — 100-200+ fps on supported GPUs *(v1.2-beta)*
- [x] Push notifications (ntfy.sh) — phone alerts at every pipeline stage *(v1.1-beta)*
- [x] TV show / multi-episode disc support *(v1.7-beta)*
- [x] Web UI — browser interface with real-time log streaming *(v1.8-beta)*
- [x] Live HandBrake progress bar *(v1.9-beta)*
- [ ] Multiple drive queue support
- [ ] Movie poster art in web UI (OMDB already returns it)
- [ ] Systemd service file for auto-starting the web UI on boot
- [ ] Progress notifications at percentage milestones (ntfy)

---

## Why Not ARM?

[Automatic Ripping Machine](https://github.com/automatic-ripping-machine/automatic-ripping-machine) is a great project but can be complex to set up and maintain, especially on non-standard hardware or distros. SuaRip started as a single bash file with no Docker, no database, no config UI — just insert disc, get MKV. The web UI was added later as an optional convenience layer, not a requirement.

---

## Changelog

### v1.9.5-beta
- Fixed stray `from flask import...` Python line inside the bash script utility functions — caused parse errors in some environments
- Fixed web UI path resolution — `ripgui.py` now serves `index.html` relative to its own location rather than the working directory, so it works regardless of where you launch it from
- Fixed TV series fields toggle in web UI — event listeners now attach directly to individual radio IDs instead of using a `querySelectorAll` loop, which was silently failing due to shell heredoc escaping of attribute selectors
- Fixed HandBrake progress line parsing — reader now handles `\r` (carriage return) line endings that HandBrakeCLI uses for in-place progress updates, so progress data is correctly captured instead of being swallowed

### v1.9-beta
- Added web UI progress bar — slides in when HandBrake encoding begins, shows live percentage, FPS, and ETA parsed from HandBrakeCLI output
- Added falling domino animation (`| | | → / | | → _ / | → _ _ /`) displayed during encode
- Added indeterminate progress bar animation during MakeMKV rip phase (before percentage data is available)
- Progress lines filtered from log output — HandBrake progress updates no longer flood the log panel
- SSE stream now handles `\r`-terminated HandBrake output correctly via character-by-character reading

### v1.8-beta
- Added web UI (`ripgui.py` + `index.html`) — Flask server with Server-Sent Events for real-time log streaming
- All run options (drive, content type, TV series details, rip mode) configurable from the browser
- Page reload re-attaches to a running job automatically
- Stop button sends SIGTERM to the running script
- Log lines colour-coded by type (encode, info, warn, error, NAS sync)

### v1.7-beta
- Added TV series mode — rips multi-episode discs and outputs `Show - S01E02.mkv` naming compatible with Jellyfin, Plex, and Emby
- Added `NAS_TV_DIR` config for separate TV Shows library path
- Added `EPISODE_START` config for multi-disc season sets
- Added `SUARIP_TYPE`, `SUARIP_SERIES`, `SUARIP_SEASON`, `SUARIP_EP_START` environment variable overrides for headless/scripted use
- TV mode filters only episode-length titles using `MIN_TITLE_SECONDS` (set to 900 for 15-minute minimum)
- Movie mode now explicitly selects the largest MKV title (main feature) and skips extras

### v1.6-beta
- Added rescue mode prompt — on startup a prompt asks if you want the ddrescue recovery pipeline (press 'r'). Times out and defaults to normal MakeMKV mode automatically. Only shown in interactive terminal sessions, skipped when running headless via udev
- Added `RESCUE_PROMPT_TIMEOUT` config option (default 20s)
- Added `⚠️ FILL THIS IN` warnings on `OMDB_API_KEY` and `NTFY_TOPIC` config lines

### v1.5-beta
- Internal drive now routes through MakeMKV instead of ddrescue — ddrescue produced corrupt ISOs when scratch drive is on a separate ASMedia SATA controller causing controller crosstalk during simultaneous read/write
- ddrescue pipeline remains intact and is accessible via rescue mode

### v1.4-beta
- Fixed silent failure when `systemd-inhibit` is installed but broken — script now tests before using it and falls through gracefully
- Added `side[ab12]` stripping to disc label cleaner

### v1.3-beta
- Fixed VAAPI transcode missing `--preset` flag — previously VAAPI encodes had no resolution or H.264 level set, producing 360p files that Jellyfin/Plex could not transcode via HLS. **If you ripped movies with v1.2-beta or earlier using VAAPI, re-rip them.**

### v1.2-beta
- Fixed VAAPI detection — `VAAPI_ENCODER` and `VAAPI_DETECT` are now separate config values
- VAAPI encode failure now falls back to software automatically

### v1.1-beta
- Added ntfy.sh push notifications
- Added eject guard to prevent spurious error notifications

### v1.0-beta
- Initial release
- Dual drive routing, multi-strategy OMDB metadata, lock file, MakeMKV timeout, NAS copy, sleep inhibition, desktop notifications, udev support

---

## License

MIT
