# Local/Open-Source Model Alternatives for Korean-Japanese Translation

Target Hardware: RTX 5090 (32GB VRAM), CUDA 12.8, PyTorch 2.12+, WSL2

## Executive Summary

There are two viable architectural approaches:

1. **End-to-End Omni Model** -- A single model that handles speech input, translation, and speech output (e.g., Qwen3-Omni)
2. **Modular Pipeline** -- Separate ASR + Translation + TTS models chained together (e.g., Whisper + TranslateGemma + CosyVoice2)

The modular pipeline is more mature and flexible today. The end-to-end approach is newer but rapidly catching up.

---

## Comparison Table

| Model | Type | KO/JA Support | VRAM (est.) | Latency | Speech-to-Speech? | PyTorch Compat | Maintained? | License |
|---|---|---|---|---|---|---|---|---|
| **Qwen3-Omni-30B-A3B** | End-to-end omni | KO+JA input & output | ~18GB (Q4 AWQ) | TTFT ~170ms on RTX 5090 | Yes (native) | 2.8+ (needs check for 2.12) | Active (2025) | Apache 2.0 |
| **Meta SeamlessM4T/Streaming** | End-to-end S2S | KO+JA (100 langs) | ~8-12GB | ~1-3s per utterance | Yes (native) | fairseq2 only supports up to PyTorch 2.9.1 | Stale (fairseq2 lag) | CC-BY-NC 4.0 |
| **Qwen3-ASR (0.6B / 1.7B)** | ASR only | KO+JA (52 langs) | ~2-4GB | 70ms for 10s audio (SenseVoice-class) | No (ASR only) | Transformers-based | Active (2025) | Apache 2.0 |
| **SenseVoice-Small** | ASR only | KO+JA+ZH+EN+Cantonese | ~1-2GB | 70ms for 10s audio (15x faster than Whisper) | No (ASR only) | Standard PyTorch | Active | Apache 2.0 |
| **Whisper large-v3** | ASR only | KO+JA (99+ langs) | ~4-6GB | ~1-3s per 30s chunk | No (ASR only) | Standard PyTorch | Stable | MIT |
| **Voxtral Transcribe 2** | ASR only | KO+JA (13 langs) | ~6-8GB (3B) | Real-time streaming | No (ASR only) | Standard PyTorch | Active (Mar 2026) | Apache 2.0 |
| **TranslateGemma (4B/12B/27B)** | Text translation | KO+JA (55 langs) | 4B: ~3GB, 12B: ~8GB | Fast text inference | No (text only) | Standard PyTorch | Active (Jan 2026) | Gemma license |
| **NLLB-200 (600M-3.3B)** | Text translation | KO+JA (200 langs) | 600M: ~2GB, 3.3B: ~7GB | Fast text inference | No (text only) | Standard PyTorch | Stable | CC-BY-NC 4.0 |
| **Qwen3-TTS (0.6B / 1.7B)** | TTS only | KO+JA (10 langs) | ~2-4GB | 97ms first packet | No (TTS only) | Transformers-based | Active (2025) | TBD (check repo) |
| **CosyVoice2-0.5B** | TTS only | KO+JA+ZH+EN+Cantonese | ~2-3GB | 150ms first packet | No (TTS only) | Standard PyTorch | Active | Apache 2.0 |
| **Kokoro-82M** | TTS only | KO+JA+EN+FR+ZH | <1GB | Real-time on CPU | No (TTS only) | Standard PyTorch | Active | Apache 2.0 |
| **Fish Speech v1.5** | TTS only | KO+JA (multilingual) | ~4GB | Real-time | No (TTS only) | Standard PyTorch | Active | Apache 2.0 |
| **MeloTTS** | TTS only | KO+JA+ZH+EN+ES+FR | <1GB | CPU real-time | No (TTS only) | Standard PyTorch | Declining | MIT |

---

## Detailed Analysis

### Option A: Qwen3-Omni (Best End-to-End Candidate)

**Why it stands out:**
- Single model does ASR + understanding + translation + speech output
- Natively supports Korean and Japanese for both input and output
- MoE architecture: 30B total params but only 3B active per token (efficient)
- Confirmed running on RTX 5090 with Q6 quantization: TTFT=0.171s, TPS=192.4
- AWQ 4-bit quantization fits in ~18GB VRAM
- Apache 2.0 license (commercial use OK)

**Concerns:**
- Relatively new; community deployment experience is still building
- PyTorch 2.12 compatibility unconfirmed (works with 2.8+, likely fine)
- Speech output quality for KO/JA needs hands-on evaluation
- Streaming/real-time mode requires vLLM setup

**Integration path:**
```
Browser mic -> WebSocket -> Qwen3-Omni (vLLM) -> text + speech output -> Browser
```

### Option B: Modular Pipeline (Most Flexible)

#### Recommended Stack:

```
ASR: SenseVoice-Small or Qwen3-ASR-1.7B
     -> (Korean/Japanese text)
Translation: TranslateGemma-4B or Qwen3-8B
     -> (Translated text)
TTS: CosyVoice2-0.5B or Qwen3-TTS-0.6B
     -> (Synthesized speech)
```

**Total VRAM estimate:** ~6-10GB (all three models simultaneously)

**Why this works:**
- Each component is best-in-class and independently upgradeable
- Very comfortable on 32GB VRAM
- SenseVoice: 15x faster than Whisper for CJK languages
- TranslateGemma: purpose-built translation model, outperforms general LLMs
- CosyVoice2: 150ms first-packet latency, excellent KO/JA quality
- All Apache 2.0 licensed

**Estimated end-to-end latency:**
- ASR: ~70-150ms
- Translation: ~100-300ms
- TTS first packet: ~150ms
- Total: ~320-650ms (good for near-real-time)

**Concerns:**
- More moving parts to manage
- Needs careful chunking/streaming coordination between stages
- Error propagation between stages

### Option C: Whisper + LLM + TTS (Simple but Slower)

```
ASR: Whisper large-v3
Translation: GPT/Qwen/TranslateGemma
TTS: Kokoro-82M or MeloTTS
```

**Pros:** Very well-documented, easy to set up
**Cons:** Whisper is slower than SenseVoice for CJK; Kokoro/MeloTTS quality may be lower

---

## Meta Seamless: Current Status (Why Alternatives Are Needed)

The core problem with Meta Seamless for your setup:

1. **fairseq2 does NOT support PyTorch 2.12** -- max supported is PyTorch 2.9.1
2. **CC-BY-NC 4.0 license** -- non-commercial only
3. **Development has slowed** -- fairseq2 updates lag behind PyTorch releases
4. **CUDA 12.8 support** -- fairseq2 supports cu128 but only up to PyTorch 2.9.1

This means if you upgrade to PyTorch 2.12 (needed for RTX 5090 Blackwell optimizations), Seamless will break. The alternatives above do not have this problem.

---

## Recommendation for This Project

### Short-term (PoC): Option B -- Modular Pipeline

```
SenseVoice-Small (ASR) + TranslateGemma-4B (Translation) + CosyVoice2-0.5B (TTS)
```

- Total VRAM: ~6-8GB (leaves 24GB headroom)
- All Apache 2.0
- Each component proven for KO/JA
- Easy to test each stage independently
- Can reuse current FastAPI server architecture

### Medium-term: Option A -- Qwen3-Omni

Once Qwen3-Omni's streaming mode matures and PyTorch 2.12 compatibility is confirmed:
- Switch to single-model architecture
- Simpler deployment (one model instead of three)
- Potentially better translation quality (end-to-end, no error propagation)
- ~18GB VRAM with Q4 quantization

### What NOT to use:
- **Meta Seamless** -- fairseq2/PyTorch version lock, NC license
- **NLLB-200** -- CC-BY-NC 4.0 license, text-only
- **MeloTTS** -- development declining, quality concerns for Korean
- **Soprano TTS** -- English only, no KO/JA support
- **NVIDIA Canary-Qwen** -- English ASR only, no KO/JA

---

## Quick Start: Modular Pipeline PoC

```bash
# 1. ASR (SenseVoice)
pip install funasr

# 2. Translation (TranslateGemma via Ollama)
ollama pull translategemma:4b

# 3. TTS (CosyVoice2)
git clone https://github.com/FunAudioLLM/CosyVoice
cd CosyVoice && pip install -r requirements.txt
```

Or via HuggingFace Transformers:
```python
# ASR
from funasr import AutoModel
asr_model = AutoModel(model="iic/SenseVoiceSmall")

# Translation
from transformers import AutoModelForCausalLM, AutoTokenizer
translator = AutoModelForCausalLM.from_pretrained("google/translategemma-4b")

# TTS
# CosyVoice2 or Qwen3-TTS via their respective APIs
```

---

## Sources

### End-to-End Models
- [Qwen3-Omni GitHub](https://github.com/QwenLM/Qwen3-Omni)
- [Qwen3-Omni HuggingFace](https://huggingface.co/Qwen/Qwen3-Omni-30B-A3B-Instruct)
- [Meta Seamless Communication](https://github.com/facebookresearch/seamless_communication)

### ASR Models
- [SenseVoice GitHub](https://github.com/FunAudioLLM/SenseVoice)
- [Qwen3-ASR GitHub](https://github.com/QwenLM/Qwen3-ASR)
- [Whisper GitHub](https://github.com/openai/whisper)
- [Voxtral Transcribe 2](https://mistral.ai/news/voxtral-transcribe-2)

### Translation Models
- [TranslateGemma (Google)](https://blog.google/innovation-and-ai/technology/developers-tools/translategemma/)
- [NLLB HuggingFace](https://huggingface.co/docs/transformers/model_doc/nllb)

### TTS Models
- [CosyVoice2 GitHub](https://github.com/FunAudioLLM/CosyVoice)
- [Qwen3-TTS GitHub](https://github.com/QwenLM/Qwen3-TTS)
- [Kokoro-82M HuggingFace](https://huggingface.co/hexgrad/Kokoro-82M)
- [Fish Speech](https://github.com/fishaudio/fish-speech)
- [MeloTTS GitHub](https://github.com/myshell-ai/MeloTTS)

### Pipeline Frameworks
- [HuggingFace Speech-to-Speech](https://github.com/huggingface/speech-to-speech)
- [GMI Cloud: Build Real-Time Voice Translator](https://www.gmicloud.ai/blog/how-to-build-a-real-time-voice-translator-with-open-source-ai)

### Compatibility
- [fairseq2 GitHub](https://github.com/facebookresearch/fairseq2)
- [NVIDIA Blackwell Migration Guide](https://forums.developer.nvidia.com/t/software-migration-guide-for-nvidia-blackwell-rtx-gpus-a-guide-to-cuda-12-8-pytorch-tensorrt-and-llama-cpp/321330)
- [Qwen3 VRAM Guide](https://apxml.com/posts/gpu-system-requirements-qwen-models)
