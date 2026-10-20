<p align="center"><img src="docs/icon.png" width="128" alt="Dial icon"></p>

<h1 align="center">Dial</h1>

<p align="center">A radial menu for your files on macOS. Select a file, tap a key, and convert, edit or share it from a wheel that opens right on top of it.</p>

---

## Install

**One line** (Terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/Sskskxi/dial/main/install.sh | bash
```

This downloads the latest release into `/Applications`, installs `ffmpeg` and `webp` with Homebrew if you have it, and starts Dial.

**Or by hand:**

1. Download **[Dial.zip](https://github.com/Sskskxi/dial/releases/latest/download/Dial.zip)** and unzip it.
2. Drag **Dial.app** into **Applications**.
3. Dial isn't notarized by Apple, so the first time, **right-click Dial.app → Open → Open**.
   (Or go to **System Settings → Privacy & Security** and click **Open Anyway**.)
4. For video, audio and WebP: `brew install ffmpeg webp`

**Requirements:** macOS 15.4 or later, Apple silicon (M1 or later).

## Use

Select files in Finder, then **tap** a key on its own:

| Tap | Wheel |
|---|---|
| ⇧ Shift | **Convert** to another format |
| ⌥⇧ Option + Shift | **Tools** for that kind of file |
| ⌘ Command | **Actions**: AirDrop, Float, Copy, Copy To, Move To, Copy Path, Terminal |
| ⌥ Option | **File menu**: Open, Open With, Quick Look, Get Info, Rename, Duplicate, Copy, Trash |

Click an item to run it, or tap again / press Esc to close. You can also hold ⇧, ⌥⇧ or ⌃ **while dragging** a file and drop it on the wheel.

Results are saved next to the original and revealed in Finder. Several files at once are processed as a batch.

## What it does

| Files | Convert to | Tools |
|---|---|---|
| **Images** (JPEG, PNG, HEIC, WebP, AVIF, TIFF, GIF, BMP, ICO, SVG) | JPEG, PNG, HEIC, WebP, AVIF, TIFF, GIF, BMP, ICO, PDF | Compress, compress to size or %, resize, rotate, flip, black & white, remove background, strip metadata, read QR code, combine into PDF, info |
| **Video** (MP4, MOV, MKV, WebM, AVI, …) | MP4, MOV, MKV, WebM, AVI, GIF, MP3, M4A | Compress, compress to size, trim, speed, snapshot, mute, half size, split, join, strip metadata, info |
| **Audio** (MP3, M4A, WAV, FLAC, OGG, Opus, AIFF) | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF | Compress, compress to size, trim, speed, normalize, mono, stereo, join, strip metadata, info |
| **PDF** | PNG, JPEG, TXT, DOCX, RTF | Compress, merge, split pages, rotate, strip metadata, info |
| **Documents** (DOCX, DOC, RTF, TXT, HTML, ODT, Markdown) | PDF, DOCX, TXT, RTF, HTML, ODT | |
| **Subtitles** | SRT, VTT, ASS | |
| **Archives** | Extract ZIP, TAR, GZ, RAR, 7z | |
| **Anything** | ZIP, TAR.GZ | |

Everything runs locally on your Mac. Nothing is uploaded.

Also in the menu bar menu: a **drop window**, a **floating shelf** for parking files, **launch at login**, and a choice of **menu bar icons** (or your own image).

## Permissions

macOS asks for these the first time they're needed:

- **Finder automation**: to read which files are selected.
- **Accessibility**: to open the wheel on the selected file instead of at the pointer. Optional.
- **Files and folders**: to save results in Desktop, Documents or Downloads.

## Build from source

```bash
git clone https://github.com/Sskskxi/dial.git
cd dial
./build.sh        # builds and installs ~/Applications/Dial.app
./package.sh      # builds build/Dial.zip for a release
```

Needs the Xcode command line tools (`xcode-select --install`).

## Troubleshooting

Dial writes a short log to `~/Library/Logs/Dial.log`. If the wheel doesn't open, check it and make sure Dial is allowed under **System Settings → Privacy & Security → Automation** and **Accessibility**. After updating Dial you may need to switch Accessibility off and on again for it.

## License

[MIT](LICENSE)
