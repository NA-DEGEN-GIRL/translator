import os
from pathlib import Path
from fastapi import FastAPI, HTTPException, UploadFile, Form
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel, field_validator
import tempfile
from openai import OpenAI, OpenAIError
from dotenv import load_dotenv
import json
import logging
import httpx

from prompts import KO2JA_SYSTEM_PROMPT, JA2KO_SYSTEM_PROMPT, TTS_INSTRUCTIONS, REALTIME_SYSTEM_PROMPT

logger = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parent

load_dotenv()

app = FastAPI()
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

ALLOWED_VOICES = {"alloy", "ash", "coral", "nova", "onyx"}


class TranslateRequest(BaseModel):
    text: str
    direction: str
    context: list[dict] = []

    @field_validator("direction")
    @classmethod
    def validate_direction(cls, v):
        if v not in ("ko2ja", "ja2ko"):
            raise ValueError("direction must be 'ko2ja' or 'ja2ko'")
        return v

    @field_validator("text")
    @classmethod
    def validate_text(cls, v):
        v = v.strip()
        if not v:
            raise ValueError("text must not be empty")
        return v


class TTSRequest(BaseModel):
    text: str
    lang: str
    speed: float = 1.15
    voice: str | None = None

    @field_validator("lang")
    @classmethod
    def validate_lang(cls, v):
        if v not in ("ja", "ko"):
            raise ValueError("lang must be 'ja' or 'ko'")
        return v

    @field_validator("speed")
    @classmethod
    def validate_speed(cls, v):
        if not (0.25 <= v <= 4.0):
            raise ValueError("speed must be between 0.25 and 4.0")
        return v

    @field_validator("text")
    @classmethod
    def validate_text(cls, v):
        v = v.strip()
        if not v:
            raise ValueError("text must not be empty")
        return v


@app.post("/api/translate")
async def translate(req: TranslateRequest):
    system_prompt = KO2JA_SYSTEM_PROMPT if req.direction == "ko2ja" else JA2KO_SYSTEM_PROMPT

    messages = [{"role": "system", "content": system_prompt}]

    for ctx in req.context[-6:]:
        messages.append({"role": "user", "content": ctx.get("original", "")})
        messages.append({"role": "assistant", "content": json.dumps(
            {"translated": ctx.get("translated", "")}, ensure_ascii=False
        )})

    messages.append({"role": "user", "content": req.text})

    try:
        response = client.chat.completions.create(
            model="gpt-4.1-mini",
            messages=messages,
            temperature=0.3,
            response_format={"type": "json_object"},
        )
    except OpenAIError as e:
        logger.error(f"Translation API error: {e}")
        raise HTTPException(status_code=502, detail="번역 서비스에 연결할 수 없습니다")

    try:
        result = json.loads(response.choices[0].message.content)
        translated = result.get("translated", "")
        if not translated:
            raise ValueError("empty translation")
    except (json.JSONDecodeError, ValueError, IndexError) as e:
        logger.error(f"Translation parse error: {e}")
        raise HTTPException(status_code=502, detail="번역 결과를 처리할 수 없습니다")

    return {
        "translated": translated,
        "back_translation": result.get("intent_korean") if req.direction == "ko2ja" else None,
    }


@app.post("/api/tts")
async def tts(req: TTSRequest):
    default_voice = "onyx" if req.lang == "ja" else "nova"
    voice = req.voice if req.voice in ALLOWED_VOICES else default_voice

    try:
        response = client.audio.speech.create(
            model="gpt-4o-mini-tts",
            voice=voice,
            input=req.text,
            instructions=TTS_INSTRUCTIONS[req.lang],
            speed=req.speed,
        )
    except OpenAIError as e:
        logger.error(f"TTS API error: {e}")
        raise HTTPException(status_code=502, detail="음성 생성 서비스에 연결할 수 없습니다")

    def iter_bytes():
        for chunk in response.iter_bytes(1024):
            yield chunk

    return StreamingResponse(iter_bytes(), media_type="audio/mpeg")


REALTIME_VOICE_MAP = {
    "onyx": "ash",    # onyx not available in Realtime, use ash (male)
    "nova": "shimmer", # nova not available, use shimmer (female)
    "alloy": "alloy",
    "ash": "ash",
    "coral": "coral",
}


class RealtimeSessionRequest(BaseModel):
    voice: str = "coral"


@app.post("/api/realtime/session")
async def create_realtime_session(req: RealtimeSessionRequest):
    voice = REALTIME_VOICE_MAP.get(req.voice, "coral")
    api_key = os.getenv("OPENAI_API_KEY")

    try:
        async with httpx.AsyncClient() as http:
            r = await http.post(
                "https://api.openai.com/v1/realtime/client_secrets",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "session": {
                        "type": "realtime",
                        "model": "gpt-realtime-mini",
                        "audio": {"output": {"voice": voice}},
                        "instructions": REALTIME_SYSTEM_PROMPT,
                    }
                },
                timeout=10,
            )
    except httpx.HTTPError as e:
        logger.error(f"Realtime session error: {e}")
        raise HTTPException(status_code=502, detail="Realtime 세션을 생성할 수 없습니다")

    if r.status_code != 200:
        logger.error(f"Realtime session failed: {r.status_code} {r.text[:200]}")
        raise HTTPException(status_code=502, detail="Realtime 세션 생성 실패")

    return r.json()


LANG_CODES = {"ko": "ko", "ja": "ja"}


@app.post("/api/stt")
async def stt(file: UploadFile, lang: str = Form("ko")):
    if lang not in LANG_CODES:
        raise HTTPException(status_code=422, detail="lang must be 'ko' or 'ja'")

    audio_data = await file.read()
    if not audio_data:
        raise HTTPException(status_code=422, detail="empty audio file")

    try:
        with tempfile.NamedTemporaryFile(suffix=".webm", delete=True) as tmp:
            tmp.write(audio_data)
            tmp.flush()
            with open(tmp.name, "rb") as f:
                response = client.audio.transcriptions.create(
                    model="gpt-4o-mini-transcribe",
                    file=f,
                    language=LANG_CODES[lang],
                )
    except OpenAIError as e:
        logger.error(f"STT API error: {e}")
        raise HTTPException(status_code=502, detail="음성 인식 서비스에 연결할 수 없습니다")

    return {"text": response.text}


app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


@app.get("/")
async def root():
    return FileResponse(str(BASE_DIR / "static" / "index.html"), media_type="text/html")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
