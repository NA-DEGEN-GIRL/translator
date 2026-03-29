# Korean-Japanese Interpreter Web App

## Project Overview
한국어-일본어 실시간 통역 웹앱. 마이크 음성 인식 + 텍스트 입력으로 양방향 통역을 제공한다.
핵심 차별점은 **메타 지시어 이해** (예: "화장실이 어딨는지 물어봐줘" → 의도를 파악하여 번역)와
**4가지 파이프라인 모드** (브라우저 / 로컬 / OpenAI / Realtime).

## Pipeline Modes
드롭다운으로 브라우저/로컬/OpenAI 선택 + Realtime은 독립 토글:

| 모드 | STT | 번역 | TTS |
|---|---|---|---|
| **브라우저** | Browser Web Speech API | OpenAI GPT-4.1-mini | Browser speechSynthesis |
| **로컬** | Whisper (local) | TranslateGemma-4B (local) | Kokoro (JA) + Browser (KO) |
| **OpenAI** | OpenAI Whisper | GPT-4.1-mini | gpt-4o-mini-tts |
| **Realtime** | OpenAI Realtime API (WebRTC speech-to-speech, 통합) |||

- 로컬 모드: 무료, 오프라인 동작 (KO TTS만 브라우저 speechSynthesis)
- 메타 지시어: 브라우저/OpenAI 모드에서만 지원 (로컬/Realtime 미지원)

## Tech Stack
- **Backend**: Python FastAPI (main.py)
- **Frontend**: Vanilla HTML/CSS/JS (static/)
- **OpenAI 모드**: GPT-4.1-mini (번역), gpt-4o-mini-tts (TTS), Whisper (STT)
- **로컬 모드**: Whisper small (STT), TranslateGemma-4B (번역), Kokoro (JA TTS)
- **브라우저 모드**: Web Speech API (STT), GPT-4.1-mini (번역), speechSynthesis (TTS)
- **Realtime 모드**: OpenAI Realtime API (WebRTC)
- **Runtime**: Python 3.11+, venv via `uv`

## Architecture

```
[브라우저 모드] Browser Speech API → /api/translate (GPT-4.1-mini) → Browser speechSynthesis
[로컬 모드]    /api/local/stt (Whisper) → /api/local/translate (TranslateGemma) → /api/local/tts (Kokoro)
[OpenAI 모드]  /api/stt (Whisper) → /api/translate (GPT-4.1-mini) → /api/tts (gpt-4o-mini-tts)
[Realtime]     /api/realtime/session → WebRTC speech-to-speech
```

### File Structure
```
main.py              # FastAPI 서버 — 모든 API 엔드포인트
local_models.py      # 로컬 모델 관리 — Whisper, TranslateGemma-4B, Kokoro TTS (lazy loading)
prompts.py           # 모든 프롬프트 — KO2JA, JA2KO, TTS, Realtime system prompts
static/
  index.html         # 분할 화면 UI (상대방 뷰 + 내 뷰)
  style.css          # rem 기반 반응형 스타일 (글자 크기 조절 지원)
  app.js             # 음성인식, API 호출, 오디오 스트리밍 재생, 미러 뷰 동기화, 파이프라인 전환
.env                 # OPENAI_API_KEY (gitignore 대상)
requirements.txt     # Python 의존성
```

### API Endpoints
- `POST /api/translate` — `{text, direction, context}` → `{translated, back_translation}` (OpenAI)
- `POST /api/tts` — `{text, lang, voice?, speed?}` → audio/mpeg stream (OpenAI)
- `POST /api/stt` — audio file upload → `{text}` (OpenAI Whisper)
- `POST /api/realtime/session` — Realtime API 세션 생성
- `POST /api/local/translate` — `{text, direction, context}` → `{translated, back_translation}` (TranslateGemma)
- `POST /api/local/stt` — audio file upload → `{text}` (local Whisper)
- `POST /api/local/tts` — `{text, lang}` → audio/wav stream (Kokoro)
- `GET /` — index.html 서빙

## Key Design Decisions

### 화면 분할 (Split View)
화면을 반으로 나눠 위쪽은 180도 회전(상대방용), 아래쪽은 내 뷰.
테이블에 폰을 놓으면 양쪽에서 대화를 볼 수 있는 구조.
- 위쪽: 일본어 안내 + 대화 내용 + 마이크 버튼 (일본어 고정)
- 아래쪽: 한국어 안내 + 대화 내용 + 설정 + 입력/마이크

### 파이프라인 모드 선택
드롭다운(브라우저/로컬/OpenAI)으로 전체 파이프라인(STT+번역+TTS)을 일괄 전환.
Realtime은 별도 토글로 독립 제어 (WebRTC speech-to-speech).

### 로컬 모드
local_models.py에서 모델을 lazy loading으로 관리. 첫 요청 시 모델 로드.
- Whisper small: 음성 인식
- TranslateGemma-4B: 번역 (메타 지시어 미지원)
- Kokoro: 일본어 TTS (한국어는 브라우저 speechSynthesis fallback)

### 언어 자동 감지
텍스트 입력 시 한글/히라가나/가타카나 유니코드 범위로 자동 판별.
마이크는 사전 언어 지정 필요 → KO/JA 토글 제공. 상대방 마이크는 일본어 고정.

### 메타 지시어 처리 (ko→ja)
prompts.py의 system prompt에서 메타 지시어 키워드(~물어봐, ~말해줘, ~전해줘 등)를 명시적으로 감지.
잘못된 번역 예시도 포함하여 오판 방지. 브라우저/OpenAI 모드에서만 동작 (GPT 기반).

### 대화 컨텍스트
최근 3개 교환(6개 메시지)을 번역 요청에 포함하여 문맥에 맞는 번역 제공.

### TTS
- OpenAI 모드: `gpt-4o-mini-tts`의 `instructions` 파라미터로 "친절한 통역사" 톤 지정
- 로컬 모드: Kokoro (JA) + Browser speechSynthesis (KO)
- 브라우저 모드: Browser speechSynthesis (양쪽 언어)
- 음성 선택, 속도 조절, 언어별 on/off 토글

### 마이크 동작
- 토글 방식: 클릭 → 녹음 시작, 다시 클릭 → 정지
- 묵음 타임아웃: auto(브라우저 기본) / 2s~7s / OFF 선택 가능

### 글자 크기
CSS를 rem 기반으로 구성. html의 font-size를 변경하면 전체 텍스트가 비례 조절.
12~32px 선택 가능. 버튼/아이콘 등 UI 요소는 고정 px.

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
- 정적 파일 변경은 서버 재시작 불필요 (브라우저 새로고침만)
- 프롬프트는 prompts.py에 집중 관리
- 로컬 모델은 local_models.py에서 lazy loading으로 관리
