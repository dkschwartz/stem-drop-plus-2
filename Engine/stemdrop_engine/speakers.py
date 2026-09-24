"""StemDrop "Male / Female" voice split engine CLI.

Takes an already-isolated vocal stem (any sample rate, mono or stereo) and
splits it into two stems — "male" and "female" — by pitch. There is no manual
speaker-labeling step: every voiced frame is classified male or female by its
fundamental frequency (f0) and routed into the matching file, with everything
else (silence, unvoiced noise) gated out of both.

Built for the common podcast/interview case: two speakers, one male and one
female, mostly talking at separate times. Known limits (inherent to having a
single vocal waveform):
  * Overlapping speech cannot be un-mixed — both voices bleed into both files.
  * Two same-gender voices both land in the same file.

Invoked as: python3 -m stemdrop_engine.speakers --input <vocals.wav> --out <dir>

Emits the same JSON-lines protocol as the separator/cleanup engines:
    {"event":"loading"}
    {"event":"progress","fraction":0.42}
    {"event":"stem","name":"male","path":"…/male.wav"}
    {"event":"stem","name":"female","path":"…/female.wav"}
    {"event":"done"}
    {"event":"error","message":"…"}

Nothing else may go to stdout. All diagnostics go to stderr. Output length
always equals input length (SPEC.md §7).
"""
import argparse
import json
import math
import os
import sys

# Same process/env setup as __main__.py and cleanup.py: own process group so
# the Swift side can SIGTERM the whole tree; HF_HOME under the app's model dir;
# no tqdm bars on stdout; MPS ops without a Metal kernel fall back to CPU.
os.setpgrp()

_model_dir = os.environ.get("STEMDROP_MODEL_DIR")
if _model_dir:
    os.environ["HF_HOME"] = _model_dir

os.environ.setdefault("TQDM_DISABLE", "1")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

from .cleanup import (  # noqa: E402
    gate_envelope,
    read_wav,
    vad_speech_probs,
    write_wav,
)

_ANALYSIS_SR = 16000        # Silero VAD's native rate
_CHUNK = 512                # Silero's fixed window at 16 kHz (32 ms)
_FMIN = 70.0                # lowest f0 we search for (Hz)
_FMAX = 350.0               # highest f0 we search for (Hz)
_GENDER_BOUNDARY = 165.0    # Hz, ~midpoint between adult male and female f0
_SPEECH_THRESHOLD = 0.5
_VOICED_PEAK = 0.25         # min normalized-autocorr peak to count a frame voiced
_PAD_MS = 100.0             # widen each speaker region this much (closes gaps)
_FADE_MS = 40.0             # edge smoothing so envelopes ramp instead of click


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _log(msg: str) -> None:
    sys.stderr.write(f"stemdrop_speakers: {msg}\n")
    sys.stderr.flush()


def _parse_args(argv):
    parser = argparse.ArgumentParser(prog="stemdrop_engine.speakers")
    parser.add_argument("--input", required=True)
    parser.add_argument("--out", required=True)
    return parser.parse_args(argv)


# ---------------------------------------------------------------------------
# Fundamental frequency estimation

def _f0_batch(frames):
    """Fundamental frequency per frame via normalized autocorrelation.

    `frames` is [B, L] float32 with the mean already removed. Returns [B]
    f0 in Hz, 0 where the frame is unvoiced (no strong periodic peak).
    """
    import torch

    B = frames.shape[0]
    L = frames.shape[-1]
    nfft = 1
    while nfft < 2 * L:
        nfft <<= 1

    lo = max(2, int(_ANALYSIS_SR / _FMAX))
    hi = min(L - 1, int(_ANALYSIS_SR / _FMIN))

    out = torch.zeros(B)
    for start in range(0, B, 4096):
        chunk = frames[start:start + 4096]
        spec = torch.fft.rfft(chunk, n=nfft)
        ac = torch.fft.irfft(spec * spec.conj(), n=nfft)          # autocorrelation
        norm = ac[:, :hi + 1] / ac[:, 0:1].clamp_min(1e-12)       # normalize to lag-0
        seg = norm[:, lo:hi + 1]
        peak = seg.argmax(dim=1) + lo
        peakval = norm[torch.arange(chunk.shape[0]), peak]
        f0 = _ANALYSIS_SR / peak.float()
        out[start:start + 4096] = torch.where(peakval > _VOICED_PEAK, f0, torch.zeros_like(f0))
    return out


def _two_centroids(vals, iters=20):
    """1-D 2-means on the (log) f0 values; returns (lower, higher)."""
    import torch

    if vals.numel() == 1:
        v = float(vals[0])
        return v, v
    lo = float(vals.min())
    hi = float(vals.max())
    c_lo = lo + 0.25 * (hi - lo)
    c_hi = lo + 0.75 * (hi - lo)
    for _ in range(iters):
        mid = (c_lo + c_hi) / 2.0
        mask_lo = vals <= mid
        if mask_lo.any():
            c_lo = float(vals[mask_lo].mean())
        if (~mask_lo).any():
            c_hi = float(vals[~mask_lo].mean())
    if c_lo > c_hi:
        c_lo, c_hi = c_hi, c_lo
    return c_lo, c_hi


# ---------------------------------------------------------------------------
# Split

def _analyze(wav, sample_rate):
    """Return (male_frames, female_frames): bool tensors over VAD frames."""
    import torch

    mono = wav.mean(dim=0).to("cpu")
    if sample_rate != _ANALYSIS_SR:
        import torchaudio.functional as F

        mono = F.resample(mono, sample_rate, _ANALYSIS_SR)

    probs = vad_speech_probs(wav, sample_rate)
    n_frames = probs.numel()

    # Cut the mono analysis signal into the same 32 ms frames the VAD used.
    n = mono.shape[-1]
    pad = (_CHUNK - n % _CHUNK) % _CHUNK
    if pad:
        mono = torch.nn.functional.pad(mono, (0, pad))
    frames = mono[: n_frames * _CHUNK].view(n_frames, _CHUNK)
    frames = frames - frames.mean(dim=1, keepdim=True)

    speech = probs >= _SPEECH_THRESHOLD
    speech_idx = torch.nonzero(speech, as_tuple=False).view(-1)

    f0 = torch.zeros(n_frames)
    if speech_idx.numel() > 0:
        f0[speech_idx] = _f0_batch(frames[speech_idx])

    voiced_idx = torch.nonzero(f0 > 0, as_tuple=False).view(-1)
    if voiced_idx.numel() == 0:
        return None, None

    voiced_f0 = f0[voiced_idx]
    logf = torch.log(voiced_f0)
    c_lo, c_hi = _two_centroids(logf)
    c_lo_hz = math.exp(c_lo)
    c_hi_hz = math.exp(c_hi)

    # Only split into male/female when the two pitch clusters genuinely sit on
    # opposite sides of the male/female divide. Two same-gender voices (or a
    # single speaker) keep the fixed boundary so they all route to one file.
    if c_lo_hz < _GENDER_BOUNDARY <= c_hi_hz:
        boundary = math.exp((c_lo + c_hi) / 2.0)
    else:
        boundary = _GENDER_BOUNDARY

    is_male = f0[voiced_idx] <= boundary
    male_mask = torch.zeros(n_frames, dtype=torch.bool)
    female_mask = torch.zeros(n_frames, dtype=torch.bool)
    male_mask[voiced_idx] = is_male
    female_mask[voiced_idx] = ~is_male

    pct_male = 100.0 * float(male_mask.float().mean()) if n_frames else 0.0
    pct_female = 100.0 * float(female_mask.float().mean()) if n_frames else 0.0
    _log(
        f"f0 clusters {c_lo_hz:.0f} / {c_hi_hz:.0f} Hz → boundary {boundary:.0f} Hz; "
        f"male {pct_male:.0f}% / female {pct_female:.0f}% of voiced frames"
    )
    return male_mask, female_mask


def main(argv=None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        import torch

        torch.set_grad_enabled(False)
        _emit({"event": "loading"})

        wav, sample_rate = read_wav(args.input)
        n_samples = wav.shape[-1]
        _log(f"input {wav.shape[0]}ch {n_samples} frames @ {sample_rate} Hz")

        _emit({"event": "progress", "fraction": 0.3})
        male_mask, female_mask = _analyze(wav, sample_rate)
        if male_mask is None:
            _emit({"event": "error", "message": "No voice detected in the audio."})
            return 1

        _emit({"event": "progress", "fraction": 0.7})

        env_male = gate_envelope(male_mask, n_samples, sample_rate, pad_ms=_PAD_MS, fade_ms=_FADE_MS)
        env_female = gate_envelope(female_mask, n_samples, sample_rate, pad_ms=_PAD_MS, fade_ms=_FADE_MS)

        male_wav = wav * env_male.unsqueeze(0)
        female_wav = wav * env_female.unsqueeze(0)

        _emit({"event": "progress", "fraction": 0.95})

        os.makedirs(args.out, exist_ok=True)
        male_path = os.path.join(args.out, "male.wav")
        female_path = os.path.join(args.out, "female.wav")
        write_wav(male_wav, male_path, sample_rate)
        write_wav(female_wav, female_path, sample_rate)

        _emit({"event": "stem", "name": "male", "path": male_path})
        _emit({"event": "stem", "name": "female", "path": female_path})
        _emit({"event": "done"})
        return 0
    except Exception as exc:  # noqa: BLE001
        _emit({"event": "error", "message": str(exc)})
        import traceback

        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
