# Korean-Japanese Interpreter Web App

## Project Overview
한국어-일본어 실시간 통역 웹앱. 마이크 음성 인식 + 텍스트 입력으로 양방향 통역을 제공한다.
핵심 차별점은 **메타 지시어 이해** (예: "화장실이 어딨는지 물어봐줘" → 의도를 파악하여 번역)와
**자연스러운 대화형 TTS** (gpt-4o-mini-tts).

## Tech Stack
- **Backend**: Python FastAPI (main.py)
- **Frontend**: Vanilla HTML/CSS/JS (static/)
- **AI Models (OpenAI API)**:
  - 번역: `gpt-4.1-mini` — 빠른 속도 + 좋은 instruction following
  - TTS: `gpt-4o-mini-tts` — 감정/톤 제어 가능한 자연스러운 음성
- **Speech Recognition**: 브라우저 Web Speech API (Chrome 권장)
- **Runtime**: Python 3.11+, venv via `uv`

## Architecture

```
Browser (Web Speech API) → POST /api/translate → GPT-4.1-mini → JSON response
                         → POST /api/tts       → gpt-4o-mini-tts → audio/mpeg stream
```

### File Structure
```
main.py              # FastAPI 서버 — 번역 + TTS 엔드포인트
static/
  index.html         # 채팅 UI (마이크 + 텍스트 입력)
  style.css          # 반응형 모바일 우선 스타일
  app.js             # 음성인식, API 호출, 오디오 재생 로직
.env                 # OPENAI_API_KEY (gitignore 대상)
requirements.txt     # Python 의존성
```

### API Endpoints
- `POST /api/translate` — `{text, direction, context}` → `{translated, back_translation}`
- `POST /api/tts` — `{text, lang}` → audio/mpeg stream
- `GET /` — index.html 서빙

## Key Design Decisions

### 메타 지시어 처리 (ko→ja)
GPT system prompt에서 메타 지시어(~해달라고 말해줘, ~물어봐줘)를 감지하고
의도를 추출하여 번역. `intent_korean` 필드로 역번역을 제공하여 사용자가 의도 전달을 확인.

### 대화 컨텍스트
최근 3개 교환(6개 메시지)을 번역 요청에 포함하여 문맥에 맞는 번역 제공.

### TTS 스타일 지시
`gpt-4o-mini-tts`의 `instructions` 파라미터로 "친절한 통역사" 톤을 지정.
일본어는 `coral` 음성, 한국어는 `alloy` 음성 사용.

## Development

```bash
# 의존성 설치
uv venv && source .venv/bin/activate && uv pip install -r requirements.txt

# 서버 실행
python main.py  # http://localhost:8001
```

## Conventions
- 서버 포트: 8001 (8000은 다른 서비스 사용 중)
- 환경변수는 .env 파일에서 로드 (python-dotenv)
- 프론트엔드는 빌드 없이 순수 HTML/CSS/JS
