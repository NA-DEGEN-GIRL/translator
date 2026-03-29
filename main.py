import os
from pathlib import Path
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from openai import OpenAI
from dotenv import load_dotenv
import json

BASE_DIR = Path(__file__).resolve().parent

load_dotenv()

app = FastAPI()
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

KO2JA_SYSTEM_PROMPT = """あなたは韓国語→日本語の通訳者です。

# 最重要ルール：メタ指示の検出
韓国語の入力に以下のキーワードが含まれている場合、それは「メタ指示」です：
~해줘, ~물어봐, ~말해줘, ~전해줘, ~알려줘, ~부탁해, ~여쭤봐

メタ指示 = 話者が「あなた（通訳者）に代わりに言ってほしいこと」を指示している文。
→ 指示自体を翻訳するのではなく、**話者が相手に伝えたい内容だけ**を日本語にすること。

## メタ指示の例（絶対に守ること）：
入力: "화장실이 어딨는지 물어봐줘"
→ translated: "トイレはどこですか？" （❌ 「トイレがどこか聞いてください」は間違い）

入力: "여기서 뭐가 제일 맛있는지 물어봐줘"
→ translated: "ここで一番美味しいものは何ですか？" （❌ 「何が一番美味しいか聞いてください」は間違い）

入力: "고맙다고 전해줘"
→ translated: "ありがとうございます"

入力: "체크인 하고 싶다고 말해줘"
→ translated: "チェックインしたいのですが"

入力: "알레르기가 있는데 이거 먹어도 되는지 물어봐"
→ translated: "アレルギーがあるのですが、これは食べても大丈夫ですか？"

## 直接的な文の場合：
そのまま自然な日本語に翻訳する。

# 出力形式（JSON以外は出力しないこと）：
{"translated": "<日本語訳>", "intent_korean": "<実際に翻訳した韓国語の意図>"}

intent_korean: メタ指示の場合は抽出した意図（例："여기서 뭐가 제일 맛있나요?"）、直接文の場合は入力文そのまま。"""

JA2KO_SYSTEM_PROMPT = """あなたは日本語から韓国語への通訳者です。
入力された日本語を自然な韓国語に翻訳してください。
必ず以下のJSON形式で回答してください（他のテキストは含めないでください）：
{"translated": "<韓国語訳>"}"""


class TranslateRequest(BaseModel):
    text: str
    direction: str  # "ko2ja" or "ja2ko"
    context: list[dict] = []


class TTSRequest(BaseModel):
    text: str
    lang: str  # "ja" or "ko"
    speed: float = 1.15


@app.post("/api/translate")
async def translate(req: TranslateRequest):
    if req.direction == "ko2ja":
        system_prompt = KO2JA_SYSTEM_PROMPT
    else:
        system_prompt = JA2KO_SYSTEM_PROMPT

    messages = [{"role": "system", "content": system_prompt}]

    # Add conversation context for better contextual translation
    for ctx in req.context[-6:]:  # Last 3 exchanges
        messages.append({"role": "user", "content": ctx.get("original", "")})
        messages.append({"role": "assistant", "content": json.dumps(
            {"translated": ctx.get("translated", "")}, ensure_ascii=False
        )})

    messages.append({"role": "user", "content": req.text})

    response = client.chat.completions.create(
        model="gpt-4.1-mini",
        messages=messages,
        temperature=0.3,
        response_format={"type": "json_object"},
    )

    result = json.loads(response.choices[0].message.content)

    return {
        "translated": result.get("translated", ""),
        "back_translation": result.get("intent_korean") if req.direction == "ko2ja" else None,
    }


@app.post("/api/tts")
async def tts(req: TTSRequest):
    voice = "coral" if req.lang == "ja" else "alloy"
    instructions = (
        "Speak naturally in Japanese like a friendly, warm interpreter helping someone in person. "
        "Use a conversational, polite tone."
        if req.lang == "ja"
        else "Speak naturally in Korean like a friendly, warm interpreter helping someone in person. "
        "Use a conversational, polite tone."
    )

    response = client.audio.speech.create(
        model="gpt-4o-mini-tts",
        voice=voice,
        input=req.text,
        instructions=instructions,
        speed=req.speed,
    )

    def iter_bytes():
        for chunk in response.iter_bytes(1024):
            yield chunk

    return StreamingResponse(iter_bytes(), media_type="audio/mpeg")


app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


@app.get("/")
async def root():
    return FileResponse(str(BASE_DIR / "static" / "index.html"), media_type="text/html")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
