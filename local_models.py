"""Local models: Whisper (ASR) + TranslateGemma-4B (Translation) + Kokoro (TTS)"""
import torch
import logging
import io
import threading

logger = logging.getLogger(__name__)

# Lazy-loaded singletons with thread-safe initialization
_whisper_pipe = None
_translate_model = None
_translate_tokenizer = None
_kokoro_pipe = None

_whisper_lock = threading.Lock()
_translate_lock = threading.Lock()
_kokoro_lock = threading.Lock()


def get_whisper():
    global _whisper_pipe
    if _whisper_pipe is None:
        with _whisper_lock:
            if _whisper_pipe is None:  # double-check
                from transformers import pipeline
                logger.info("Loading Whisper small...")
                _whisper_pipe = pipeline(
                    "automatic-speech-recognition",
                    model="openai/whisper-small",
                    device="cuda",
                    dtype=torch.float16,
                )
                logger.info("Whisper loaded")
    return _whisper_pipe


def get_translator():
    global _translate_model, _translate_tokenizer
    if _translate_model is None:
        with _translate_lock:
            if _translate_model is None:  # double-check
                from transformers import AutoTokenizer, AutoModelForCausalLM
                from huggingface_hub import get_token

                model_id = "google/translategemma-4b-it"
                token = get_token()
                logger.info("Loading TranslateGemma-4B...")
                _translate_tokenizer = AutoTokenizer.from_pretrained(model_id, token=token)
                _translate_model = AutoModelForCausalLM.from_pretrained(
                    model_id, token=token, torch_dtype=torch.bfloat16, device_map="cuda"
                )
                logger.info(f"TranslateGemma loaded. VRAM: {torch.cuda.memory_allocated()/1024**3:.1f}GB")
    return _translate_model, _translate_tokenizer


LANG_MAP = {
    "ko": "Korean",
    "ja": "Japanese",
}


def transcribe(audio_path: str, lang: str = "ko") -> str:
    """Transcribe audio file to text using Whisper."""
    pipe = get_whisper()
    result = pipe(audio_path, generate_kwargs={"language": LANG_MAP.get(lang, "Korean").lower()})
    return result["text"].strip()


def translate_text(text: str, direction: str) -> str:
    """Translate text using TranslateGemma-4B. direction: 'ko2ja' or 'ja2ko'"""
    model, tokenizer = get_translator()

    if direction == "ko2ja":
        src, tgt = "Korean", "Japanese"
    else:
        src, tgt = "Japanese", "Korean"

    prompt = f"<start_of_turn>user\nTranslate to {tgt}. Output ONLY the translation, nothing else.\n{text}<end_of_turn>\n<start_of_turn>model\n"
    inputs = tokenizer(prompt, return_tensors="pt").to("cuda")

    with torch.no_grad():
        out = model.generate(**inputs, max_new_tokens=128, do_sample=False)

    result = tokenizer.decode(out[0][inputs.input_ids.shape[1]:], skip_special_tokens=True)
    # Take only the first line to avoid explanations
    first_line = result.strip().split("\n")[0].strip()
    # Remove leading * or - bullet markers
    if first_line.startswith(("* ", "- ")):
        first_line = first_line[2:]
    return first_line


def get_kokoro():
    global _kokoro_pipe
    if _kokoro_pipe is None:
        with _kokoro_lock:
            if _kokoro_pipe is None:  # double-check
                from kokoro import KPipeline
                logger.info("Loading Kokoro TTS (Japanese)...")
                _kokoro_pipe = KPipeline(lang_code="j")
                list(_kokoro_pipe("テスト", voice="jf_alpha"))
                logger.info("Kokoro TTS loaded")
    return _kokoro_pipe


def synthesize_ja(text: str) -> bytes:
    """Synthesize Japanese speech using Kokoro. Returns WAV bytes."""
    import soundfile as sf

    pipe = get_kokoro()
    all_audio = []
    for _, _, audio in pipe(text, voice="jf_alpha"):
        all_audio.append(audio)

    import numpy as np
    combined = np.concatenate(all_audio)

    buf = io.BytesIO()
    sf.write(buf, combined, 24000, format="WAV")
    return buf.getvalue()
