# StemDrop Plus 2

A Mac app that splits a song into separate audio tracks — vocals, drums, bass,
guitar, piano, and more. Drag a song in, tick the parts you want, and the WAVs
land in a folder next to it. Everything runs on your own machine; nothing is
uploaded.

**Just want to use it?** → [Download and setup instructions](#install)

---

## What it does

- Drag and drop one song or a whole batch
- Stems: **Instrumental** (the track with vocals removed), Vocals, Drums, Bass,
  Guitar, Piano, Other, plus Kick / Snare / Cymbals isolated out of the drums
- Vocal Cleanup pass with an adjustable gate, for bleed in the vocal stem
- A mix workspace with waveforms, for balancing stems and bouncing a new mix
- 24-bit WAV out by default (16-bit, 32-bit float, and MP3 also available)
- Reads WAV, MP3, M4A/AAC, AIFF, and FLAC
- Fully offline after the one-time model download

Separation uses [Demucs](https://github.com/adefossez/demucs) (`htdemucs_ft`,
switching to `htdemucs_6s` when Guitar or Piano is requested). Vocal activity
detection uses [Silero VAD](https://github.com/snakers4/silero-vad).

## Requirements

- A Mac with **Apple Silicon** (M1 or newer) — Intel Macs are not supported
- **macOS 14 Sonoma** or newer
- About 1 GB of disk space, plus an internet connection on first launch to
  fetch the separation model (~55 MB, once)

## Install

The app is not notarized by Apple, so macOS will refuse to open it the first
time. That is expected and it takes two extra clicks to get past:

1. Download the `.zip` from the [latest release](../../releases/latest) and
   double-click it to unzip.
2. Drag **StemDrop Plus 2** into your **Applications** folder.
3. Double-click it. macOS will say it cannot verify the developer — click
   **Done**.
4. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to the StemDrop message. Confirm with **Open Anyway**
   again and enter your Mac password.

You only do steps 3–4 once. After that it opens normally.

On first launch it downloads the separation model, which takes a minute. Then
drop in a song.

### Where the files go

Stems are written to `~/Music/StemDrop/<Song name> STEM SPLIT/`. You can
change that in the app's Settings, or switch it to "same folder as the source
song".

## Building from source

Requires Xcode 26 or newer and Python 3.13 with [`uv`](https://docs.astral.sh/uv/).

```sh
./Engine/build_engine.sh     # builds the bundled Python sidecar (slow, once)
./Scripts/bundle.sh          # produces "STEM DROP PLUS 2.app"
```

`swift build` and `swift test` work on their own for the Swift side, but the
app needs the engine bundled before separation will run.

Design decisions, the processing pipeline, and the Swift↔Python protocol are
documented in [SPEC.md](SPEC.md).

## License

[MIT](LICENSE). Demucs and Silero VAD are MIT-licensed; Silero's license is
included at `Engine/stemdrop_engine/data/SILERO_VAD_LICENSE`.
