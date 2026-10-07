# StemDrop — Technical Spec (MVP)

Source brief: `12.0/StemDrop_One_Step_Mac_Stem_Extractor.md` (product intent, all versions).
This file turns that brief into build decisions. Where the brief says "possible" or
"ideally", this file picks one answer. Written 2026-09-18.

Machine it is built on: Apple M1 Ultra, macOS 15 (Darwin 24.6), Xcode 26.3, Swift 6.2,
Python 3.13 + `uv` available. ffmpeg exists on this Mac via Homebrew but the shipped app
must NOT depend on it.

---

## 1. Scope — MVP only

In: native SwiftUI Mac app · drag-and-drop (single + batch) · six stem checkboxes ·
fully local separation · WAV 24-bit export · same-folder output · remembered selection ·
per-job progress + queue · auto filenames with conflict numbering · reveal in Finder.

Out (unchanged from brief): everything under "Do Not Include Yet", plus MP3/M4A/FLAC
export, presets, Finder Quick Actions, Dock drop, menu bar mode, quality modes, watch
folder, Shortcuts. Those are v1.1/v1.2 and are not designed here beyond leaving hooks.

## 2. Key decisions

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| D1 | Separation model | **Demucs `htdemucs_ft` by default** (quality-first, revised 2026-09-19 §14); `htdemucs_6s` only when Guitar or Piano is selected | `htdemucs_ft` measures clearly better on vocals/drums/bass/other; `htdemucs_6s` is the only model with guitar/piano, so it is the automatic fallback. Both are free/open weights. |
| D2 | Runtime for MVP | **Bundled Python sidecar** (python-build-standalone + torch MPS + demucs) inside `StemDrop.app/Contents/Resources/engine/` | Meets "no Terminal / no Python / no Homebrew" for the *user* — they never see Python. MLX/Core ML port is a later swap behind the same `StemSeparator` protocol (see §5). Do not block MVP on an MLX port; verify one exists in Phase 0 and only adopt it if it runs `htdemucs_6s` unmodified. |
| D3 | Swift ↔ engine IPC | Spawn `engine/bin/python3 -m stemdrop_engine` via `Process`; **JSON lines on stdout** for progress/results, stderr captured to log | Simplest thing that gives real progress bars. No sockets, no XPC for MVP. |
| D4 | Model weights | Downloaded on **first launch** into `~/Library/Application Support/StemDrop/models/`, with a checksum, then never needs internet again | Keeps the .app small; brief allows "no internet *after* model installation". |
| D5 | Input decoding | **AVFoundation** (`AVAudioFile`) → 44.1 kHz stereo float WAV in a temp dir | Handles WAV/MP3/M4A/AAC/AIFF natively, no ffmpeg. FLAC: macOS 11+ decodes via AVFoundation — verify in Phase 0; if it fails, FLAC moves to v1.1. |
| D6 | Output encoding | **AVAudioFile** writing WAV, int24 default (int16 / float32 selectable in Settings) | Native, no third-party encoder. MP3 needs a bundled LAME → v1.1. |
| D7 | Project layout | **SwiftPM executable target** + `Scripts/bundle.sh` that assembles `StemDrop.app` (Info.plist, icon, engine dir) | No `.xcodeproj` to hand-edit; every agent can build with `swift build` from the CLI. Xcode can still open the package. |
| D8 | Concurrency | One separation job at a time (queue is serial); decoding/encoding of the *next* job may overlap | Demucs already saturates the GPU; parallel jobs just thrash memory. |
| D9 | Preferences | `UserDefaults` via `@AppStorage`, keys listed in §7 | MVP needs ~8 keys; no need for a settings file. |
| D10 | Sandbox | **App Sandbox OFF** (revised 2026-09-19 after R1). Entitlements file keeps only what Developer ID signing needs. | A dropped URL grants access to the file only, not its folder — sandboxed same-folder output would need a per-folder permission dialog, which breaks the no-dialog promise. Notarisation does not require the sandbox. Revisit only for a Mac App Store build. |
| D11 | Min macOS | 14.0 (Sonoma) | SwiftUI features + Apple Silicon only. Intel Macs are not a target. |

## 3. Processing pipeline (concrete)

```
drop URLs
 → AudioImporter.validate(url)          reject non-audio, >2 GB, unreadable
 → JobQueue.enqueue(AudioJob)           status .queued
 → AudioConverter.toEngineWAV(url)      AVAudioFile → tmp/<uuid>/input.wav (44.1k, 2ch, f32)
 → PythonEngineRunner.separate(...)     Process; reads JSON-lines progress 0…1
      writes tmp/<uuid>/stems/{vocals,drums,bass,guitar,piano,other}.wav (only requested)
 → AudioExporter.write(stem, format)    tmp stem → final URL, chosen bit depth
 → FileNaming.resolve(base, stem)       "Song - Drums.wav", "Song - Drums 2.wav", …
 → TemporaryFiles.cleanup(jobID)
 → NSWorkspace.activateFileViewerSelecting(outputs) if pref enabled
```

Engine JSON-lines protocol (stdout, one object per line):

```
{"event":"loading"}                                   model load started
{"event":"progress","fraction":0.42}                   0…1 over the whole file
{"event":"stem","name":"drums","path":"…/drums.wav"}   emitted per finished stem
{"event":"done"}
{"event":"error","message":"human-readable text"}
```

Engine CLI: `python3 -m stemdrop_engine --input <wav> --out <dir> --stems drums,vocals --model htdemucs_6s --device mps`

## 4. Error surface (user-facing strings — fixed, tested)

| Condition | Message |
|-----------|---------|
| Not audio / decode fails | `Could not read this audio file.` |
| Engine exits non-zero | `Stem separation failed.\nTry converting the song to WAV or M4A.` |
| < 3× input size free in tmp volume | `Not enough free disk space.` |
| Model download fails | `Could not download the separation model. Check your connection and try again.` |
| Output folder not writable | `Can't save next to the original file. Choose a different output folder.` |

Full stderr goes to `~/Library/Logs/StemDrop/engine.log`, never to the UI.

## 5. Module contracts (the interfaces agents code against)

```swift
enum StemType: String, CaseIterable, Codable { case instrumental, vocals, drums, bass, guitar, piano, other,
                                               kick, snare, cymbals }  // instrumental = all non-vocal stems summed

struct AudioJob: Identifiable { let id: UUID; let sourceURL: URL; let stems: Set<StemType>
                                var status: JobStatus; var progress: Double; var outputs: [URL] }
enum JobStatus { case queued, converting, separating, exporting, done, failed(String) }

protocol StemSeparator: Sendable {                               // D2: swap engine here later
    func separate(inputWAV: URL, stems: Set<StemType>, workDir: URL,
                  progress: @escaping (Double) -> Void) async throws -> [StemType: URL]
}
final class PythonEngineRunner: StemSeparator { … }    // MVP implementation

protocol AudioConverting { func toEngineWAV(_ src: URL, into dir: URL) async throws -> URL }
protocol AudioExporting  { func write(stemWAV: URL, to dst: URL, settings: ExportSettings) throws }
struct ExportSettings { var format: OutputFormat = .wav; var bitDepth: WAVBitDepth = .int24 }

enum FileNaming { static func outputURL(source: URL, stem: StemType, style: NamingStyle,
                                        conflict: ConflictPolicy) -> URL }
```

File tree is the one in the brief's "Architecture" section, with `MLXRunner.swift`
replaced by `PythonEngineRunner.swift` for MVP, plus:

```
STEMDROP/
├── Package.swift
├── Sources/StemDrop/…            (brief's App/ Models/ UI/ Audio/ Separation/ Utilities/)
├── Engine/                       Python package `stemdrop_engine` + pyproject (uv)
│   ├── stemdrop_engine/__main__.py
│   └── build_engine.sh           builds the relocatable runtime into Resources/engine/
├── Scripts/bundle.sh             swift build → StemDrop.app
├── Resources/Info.plist, AppIcon.icns, StemDrop.entitlements
├── Tests/StemDropTests/          FileNaming, JSON-lines parser, AudioConverter
└── DEV LOG/DEV_LOG.md
```

## 6. UI (MVP)

Main window exactly as the brief's mock: title, six checkboxes (persisted), drop zone,
Output row (read-only "Same folder" for MVP, `Change` disabled), Format popup (WAV only,
bit-depth sub-choice). Below the drop zone a job list appears only when non-empty:
filename · stems · progress bar · status text · ✓/✗. Per [[ui-rule-1-borders-on-everything]],
every element gets a visible border. Zero stems checked → drop zone dims and reads
"Select at least one stem". Settings window: only the GENERAL block from the brief plus
bit depth; PROCESSING and FINDER blocks come with v1.1/1.2.

## 7. Preference keys

`selectedStems:[String]` (default `["drums"]`) · `outputFormat` (`wav`) · `wavBitDepth`
(`int24`) · `namingStyle` (`dash` | `bracket`) · `conflictPolicy` (`number` | `replace` |
`ask`) · `revealInFinder` (true) · `playSound` (true) · `deleteTempImmediately` (true) ·
`modelInstalled` (false) · **`preserveOriginalLength` (true)** · **`normalizeOutput` (false)** ·
**`trimTrailingSilence` (false)**.

Daniel 2026-09-19: stems must come out untouched — exact original duration (pad with digital
silence if the decoded/separated audio is shorter, e.g. MP3 decoder padding; trim only if longer),
no normalisation, no gain change, no silence trimming. The three keys above exist so the
behaviour is explicit and visible in Settings under "Audio", all defaulting to untouched.

## 8. Definition of done (MVP)

1. `Scripts/bundle.sh` produces `StemDrop.app` that launches on a clean user account with
   no Python, no Homebrew.
2. Drop three MP3s with Drums ✓ → three `… - Drums.wav` files appear beside the sources,
   progress visible per job, no dialogs.
3. Drop a WAV with Vocals ✓ + Drums ✓ → two files. Dropping it again → `… 2.wav` versions.
4. Drop a `.txt` → "Could not read this audio file." and nothing else changes.
5. `swift test` green for FileNaming, JSON-lines parser, converter.
6. Separation of a 4-minute song completes on the M1 Ultra in under 90 s on MPS
   (target, not a gate — record the real number in the DEV LOG).

## 9. Open verifications (Phase 0 — must be answered before any UI code is written)

- V1  Does `demucs` + torch install and run `htdemucs_6s` on MPS under Python 3.12
       from python-build-standalone? (3.13 + torch MPS may lag; use 3.12.)
- V2  Size of the relocatable engine dir. If > 1.5 GB, strip torch (CPU-only wheels
       are not smaller on macOS; try `torch` without `torchvision`/`torchaudio` extras).
- V3  Does AVFoundation decode FLAC on macOS 14/15? (D5)
- V4  Is there a maintained MLX Demucs that loads `htdemucs_6s`? If yes, note it for v1.2;
       do not adopt now.

## 10. Phase 0 results (2026-09-18) — D2 confirmed

V1 ✓ htdemucs_6s on MPS, 30-s clip 21.9 s cold / 5.0 s warm; api keys `drums,bass,other,vocals,guitar,piano`.
V1c ✓ python-build-standalone 3.12 relocatable runtime works. **numpy must be pinned explicitly** (uv did not pull it).
V2 pbs engine dir 840 MB (torch 542 MB). Ship it; slimming is v1.2 work.
V3 ✓ AVFoundation decodes FLAC and MP3 — FLAC stays in MVP.
V4 `lextoumbourou/mlx-demucs` supports htdemucs_6s → candidate for v1.2 behind `StemSeparator`.
Model cache: HF hub `models--adefossez--HTDemucs-6s`, 54.9 MB. ModelManager sets `HF_HOME` to `~/Library/Application Support/StemDrop/models` so weights live there, not in `~/.cache`.

## 11. Real test file (Daniel, 2026-09-19)
A 6:38, 48 kHz stereo MP3, 13.4 MB, held on an external volume (path kept local). Extract **Drums** only. Output goes beside it on the external volume. Use for the §8 end-to-end run and the timing number.
First real run 2026-09-19 (engine CLI, not the app): drums only, 26.5 s wall including first model download; output 24-bit WAV verified non-silent (peak −0.1 dB). §8.6 target met.

## 12. Metadata + default format change (Daniel, 2026-09-19)

Tested on this Mac: Finder/Spotlight shows Artist + Title for WAV but **never Album** for WAV
(INFO chunk, ID3-in-WAV and CoreAudio info dictionary all tried; the importer ignores it).
AIFF (ID3), FLAC and ALAC all show Artist + Album. Therefore:

- **D6 revised: default output = AIFF, 24-bit** (lossless PCM, same quality/size as WAV).
  `OutputFormat` gains `.aiff` (default) and keeps `.wav`. Bit-depth choices apply to both.
- Every exported stem is tagged: **Artist** = source file's artist tag (fallback: source's
  album-artist; if neither, leave blank — never invent), **Album** = `ISOLATED TRACKS` (fixed),
  **Title** = `<source title or base filename> - <Stem>`, **Year** = source year if present.
  Preference key `albumTag` (default `ISOLATED TRACKS`) so it can be changed in Settings.
- WAV output still gets Artist/Title tags; Settings shows a caption next to WAV:
  "Finder can't display Album for WAV files."
- Implementation: read source tags with `AVAsset.load(.commonMetadata)` (artist/title/album/
  creationDate). Write AIFF via AVAudioFile (int16/int24/float32 big-endian PCM), then append
  an ID3v2.3 chunk (`ID3 ` chunk in AIFF) containing TPE1/TALB/TIT2/TYER — small hand-rolled
  ID3 writer (~80 lines), no third-party lib. For WAV append a `LIST/INFO` chunk with IART/INAM.
  Verify with `mdimport -t -d2 <file> | grep kMDItemAlbum`.

## 13. Daniel additions (2026-09-19, second batch)

- **Format dropdown = WAV / AIFF / MP3** (default AIFF). MP3 is encoded by the Python engine
  (`lameenc` wheel, 320 kbps CBR, joint stereo) via `python3 -m stemdrop_engine.encode_mp3
  --input <wav> --output <mp3> --bitrate 320`; JSON-lines `{"event":"done"}` / error like the
  separator. Swift side: `AudioExporter` writes a float32 WAV to temp, engine encodes, then
  `TagWriter` prepends an ID3v2.3 tag (TPE1/TALB/TIT2/TYER). D6 stands for WAV/AIFF.
- **Sound effects**: `NSSound(named: "Tink")` when a job's separation starts,
  `NSSound(named: "Glass")` when its exports finish. Pref `playSound` gates both.
- **Output location = `<outputRoot>/<Song base name> STEM SPLIT/`**, created per job.
  `outputRoot` default = `~/Documents/Adobe/Premiere Pro/12.0` when that folder exists,
  otherwise `~/Music/StemDrop`, which is created on first launch
  (pref key `outputRootPath`; falls back to the source's folder if the path no longer exists).
  Conflict numbering applies to files inside that folder. "Same folder as source" is no longer
  the default; it remains selectable in Settings as an option (`outputMode`: `root` | `sameFolder`).
- **Main window gets an output-folder row** under the format dropdown and stem checkboxes:
  `Output folder: <abbreviated path>   [Change…]` — `Change…` opens `NSOpenPanel`
  (directories only) and stores the choice in `outputRootPath`.

## 14. Quality-first model selection (Daniel, 2026-09-19)

Daniel: "i only care about quality." Free/open weights only — no paid service.

- Engine `--model auto` (the new default, passed by `PythonEngineRunner`):
  - requested stems ⊆ {vocals, drums, bass, other} → **`htdemucs_ft`** (bag of four
    per-stem fine-tunes; measured SDR ≈ drums 10.11 / bass 9.7 / vocals 9.19 / other 7.0 dB).
  - guitar or piano requested → **`htdemucs_6s`** (only model that produces those;
    SDR ≈ 9.5 / 9.0 / 8.5 / 5.5 dB). This is an automatic, invisible fallback.
- Cost: `htdemucs_ft` is a 4-model bag, ~3.5× slower. Measured on the M1 Ultra with the
  §11 test song (6:38): **91 s** for Drums (vs ~26 s on `htdemucs_6s`). Model download
  grew from ~55 MB to ~390 MB total (both models pre-fetched).
- `download_model.py` now pre-fetches **both** models. New pref key `modelRevision`
  (current = 2); `ModelManager.ensureInstalled` re-downloads when the stored revision is
  lower, so existing installs pick up `htdemucs_ft` automatically.
- Progress: a bag emits per-model fractions that reset to 0 four times. `__main__.py`
  spreads progress across the bag so the bar is monotonic 0→1.
- Dropping to 6-stem quality can be forced later via `--model htdemucs_6s`; not exposed in UI.

## 15. Vocal Cleanup — second pass (Daniel, 2026-09-20)

Second tab ("Vocal Cleanup", segmented picker at the top of the window). Input is an
**already-separated vocal stem**; output is one file, `<Song> - Vocals CLEAN.<ext>`.

- Engine: `python3 -m stemdrop_engine.cleanup --input <wav> --out <dir>
  --reseparate {0,1,2} --gate {0,1} --gate-threshold 0.5 --denoise 0.0–1.0 --device mps`.
  Emits the **same JSON-lines protocol** as §3 (`stem` event uses name `vocals`), so
  `PythonEngineRunner` reuses its collector; the Swift side only builds a different argv.
- Three stages, each toggleable in the UI, run in this order:
  1. **Re-separation** (1 or 2 passes) — the stem goes back through Demucs, keep `vocals`.
     Uses only the vocals sub-model of the `htdemucs_ft` bag: the bag's weights are the
     identity matrix, so this is bit-identical to the full bag at ~¼ the time. No new
     model download; `modelRevision` unchanged.
  2. **Voice gate** — Silero VAD (`stemdrop_engine/data/silero_vad.jit`, MIT, 2.3 MB,
     vendored inside the package — no pip dependency, no download). Voiced frames widened
     by 150 ms both sides, 40 ms linear fades, gaps go to silence. Threshold slider
     0.1–0.9. **If no frame is voiced the gate is skipped** and logged to stderr, so an
     instrumental or a bad threshold can't silence the whole file.
  3. **Spectral denoise** — in-house soft spectral gate (torch STFT 2048/512): per-bin
     noise floor = 20th percentile over frames the gate left open; bins ≤ +3 dB above
     floor are attenuated by `amount`, ≥ +9 dB untouched, mask smoothed 5×3. No
     `noisereduce`/`scipy` dependency. Amount slider 0.1–1.0, default 0.5.
- Progress shares: re-separation 0.80 / gate 0.12 / denoise 0.08, renormalized over the
  enabled stages; monotonic 0→1.
- Output length == input length always (§7); written float32 with `clip="none"` (never
  rescaled); `normalize` is forced off for cleanup exports regardless of prefs.
- Location rule: if the stem sits in a `… STEM SPLIT` folder, the clean file goes **next to
  it**. Otherwise the normal §13 rules apply, with the song name derived by stripping the
  trailing ` - Vocals` / ` [Vocals]` (`FileNaming.songBaseName`).
- Tests: `Engine/tests/test_cleanup.py` (pytest; speech via macOS `say`, gate/denoise
  assertions in dB, CLI protocol check) and Swift `CleanupSettingsTests` + additions to
  `FileNamingTests`, `OutputLocationTests`, `JobQueueTests`.
- Measured: full three-stage run on a 5.8 s clip = 10.7 s including model load (M1 Ultra).
