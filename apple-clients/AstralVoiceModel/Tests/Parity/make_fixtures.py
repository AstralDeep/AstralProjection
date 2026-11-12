"""Writes the reference fixtures that the Swift parity tests compare against, using the mlx-audio LFM3-Audio reference.
Run with the Edge-Test virtualenv: ASTRAL_LFM3_MODEL_DIR=<model dir> python make_fixtures.py <out dir>."""

import json
import os
import subprocess
import sys
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

import mlx.core as mx
import numpy as np

from mlx_audio.sts import load
from mlx_audio.sts.models.lfm3_audio.features import log_mel
from mlx_audio.sts.models.lfm3_audio.processor import load_clip

MODEL = os.environ.get("ASTRAL_LFM3_MODEL_DIR", "/Users/sam/Desktop/LFM3-Audio-Edge-Test/models/LFM3-Audio-2B-3bit")
SENTENCE = "Please remind me to call the clinic tomorrow morning."
TTS_TEXT = "The patient is stable."


def main(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    wav = out / "asr_input.wav"
    subprocess.run(["say", "-o", str(wav), "--data-format=LEI16@16000", SENTENCE], check=True)
    model = load(MODEL)
    proc = model.processor
    fixture = {"sentence": SENTENCE, "tts_text": TTS_TEXT}

    clip = load_clip(str(wav))
    mel = log_mel(clip)
    fixture["mel"] = {
        "samples": len(clip),
        "shape": list(mel.shape),
        "head": mel[:, :3].T.reshape(-1).tolist(),
        "tail": mel[:, -2:].T.reshape(-1).tolist(),
        "sum": float(mel.astype(np.float64).sum()),
    }

    messages = [
        {"role": "system", "content": "Perform ASR in English."},
        {"role": "user", "content": [{"type": "audio", "audio": clip}]},
    ]
    inputs = proc.prepare(messages, sample_rate=16000)
    ids = np.asarray(inputs["input_ids"])[0].tolist()
    fixture["asr_prompt_ids"] = ids
    features = mx.array(inputs["input_features"])
    mask = mx.array(inputs["feature_attention_mask"]).sum(-1)
    enc = model.audio_tower(features, mask)
    proj = model.audio_projector(enc)
    mx.eval(enc, proj)
    fixture["encoder"] = {
        "shape": list(enc.shape),
        "rows": [enc[i].astype(mx.float32).tolist()[:16] for i in (0, enc.shape[0] // 2, enc.shape[0] - 1)],
        "row_indices": [0, enc.shape[0] // 2, enc.shape[0] - 1],
    }
    fixture["projector"] = {
        "shape": list(proj.shape),
        "rows": [proj[i].astype(mx.float32).tolist()[:16] for i in (0, proj.shape[0] // 2, proj.shape[0] - 1)],
    }

    tokens = []
    for token, _ in model.stream_slots(**inputs, max_tokens=48, generation_mode="text", temperature=0.0):
        tokens.append(token)
    fixture["asr_first_tokens"] = tokens
    result = model.generate(str(wav), task="asr", sample_rate=16000, temperature=0.0)
    fixture["asr_transcript"] = result.text
    fixture["asr_token_ids"] = result.token_ids

    prompts = {}
    prompts["tts"] = proc.apply_chat_template(
        [
            {"role": "system", "content": "Perform TTS in English using a female voice."},
            {"role": "user", "content": [{"type": "text", "text": TTS_TEXT}]},
        ]
    )
    prompts["tts_ids"] = proc.tokenizer.encode(prompts["tts"], add_special_tokens=False)
    prompts["chat"] = proc.apply_chat_template(
        [
            {"role": "system", "content": "Respond briefly."},
            {"role": "user", "content": "Say hello."},
            {"role": "assistant", "content": "Hello there."},
            {"role": "user", "content": [{"type": "text", "text": "What is 2 plus 2?"}]},
        ]
    )
    prompts["chat_ids"] = proc.tokenizer.encode(prompts["chat"], add_special_tokens=False)
    fixture["prompts"] = prompts

    fixture["tokenizer"] = [
        {"text": text, "ids": proc.tokenizer.encode(text, add_special_tokens=False)}
        for text in [
            "Hello, world!",
            "  leading and trailing  ",
            "Numbers 12345 and 6789.",
            "naïve café — “quotes”",
            "line one\nline two\n\nline four",
            "<|im_start|>user\nhi<|im_end|>",
            "日本語のテキスト",
            "it's we're they'll I'd",
        ]
    ]
    fixture["tokenizer_decode"] = {
        "ids": ids[-12:],
        "text": proc.tokenizer.decode(ids[-12:], skip_special_tokens=True),
    }

    tts_inputs = proc.prepare(
        [
            {"role": "system", "content": "Perform TTS in English using a female voice."},
            {"role": "user", "content": [{"type": "text", "text": TTS_TEXT}]},
        ]
    )
    rng = np.random.default_rng(7)
    order = np.stack([rng.permutation(12) for _ in range(64)]).astype(np.int32)
    frames = []
    for token, codes in model.stream_slots(
        **tts_inputs,
        max_tokens=64,
        generation_mode="audio",
        audio_temperature=0.0,
        audio_top_k=0,
        audio_repetition_penalty=1.1,
        audio_repetition_window=4096,
        frame_order=order,
    ):
        if codes is not None:
            frames.append([int(v) for v in codes.tolist()])
    fixture["tts_frame_order"] = order.tolist()
    fixture["tts_frames"] = frames[:24]

    codec = model.codec()
    fixed = np.array([[(i * 37 + j * 91 + 5) % 2016 for i in range(8)] for j in range(12)], dtype=np.int32)
    wave = codec.decode(mx.array(fixed))
    mx.eval(wave)
    w = np.array(wave.astype(mx.float32))
    fixture["codec"] = {
        "codes": fixed.tolist(),
        "samples": int(w.shape[0]),
        "head": w[600:632].tolist(),
        "tail": w[-16:].tolist(),
        "abs_sum": float(np.abs(w).sum()),
    }
    (out / "reference.json").write_text(json.dumps(fixture))
    print("wrote", out, "transcript:", result.text)


main(sys.argv[1])
