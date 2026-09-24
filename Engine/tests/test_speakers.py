"""Engine tests for stemdrop_engine.speakers (pitch-based male/female split).

Does NOT touch Demucs: the split runs on an already-isolated vocal waveform
and only needs Silero VAD + the autocorrelation f0 estimator, so it is cheap.

Fixture: a low male voice (macOS "Fred") and a high female voice
(macOS "Victoria"), concatenated with a silent gap. Run with:

    cd Engine && ../Resources/engine/bin/python3 -m pytest tests -q
"""
import os
import subprocess
import sys

import pytest
import torch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from stemdrop_engine import speakers  # noqa: E402
from stemdrop_engine.cleanup import read_wav, write_wav  # noqa: E402

SR = 44100


def _voice(tmp_path, voice: str, text: str) -> torch.Tensor:
    aiff = tmp_path / f"{voice}.aiff"
    wav = tmp_path / f"{voice}.wav"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", f"LEF32@{SR}", "-c", "2", str(aiff), str(wav)],
        check=True,
    )
    return read_wav(str(wav))[0]


def _rms(x, a, b):
    return float(x[:, a:b].pow(2).mean().sqrt())


@pytest.fixture(scope="module")
def fixture(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("speakers")
    male = _voice(tmp, "Fred", "Hello, this is the host speaking now for a while.")
    female = _voice(tmp, "Victoria", "That is a great question, let me answer you now.")
    gap = int(0.5 * SR)
    mix = torch.cat(
        [male, torch.zeros((male.shape[0], gap)), female, torch.zeros((female.shape[0], gap))],
        dim=1,
    )
    return {
        "tmp": tmp,
        "male": male,
        "female": female,
        "gap": gap,
        "mix": mix,
    }


def test_split_routes_low_and_high_voices(fixture):
    tmp, male, female, gap, mix = (
        fixture["tmp"], fixture["male"], fixture["female"], fixture["gap"], fixture["mix"],
    )
    src = str(tmp / "mix.wav")
    out = str(tmp / "out")
    write_wav(mix, src, SR)

    ret = speakers.main(["--input", src, "--out", out])
    assert ret == 0

    m, _ = read_wav(os.path.join(out, "male.wav"))
    f, _ = read_wav(os.path.join(out, "female.wav"))

    ms, me = 0, male.shape[-1]
    fs, fe = me + gap, me + gap + female.shape[-1]

    # Each gender's region must be clearly louder in its own file than in the
    # other (a ~11 dB separation in practice; assert a conservative 9.5 dB).
    assert _rms(m, ms, me) > 3.0 * _rms(f, ms, me)
    assert _rms(f, fs, fe) > 3.0 * _rms(m, fs, fe)


def test_split_preserves_length(fixture):
    tmp, mix = fixture["tmp"], fixture["mix"]
    src = str(tmp / "len.wav")
    out = str(tmp / "lenout")
    write_wav(mix, src, SR)

    assert speakers.main(["--input", src, "--out", out]) == 0
    m, _ = read_wav(os.path.join(out, "male.wav"))
    f, _ = read_wav(os.path.join(out, "female.wav"))
    assert m.shape == mix.shape
    assert f.shape == mix.shape
