# STEM DROP PLUS 2 — DEV LOG

---

APP: STEM DROP PLUS 2
STATE: green
MOMENTUM: shipped
KEYWORDS: public release, GitHub, gatekeeper, instrumental stem, progress bug, non-technical install
AGENT: Claude Opus 5 (Claude Code)
HEADLINE: Repo made public, v0.1.0 release published with a signed-adhoc build and a plain-English install page for Daniel's brother.
NEXT: Get a Developer ID so builds can be notarized and the Gatekeeper detour disappears.
DATE: 2026-10-06, ~8:00 PM Chicago

## WHAT CHANGED

Daniel's brother reported the app "doesn't work" with no detail. The ask was to
make the repo public and produce a link a non-coder could actually use.

Privacy scan first, since going public exposes history: 75 tracked files, all
within Sources/Tests/Engine/Resources/Scripts. No keys, tokens or credentials.
No audio or media ever committed. graphify-out/ confirmed untracked (it sits at
Sources/StemDrop/graphify-out/ and is caught by the .gitignore rule). Only
author identity in history is the GitHub noreply address, so no personal email
leaks. Two private-path mentions were generalized in SPEC.md §11 and §13.

Committed the pending Instrumental-stem work (derives the stem by summing all
non-vocal stems, matching Demucs' own no_vocals split, so no extra model pass).

Two real bugs found and fixed:

1. First-run output root was hardcoded to the Premiere 12.0 folder, which only
   exists on this machine. OutputLocation ignores a root that doesn't exist and
   silently writes beside the source instead, so Settings lied about the
   destination. Now resolves to the 12.0 folder when present, else creates and
   uses ~/Music/StemDrop. A folder the user already chose is never touched, so
   Daniel's own setup is unchanged.
2. Progress bar stalled. The model-boundary detector only ran inside the 0.5s
   emit throttle, so a reset occurring between emits was lost. On htdemucs_ft
   (bag of 4) the fraction stuck at 0.25 for the rest of the run — reads exactly
   like a hung job, and a plausible cause of the brother's report. Boundary
   tracking now runs on every callback; only the emit stays throttled. Also
   emit an explicit progress 1.0 once separation returns.

## TRIED-FAILED

- Verifying stem content via Python `wave` failed: engine writes float32 WAV
  (format tag 3). soundfile isn't in the bundle, and torchaudio.load now needs
  torchcodec, which isn't either. Settled on a hand-rolled RIFF parser.
- First reconstruction assertion (mix == vocals + instrumental, tol 0.02)
  failed at 0.34 max error. The test was wrong, not the code: htdemucs_ft isn't
  perfect-reconstruction and the synthetic input was hard-clipped. Re-checked
  by correlation instead.

## DECISIONS

- MIT license, since Demucs and Silero VAD are both MIT. Changeable.
- Shipped ad-hoc signed and not notarized — no Developer ID cert on this Mac
  (`security find-identity` returns 0 valid identities). Handled with explicit
  Open Anyway instructions rather than hiding it.
- Delivery is a GitHub Release asset plus a published install page, not a bare
  repo link, because a repo link is useless to a non-developer.

## VERIFICATION

- swift build clean; 51 Swift tests pass; 15 engine pytest tests pass.
- End-to-end on a 6s synthetic stereo file through the BUNDLED engine inside the
  zipped app: vocals peak -62.97 dBFS (correctly near-silent, 0.0000% of mix
  energy), instrumental peak -0.10 dBFS, correlation with the vocal-free mix
  0.9889, zero samples at full scale.
- Progress after fix: 0.0 -> 0.24375 -> 0.25 -> 0.5 -> 0.75 -> 1.0 -> done.
- Signature survives the ditto round-trip (`codesign --verify --deep --strict`).
- Anonymous, unauthenticated curl: repo 200, release asset 200, first bytes PK..

## NEXT UP

1. Developer ID + notarization. Removes steps 3-4 of the install entirely.
2. Wait for the brother's actual error before assuming it's fixed — the two
   bugs found are plausible causes, not confirmed ones.
3. Info.plist still says CFBundleShortVersionString 0.1.0 while the repo tag is
   v0.1.0 — aligned now, keep them in sync on the next build.

## PENDING ISSUES TO TACKLE

- Swift 6 concurrency warnings in AudioConverter (`mutation of captured var
  'reachedEndOfFile'`) — currently a warning, an error under Swift 6 mode.
- Instrumental is a plain sum of stems; on a dense mix it could exceed full
  scale. No clipping in the synthetic test, but worth a peak check on real music.

## BLOCKERS

- Cannot notarize. Needs Daniel's Apple Developer account; Claude can't sign.
