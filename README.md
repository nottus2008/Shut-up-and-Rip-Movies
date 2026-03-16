# Shut Up And Rip Movies 🎬

![Version](https://img.shields.io/badge/version-1.0--beta-blue)
![License](https://img.shields.io/badge/license-MIT-green)

**Automatic DVD/Blu-ray ripping and transcoding — because ARM made my head hurt.**

`suarip.sh` is a single bash script that handles the full pipeline: detect disc → look up metadata → rip → transcode → copy to NAS → eject. Insert a disc, walk away, find a properly named MKV waiting for you on your media server.

---

## Features

- **Fully headless/unattended operation** — designed for a dedicated ripper box you SSH into
- **Dual drive routing** — internal drives use `ddrescue` (avoids SCSI compatibility issues), USB/external drives use MakeMKV
- **Blu-ray support** — MakeMKV handles BD+ and AACS encryption automatically
- **Smart metadata lookup** — multi-strategy OMDB search cleans disc labels and tries progressively simpler queries until it finds a match. Outputs `Movie Title (Year).mkv` compatible with Plex, Jellyfin, and Emby
- **ddrescue → dvdbackup fallback** — if ddrescue fails, automatically tries dvdbackup before giving up
- **Lock file** — prevents multiple instances from running simultaneously
- **MakeMKV timeout** — kills a hung MakeMKV process rather than waiting forever
- **NAS copy** — copies finished MKV to a network share automatically
- **Sleep inhibition** — prevents the system from sleeping during a rip/transcode
- **Desktop notifications** — notifies on each pipeline stage and on completion
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
| MakeMKV | Blu-ray ripping, USB drive DVDs | Yes (for Blu-ray) |
| HandBrake CLI | Transcoding | Yes |
| ddrescue | DVD ripping (internal drives) | Recommended |
| dvdbackup | DVD fallback ripper | Recommended |
| libdvdcss | CSS decryption for commercial DVDs | Yes |
| curl + python3 | OMDB metadata lookup | Yes |
| libnotify | Desktop notifications | Optional |

---

## Installation

### Fedora / Nobara
```bash
sudo dnf install HandBrake-cli curl python3 libnotify ddrescue dvdbackup
sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
sudo usermod -aG cdrom $USER
Fedora based distros will need to add the tainted repo to install libdvdcss 
sudo dnf install rpmfusion-free-release-tainted
sudo dnf install libdvdcss
Install MakeMKV from source: https://forum.makemkv.com/forum/viewtopic.php?f=3&t=224
```

### Ubuntu / Debian
```bash
sudo add-apt-repository ppa:stebbins/handbrake-releases
sudo apt install handbrake-cli curl python3 libnotify-bin gddrescue dvdbackup
sudo apt install libdvd-pkg && sudo dpkg-reconfigure libdvd-pkg
sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
sudo usermod -aG cdrom $USER
```
Install MakeMKV from source: https://forum.makemkv.com/forum/viewtopic.php?f=3&t=224

### Arch / Endeavour / CachyOS
```bash
sudo pacman -S handbrake-cli curl python3 libnotify ddrescue dvdbackup
sudo pacman -S libdvdcss libdvdread libdvdnav
sudo modprobe sg && echo "sg" | sudo tee /etc/modules-load.d/sg.conf
sudo usermod -aG optical $USER
```
Install MakeMKV via AUR (`yay -S makemkv`) or from source.

> **Note:** On Arch-based systems the optical drive group is `optical`, not `cdrom`. Log out and back in after adding yourself to the group.

---

## Setup

1. Download `suarip.sh` and make it executable:
```bash
chmod +x suarip.sh
```

2. Edit the CONFIG section at the top of the script:
```bash
INTERNAL_DRIVE="/dev/sr0"        # Your internal optical drive
USB_DRIVE="/dev/sr1"             # Your USB/external drive (leave empty if none)
TEMP_DIR="/mnt/scratch/suarip_temp"  # Scratch space for temp files
OUTPUT_DIR="$HOME/Videos/Movies" # Local output before NAS copy
NAS_DIR="/mnt/nas/Movies"        # NAS destination (leave empty to skip)
OMDB_API_KEY="your_key_here"     # Free key from https://www.omdbapi.com/
```

3. Get a free OMDB API key at https://www.omdbapi.com/apikey.aspx

4. Test it manually first:
```bash
./suarip.sh
```

---

## Usage

### Manual
```bash
./suarip.sh
```

### Automatic on disc insert (udev)

Create `/etc/udev/rules.d/99-suarip.rules` — replace `yourusername` in both places:

```
# Internal drive (sr0)
ACTION=="change", KERNEL=="sr0", ENV{ID_CDROM_MEDIA_DVD}=="1", \
RUN+="/bin/su yourusername -c '/home/yourusername/suarip.sh'"

# USB/external drive (sr1) - also catches Blu-ray
ACTION=="change", KERNEL=="sr1", ENV{ID_CDROM_MEDIA}=="1", \
RUN+="/bin/su yourusername -c '/home/yourusername/suarip.sh'"
```

Reload udev rules:
```bash
sudo udevadm control --reload-rules
```

### Monitoring a running rip (SSH)
```bash
tail -f ~/.local/share/suarip/suarip_*.log
```

### Running headless (survives SSH disconnect)
```bash
tmux new -s rip
./suarip.sh
# Detach: Ctrl+B D
# Reattach: tmux attach -t rip
```

---

## Configuration Reference

| Setting | Default | Description |
|---------|---------|-------------|
| `INTERNAL_DRIVE` | `/dev/sr0` | Internal optical drive device |
| `USB_DRIVE` | `/dev/sr1` | USB/external drive (empty to disable) |
| `TEMP_DIR` | `/mnt/scratch/suarip_temp` | Scratch directory for temp files |
| `OUTPUT_DIR` | `~/Videos/Movies` | Local output directory |
| `NAS_DIR` | *(empty)* | NAS path — leave empty to skip |
| `OMDB_API_KEY` | *(your key)* | OMDB API key for metadata |
| `DVD_PRESET` | `HQ 720p30 Surround` | HandBrake preset for DVDs |
| `BLURAY_PRESET` | `HQ 1080p30 Surround` | HandBrake preset for Blu-ray |
| `RF_QUALITY` | `19` | RF quality (18-22 recommended, lower=better) |
| `NOTIFY` | `true` | Desktop notifications |
| `AUTO_EJECT` | `true` | Eject disc when done |
| `CONFIRM_METADATA` | `false` | Prompt to confirm/correct movie title |
| `MIN_TITLE_SECONDS` | `3600` | MakeMKV minimum title length (filters extras) |
| `MAKEMKV_TIMEOUT` | `1800` | MakeMKV timeout in seconds (30 min) |
| `DDRESCUE_RETRIES` | `3` | Bad sector retries for ddrescue |

---

## How It Works

### Drive routing
The script routes differently based on which drive has the disc:

```
Disc inserted
     │
     ├─ Blu-ray? ──────────────────► MakeMKV → HandBrake
     │
     ├─ DVD in USB drive? ──────────► MakeMKV → HandBrake
     │
     └─ DVD in internal drive? ──┬──► ddrescue → ISO → HandBrake
                                 └──► dvdbackup (fallback) → HandBrake
```

This routing exists because some internal drives have SCSI command compatibility issues with MakeMKV (see Drive Compatibility below) while USB drives tend to work fine with it.

### Metadata lookup
The script tries up to 5 progressively simpler OMDB searches before giving up:
1. Cleaned disc label + year hint (if year found in label)
2. Cleaned disc label, no year
3. Label with edition words stripped (Director's Cut, Special Edition, etc.)
4. First 3 words of label
5. First 2 words of label

On failure with `CONFIRM_METADATA=false` it uses the cleaned disc label title-cased. All attempted searches are logged for debugging.

---

## Drive Compatibility Notes

Hard-won knowledge from real-world testing:

**Internal drives and MakeMKV:** Some older internal drives have compatibility issues with MakeMKV's SCSI generic (`sg`) interface and will hang silently without ripping anything. If MakeMKV hangs on `info disc:0` but `dvdbackup` works fine, this is the issue. The script automatically routes internal drives through `ddrescue` to avoid this.

**Known problematic drives with MakeMKV:**
- HL-DT-ST DVD+-RW GH50N (firmware B103) — hangs at SDF lookup stage

**USB drives and dvdbackup:** USB optical drives tend to have poor compatibility with `dvdbackup` and `libdvdread`. If you get read errors or empty output with dvdbackup on a USB drive, use MakeMKV instead (which works well with USB).

**The general rule:** internal drives → ddrescue/dvdbackup, USB drives → MakeMKV.

**libdvdcss:** Make sure it's installed and up to date. An outdated libdvdcss will fail silently on some discs. On Arch-based systems run `sudo pacman -S libdvdcss` to ensure you have the latest version.

**sg module:** MakeMKV requires the SCSI generic kernel module. Verify it's loaded with `lsmod | grep sg`. If not: `sudo modprobe sg`. To make it persist across reboots: `echo "sg" | sudo tee /etc/modules-load.d/sg.conf`

---

## Tested Hardware

| Machine | CPU | OS | Notes |
|---------|-----|----|-------|
| Custom build | AMD Ryzen 5 5600G | Nobara Linux | Full pipeline works, ~154fps transcode |
| Mac Mini 5,1 | Intel Core i5-2520M | Ubuntu (Snaps) | Works, ~25fps transcode |
| Custom AM1 build | AMD Athlon 5350 | Endeavour OS | Works with ddrescue, ~25fps transcode |

---

## Troubleshooting

**MakeMKV hangs silently on disc scan:**
- Check `sg` module is loaded: `lsmod | grep sg`
- Try `makemkvcon f -l` to see if the drive is detected
- Try with explicit device path: `makemkvcon -r info dev:/dev/sr0`
- If internal drive, use ddrescue instead (see Drive Compatibility above)

**disc label not found / OMDB returns wrong movie:**
- Check what the script logged for its search attempts
- Set `CONFIRM_METADATA=true` to manually correct titles
- Rename the output file manually and re-add to Jellyfin/Plex

**HandBrake error 3:**
- Try pointing at VIDEO_TS folder directly instead of ISO: `-i /path/VIDEO_TS`
- Check the full log for the actual error
- Verify the source file is valid: `ffprobe /path/to/source`

**Permission denied on temp directory:**
- Check ownership: `ls -la /mnt/scratch`
- Fix: `sudo chown $USER:$USER /mnt/scratch`

**Multiple MakeMKV processes running:**
- Kill them: `sudo killall makemkvcon`
- The lock file prevents this in normal operation but manual runs can stack up

**NAS copy fails:**
- Verify the share is mounted: `mountpoint /mnt/nas`
- Check credentials file permissions: `chmod 600 ~/.nascredentials`
- The script saves locally and warns if NAS is unavailable

---

## Roadmap

- [ ] Hardware encoding support (VAAPI/VCE) for faster transcodes
- [ ] Progress notifications at percentage milestones
- [ ] TV show / multi-disc set support
- [ ] Multiple drive queue support
- [ ] Webhook notifications (Discord, Gotify, etc.)

---

## Why Not ARM?

[Automatic Ripping Machine](https://github.com/automatic-ripping-machine/automatic-ripping-machine) is a great project but can be complex to set up and maintain, especially on non-standard hardware or distros. This script is a single bash file with no Docker, no web UI, no database — just insert disc, get MKV.

---

## Changelog

### v1.0-beta
- Initial release
- Dual drive routing — internal drives use ddrescue, USB/external use MakeMKV
- Multi-strategy OMDB metadata lookup (5 progressively simpler search attempts)
- ddrescue → dvdbackup automatic fallback
- Lock file prevents multiple simultaneous instances
- MakeMKV timeout prevents indefinite hangs
- NAS copy with mount detection and local fallback
- Sleep inhibition via systemd-inhibit
- Desktop notifications on each pipeline stage
- Fully headless/unattended operation with `CONFIRM_METADATA=false`
- udev auto-trigger support for disc insert automation
- Tested on Nobara, Ubuntu, and Endeavour OS

---

## License

MIT
