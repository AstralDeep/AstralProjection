#!/usr/bin/env python3
# Rebuilds the tiny random-weight GGUF fixtures the runtime tests load: a Qwen3-ASR-shaped recognition pair (text model plus qwen3a audio encoder) and two chat models.
# Usage: python3 generate_fixtures.py [output-dir]; needs the gguf and numpy packages, and the files it writes are the committed fixtures next to this script.
import sys
from pathlib import Path

import numpy as np
from gguf import GGUFValueType, GGUFWriter

HIDDEN = 32
HEADS = 2
KV_HEADS = 1
HEAD_DIM = 16
FFN = 64
LAYERS = 2
CONSTANT_CHANNEL = 1.0
EOS_BIAS = 500.0
ASCII_BIAS = 1.0

SPECIALS = [
    "<|endoftext|>",
    "<|im_start|>",
    "<|im_end|>",
    "<|audio_start|>",
    "<|audio_end|>",
    "<asr_text>",
]
MERGES = [("h", "e"), ("Ġ", "t"), ("Ġt", "he"), ("i", "n"), ("e", "r"), ("Ġ", "a"), ("o", "n"), ("a", "n")]
CHATML = (
    "{% for message in messages %}<|im_start|>{{ message['role'] }}\n{{ message['content'] }}<|im_end|>\n{% endfor %}"
    "{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}"
)


def byte_alphabet():
    keep = list(range(33, 127)) + list(range(161, 173)) + list(range(174, 256))
    mapped = {b: chr(b) for b in keep}
    extra = 0
    for b in range(256):
        if b not in mapped:
            mapped[b] = chr(256 + extra)
            extra += 1
    return [mapped[b] for b in range(256)]


def vocabulary():
    tokens = byte_alphabet()
    for left, right in MERGES:
        if left + right not in tokens:
            tokens.append(left + right)
    types = [1] * len(tokens)
    first_special = len(tokens)
    tokens += SPECIALS
    types += [3] * len(SPECIALS)
    return tokens, types, first_special


def write_tokenizer(writer, tokens, types, first_special):
    writer.add_tokenizer_model("gpt2")
    writer.add_tokenizer_pre("qwen2")
    writer.add_token_list(tokens)
    writer.add_token_types(types)
    writer.add_token_merges([f"{a} {b}" for a, b in MERGES])
    writer.add_eos_token_id(first_special + SPECIALS.index("<|im_end|>"))
    writer.add_pad_token_id(first_special)
    writer.add_add_bos_token(False)
    writer.add_add_eos_token(False)


def text_weights(writer, rng, tokens, eos_id, eos_bias):
    vocab = len(tokens)

    def rand(*shape, scale=0.4):
        return (rng.standard_normal(shape) * scale).astype(np.float32)

    embedding = rand(vocab, HIDDEN, scale=1.0)
    embedding[:, 0] = CONSTANT_CHANNEL
    output = rand(vocab, HIDDEN, scale=0.5)
    output[:, 0] = 0.0
    output[97:123, 0] = ASCII_BIAS
    output[32, 0] = ASCII_BIAS
    output[eos_id, 0] = eos_bias
    writer.add_tensor("token_embd.weight", embedding)
    writer.add_tensor("output.weight", output)
    norm_scale = np.zeros(HIDDEN, dtype=np.float32)
    norm_scale[:] = 1.0
    writer.add_tensor("output_norm.weight", norm_scale)
    for layer in range(LAYERS):
        prefix = f"blk.{layer}."
        attn_out = rand(HIDDEN, HEADS * HEAD_DIM)
        attn_out[0, :] = 0.0
        ffn_down = rand(HIDDEN, FFN)
        ffn_down[0, :] = 0.0
        writer.add_tensor(prefix + "attn_norm.weight", np.ones(HIDDEN, dtype=np.float32))
        writer.add_tensor(prefix + "attn_q.weight", rand(HEADS * HEAD_DIM, HIDDEN))
        writer.add_tensor(prefix + "attn_k.weight", rand(KV_HEADS * HEAD_DIM, HIDDEN))
        writer.add_tensor(prefix + "attn_v.weight", rand(KV_HEADS * HEAD_DIM, HIDDEN))
        writer.add_tensor(prefix + "attn_q_norm.weight", np.ones(HEAD_DIM, dtype=np.float32))
        writer.add_tensor(prefix + "attn_k_norm.weight", np.ones(HEAD_DIM, dtype=np.float32))
        writer.add_tensor(prefix + "attn_output.weight", attn_out)
        writer.add_tensor(prefix + "ffn_norm.weight", np.ones(HIDDEN, dtype=np.float32))
        writer.add_tensor(prefix + "ffn_gate.weight", rand(FFN, HIDDEN))
        writer.add_tensor(prefix + "ffn_up.weight", rand(FFN, HIDDEN))
        writer.add_tensor(prefix + "ffn_down.weight", ffn_down)


def text_model(path, arch, name, seed, eos_bias, template=None, sections=None):
    tokens, types, first_special = vocabulary()
    eos_id = first_special + SPECIALS.index("<|im_end|>")
    writer = GGUFWriter(str(path), arch)
    writer.add_name(name)
    writer.add_block_count(LAYERS)
    writer.add_context_length(4096)
    writer.add_embedding_length(HIDDEN)
    writer.add_feed_forward_length(FFN)
    writer.add_head_count(HEADS)
    writer.add_head_count_kv(KV_HEADS)
    writer.add_key_length(HEAD_DIM)
    writer.add_value_length(HEAD_DIM)
    writer.add_layer_norm_rms_eps(1e-6)
    writer.add_rope_freq_base(1000000.0)
    if sections is not None:
        writer.add_key_value(f"{arch}.n_deepstack_layers", 0, GGUFValueType.UINT32)
        writer.add_rope_dimension_sections(sections)
    else:
        writer.add_rope_dimension_count(HEAD_DIM)
    write_tokenizer(writer, tokens, types, first_special)
    if template:
        writer.add_chat_template(template)
    text_weights(writer, np.random.default_rng(seed), tokens, eos_id, eos_bias)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


def audio_encoder(path, seed):
    rng = np.random.default_rng(seed)
    channels = 8
    mel_bins = 128
    writer = GGUFWriter(str(path), "clip")
    writer.add_name("tiny-asr-mmproj")
    writer.add_type("mmproj")
    writer.add_bool("clip.has_audio_encoder", True)
    writer.add_uint32("clip.audio.projection_dim", HIDDEN)
    writer.add_uint32("clip.audio.embedding_length", HIDDEN)
    writer.add_uint32("clip.audio.feed_forward_length", FFN)
    writer.add_uint32("clip.audio.block_count", LAYERS)
    writer.add_uint32("clip.audio.attention.head_count", HEADS)
    writer.add_uint32("clip.audio.num_mel_bins", mel_bins)
    writer.add_float32("clip.audio.attention.layer_norm_epsilon", 1e-5)
    writer.add_string("clip.audio.projector_type", "qwen3a")

    def rand(*shape, scale=0.1):
        return (rng.standard_normal(shape) * scale).astype(np.float32)

    def f16(array):
        return array.astype(np.float16)

    writer.add_tensor("a.position_embd.weight", rand(32, HIDDEN))
    in_channels = 1
    for index in (1, 2, 3):
        writer.add_tensor(f"a.conv2d.{index}.weight", f16(rand(channels, in_channels, 3, 3, scale=0.3)))
        writer.add_tensor(f"a.conv2d.{index}.bias", rand(channels, 1, 1))
        in_channels = channels
    writer.add_tensor("a.conv_out.weight", f16(rand(HIDDEN, (mel_bins // 8) * channels)))
    for layer in range(LAYERS):
        prefix = f"a.blk.{layer}."
        for norm in ("ln1", "ln2"):
            writer.add_tensor(prefix + norm + ".weight", np.ones(HIDDEN, dtype=np.float32))
            writer.add_tensor(prefix + norm + ".bias", np.zeros(HIDDEN, dtype=np.float32))
        for projection in ("attn_q", "attn_k", "attn_v", "attn_out"):
            writer.add_tensor(prefix + projection + ".weight", rand(HIDDEN, HIDDEN))
            writer.add_tensor(prefix + projection + ".bias", rand(HIDDEN, scale=0.01))
        writer.add_tensor(prefix + "ffn_up.weight", rand(FFN, HIDDEN))
        writer.add_tensor(prefix + "ffn_up.bias", rand(FFN, scale=0.01))
        writer.add_tensor(prefix + "ffn_down.weight", rand(HIDDEN, FFN))
        writer.add_tensor(prefix + "ffn_down.bias", rand(HIDDEN, scale=0.01))
    writer.add_tensor("a.post_ln.weight", np.ones(HIDDEN, dtype=np.float32))
    writer.add_tensor("a.post_ln.bias", np.zeros(HIDDEN, dtype=np.float32))
    writer.add_tensor("mm.a.mlp.1.weight", rand(HIDDEN, HIDDEN))
    writer.add_tensor("mm.a.mlp.1.bias", rand(HIDDEN, scale=0.01))
    writer.add_tensor("mm.a.mlp.2.weight", rand(HIDDEN, HIDDEN))
    writer.add_tensor("mm.a.mlp.2.bias", rand(HIDDEN, scale=0.01))
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent
    out.mkdir(parents=True, exist_ok=True)
    text_model(out / "tiny-asr.gguf", "qwen3vl", "tiny-asr", 11, -EOS_BIAS, sections=[4, 2, 2, 0])
    audio_encoder(out / "tiny-asr-mmproj.gguf", 12)
    text_model(out / "tiny-chat.gguf", "qwen3", "tiny-chat", 13, -EOS_BIAS, template=CHATML)
    text_model(out / "tiny-chat-short.gguf", "qwen3", "tiny-chat-short", 14, EOS_BIAS, template=CHATML)


if __name__ == "__main__":
    main()
