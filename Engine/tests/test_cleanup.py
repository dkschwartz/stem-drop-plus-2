"""Engine tests for stemdrop_engine.cleanup (gate + denoise stages).

Re-separation is not exercised here: it needs the ~300 MB Demucs weights and
~30 s of compute; it is covered by the manual run in the DEV LOG instead.

Fixture: 2 s of leading "music residue" (quiet chord + hiss), then real
speech from macOS `say`, then 2 s more residue, with the same low-level
residue also mixed *under* the speech. Run with:

    cd Engine && ../Resources/engine/bin/python3 -m pytest tests -q
"""
import os
import subprocess
import sys

import numpy as np
import pytest
import torch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from stemdrop_engine import cleanup  # noqa: E402

SR = 44100
PY = sys.executable


def _speech(tmp_path) -> torch.Tensor:
    aiff = tmp_path / "speech.aiff"
    wav = tmp_path / "speech.wav"
    subprocess.run(["say", "-o", str(aiff), "Keep every word and drop the music between them."], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEF32@{SR}", "-c", "2", str(aiff), str(wav)], check=True)
    x, sr = cleanup.read_wav(str(wav))
    assert sr == SR
    return x


def _residue(n: int, level: float = 0.02) -> torch.Tensor:
    t = torch.arange(n) / SR
    chord = sum(torch.sin(2 * np.pi * f * t) for f in (220.0, 277.2, 329.6, 440.0)) / 4
    hiss = torch.randn(n) * 0.25
    mono = (chord + hiss) * level
    return torch.stack([mono, mono])


def _rms(x: torch.Tensor) -> float:
    return float(x.pow(2).mean().sqrt())


def _db(a: float, b: float) -> float:
    return 20 * np.log10((a + 1e-9) / (b + 1e-9))


@pytest.fixture(scope="module")
def fixture(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("cleanup")
    speech = _speech(tmp)
    gap = 2 * SR
    n = gap + speech.shape[-1] + gap
    mix = _residue(n)
    mix[:, gap:gap + speech.shape[-1]] += speech
    return {"mix": mix, "gap": gap, "speech_len": speech.shape[-1], "tmp": tmp}


def test_wav_roundtrip_preserves_length_and_content(fixture):
    path = str(fixture["tmp"] / "rt.wav")
    cleanup.write_wav(fixture["mix"], path, SR)
    back, sr = cleanup.read_wav(path)
    assert sr == SR
    assert back.shape == fixture["mix"].shape
    assert torch.allclose(back, fixture["mix"].clamp(-1, 1), atol=1e-6)


def test_gate_silences_gaps_and_keeps_speech(fixture):
    mix, gap, n_sp = fixture["mix"], fixture["gap"], fixture["speech_len"]
    gated, env = cleanup.apply_gate(mix, SR, threshold=0.5, pad_ms=150, fade_ms=40)

    assert gated.shape == mix.shape
    assert env.shape[-1] == mix.shape[-1]

    # First/last 1.5 s are pure residue and far from any speech → gated out.
    head, tail = gated[:, : int(1.5 * SR)], gated[:, -int(1.5 * SR):]
    assert _db(_rms(head), _rms(mix[:, : int(1.5 * SR)])) < -40
    assert _db(_rms(tail), _rms(mix[:, -int(1.5 * SR):])) < -40

    # Speech region keeps (nearly) all its energy.
    sp_in = mix[:, gap:gap + n_sp]
    sp_out = gated[:, gap:gap + n_sp]
    assert _db(_rms(sp_out), _rms(sp_in)) > -1.5


def test_gate_envelope_fades_not_steps():
    voiced = torch.tensor([False] * 20 + [True] * 20 + [False] * 20)
    env = cleanup.gate_envelope(voiced, n_samples=60 * 512, sample_rate=16000, pad_ms=0, fade_ms=40)
    # Largest per-sample jump must be small: a hard step would be 1.0.
    assert float(env.diff().abs().max()) < 0.01
    assert float(env.min()) == 0.0 and float(env.max()) > 0.99


def test_denoise_reduces_bed_more_than_speech(fixture):
    mix, gap, n_sp = fixture["mix"], fixture["gap"], fixture["speech_len"]
    out = cleanup.spectral_denoise(mix, amount=1.0)
    assert out.shape == mix.shape

    bed_in = mix[:, : int(1.5 * SR)]
    bed_out = out[:, : int(1.5 * SR)]
    sp_in = mix[:, gap:gap + n_sp]
    sp_out = out[:, gap:gap + n_sp]

    bed_drop = _db(_rms(bed_out), _rms(bed_in))
    speech_drop = _db(_rms(sp_out), _rms(sp_in))
    assert bed_drop < -6            # the steady bed is clearly attenuated
    assert speech_drop > -3         # speech is not
    assert bed_drop < speech_drop - 3


def test_denoise_amount_zero_is_near_identity(fixture):
    out = cleanup.spectral_denoise(fixture["mix"], amount=0.0)
    assert torch.allclose(out, fixture["mix"], atol=1e-4)


def test_cli_end_to_end_without_reseparation(fixture):
    tmp = fixture["tmp"]
    src = str(tmp / "in.wav")
    out_dir = str(tmp / "out")
    cleanup.write_wav(fixture["mix"], src, SR)

    proc = subprocess.run(
        [PY, "-m", "stemdrop_engine.cleanup", "--input", src, "--out", out_dir,
         "--reseparate", "0", "--gate", "1", "--denoise", "0.5", "--device", "cpu"],
        cwd=os.path.join(os.path.dirname(__file__), ".."),
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode == 0, proc.stderr
    events = [line for line in proc.stdout.splitlines() if line.strip()]
    import json

    parsed = [json.loads(e) for e in events]
    kinds = [p["event"] for p in parsed]
    assert kinds[0] == "loading" and kinds[-1] == "done"
    assert "stem" in kinds and "error" not in kinds
    fractions = [p["fraction"] for p in parsed if p["event"] == "progress"]
    assert fractions == sorted(fractions) and fractions[-1] == 1.0

    stem = next(p for p in parsed if p["event"] == "stem")
    assert stem["name"] == "vocals"
    result, sr = cleanup.read_wav(stem["path"])
    assert sr == SR
    assert result.shape == fixture["mix"].shape


def test_stage_weights_sum_to_one():
    for args in [(1, True, 0.5), (0, True, 0.5), (2, False, 0.0), (0, False, 0.3)]:
        w = cleanup._stage_weights(*args)
        assert abs(sum(x for _, x in w) - 1.0) < 1e-9
    assert cleanup._stage_weights(0, False, 0.0) == []


def test_gate_skips_when_nothing_is_voiced():
    # Pure low-level noise: no speech anywhere → gate must leave audio alone
    # rather than silence the entire file.
    noise = torch.randn(2, 3 * SR) * 0.01
    out, env = cleanup.apply_gate(noise, SR, threshold=0.5, pad_ms=150, fade_ms=40)
    assert env is None
    assert torch.equal(out, noise)


def test_voiced_frames_keeps_loud_sung_notes_vad_missed():
    # Frames 0-3: confident speech at -27 dB. Frames 4-5: sustained note the
    # VAD scored low but only 10 dB under the voice level → kept.
    # Frames 6-7: quiet residue 40 dB down with low VAD → gated.
    probs = torch.tensor([0.9, 0.9, 0.8, 0.7, 0.05, 0.1, 0.05, 0.02])
    levels = torch.tensor([-27.0, -28.0, -26.0, -27.0, -37.0, -36.0, -67.0, -70.0])
    voiced = cleanup.voiced_frames(probs, levels, threshold=0.5)
    assert voiced.tolist() == [True, True, True, True, True, True, False, False]


def test_voiced_frames_falls_back_to_vad_when_nothing_is_confident():
    probs = torch.tensor([0.3, 0.1, 0.35])
    levels = torch.tensor([-20.0, -20.0, -20.0])
    assert cleanup.voiced_frames(probs, levels, threshold=0.3).tolist() == [True, False, True]
