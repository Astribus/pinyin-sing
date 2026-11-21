"""Times every sung character of a song's lyrics against a recording of it.

1. Separates the vocals from the music with Demucs (htdemucs).
2. Force-aligns each line's romanized lyrics (pinyin) to the vocals with the MMS_FA
   aligner that ships with torchaudio, searching a window around the line's start time.
3. Writes the start and end of every character in song time, with a confidence score
   per line, so poor matches can be skipped.

Usage: python align.py <recording.wav> <job.json> <result.json>

job.json:    {"offset": song seconds at recording start,
              "lines": [{"index": 3, "start": 12.3, "end": 15.0, "units": ["wo", "men", ...]}]}
result.json: {"lines": [{"index": 3, "score": 0.82, "times": [[12.41, 12.70], ...]}]}
"""

import json
import os
import subprocess
import sys
import tempfile

import soundfile
import torch
import torchaudio
from torchaudio.pipelines import MMS_FA as BUNDLE


def separate_vocals(wav_path, work_dir, device):
    subprocess.run(
        [sys.executable, "-m", "demucs", "--two-stems", "vocals", "-n", "htdemucs",
         "-d", device, "-o", work_dir, wav_path],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    name = os.path.splitext(os.path.basename(wav_path))[0]
    return os.path.join(work_dir, "htdemucs", name, "vocals.wav")


def clean_unit(text):
    """Keeps only letters the aligner knows (pinyin without tones, latin words)."""
    text = text.lower().replace("ü", "u")
    return "".join(ch for ch in text if ch in LETTERS)


def main():
    wav_path, job_path, out_path = sys.argv[1:4]
    with open(job_path, encoding="utf-8") as f:
        job = json.load(f)
    offset = float(job["offset"])

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    with tempfile.TemporaryDirectory() as work:
        vocals = separate_vocals(wav_path, work, device)
        data, rate = soundfile.read(vocals, dtype="float32", always_2d=True)
    waveform = torch.from_numpy(data.T.copy()).mean(0, keepdim=True)
    waveform = torchaudio.functional.resample(waveform, rate, BUNDLE.sample_rate)
    sr = BUNDLE.sample_rate
    total = waveform.shape[1] / sr

    model = BUNDLE.get_model(with_star=False).to(device)
    tokenizer = BUNDLE.get_tokenizer()
    aligner = BUNDLE.get_aligner()

    results = []
    for line in job["lines"]:
        units = [clean_unit(u) for u in line["units"]]
        keep = [i for i, u in enumerate(units) if u]
        if not keep:
            continue
        # Window: a little before the listed start (lyric files are often late) to the
        # next line's start, in recording time.
        a = max(0.0, float(line["start"]) - offset - 1.5)
        b = min(total, float(line["end"]) - offset + 0.5)
        if b - a < 0.5:
            continue
        clip = waveform[:, int(a * sr):int(b * sr)].to(device)
        with torch.inference_mode():
            emission, _ = model(clip)
        emission = emission.cpu()
        try:
            spans = aligner(emission[0], tokenizer([units[i] for i in keep]))
        except Exception:
            continue
        frames = clip.shape[1] / emission.shape[1] / sr  # seconds per emission frame
        times = [None] * len(units)
        scores = []
        for k, word in zip(keep, spans):
            start = a + word[0].start * frames + offset
            end = a + word[-1].end * frames + offset
            times[k] = [round(start, 3), round(end, 3)]
            scores.extend(float(s.score) for s in word)
        results.append({
            "index": line["index"],
            "score": round(sum(scores) / len(scores), 3) if scores else 0.0,
            "times": times,
        })

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"lines": results}, f)


LETTERS = set("abcdefghijklmnopqrstuvwxyz'")

if __name__ == "__main__":
    main()
