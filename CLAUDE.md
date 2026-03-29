# Korean-Japanese Interpreter Web App

## Project Overview
한국어-일본어 실시간 통역 웹앱. 마이크 음성 인식 + 텍스트 입력으로 양방향 통역을 제공한다.
핵심 차별점은 **메타 지시어 이해** (예: "화장실이 어딨는지 물어봐줘" → 의도를 파악하여 번역)와
**자연스러운 대화형 TTS** (gpt-4o-mini-tts).

## Tech Stack
- **Backend**: Python FastAPI (main.py)
- **Frontend**: Vanilla HTML/CSS/JS (static/)
- **AI Models (OpenAI API)**:
  - 번역: `gpt-4.1-mini` — 빠른 속도 + 좋은 instruction following (nano는 메타 지시어 이해 부족)
  - TTS: `gpt-4o-mini-tts` — 감정/톤 제어 가능한 자연스러운 음성, `instructions` 파라미터로 스타일 지시
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
  index.html         # 분할 화면 UI (상대방 뷰 + 내 뷰)
  style.css          # rem 기반 반응형 스타일 (글자 크기 조절 지원)
  app.js             # 음성인식, API 호출, 오디오 스트리밍 재생, 미러 뷰 동기화
.env                 # OPENAI_API_KEY (gitignore 대상)
requirements.txt     # Python 의존성
```

### API Endpoints
- `POST /api/translate` — `{text, direction, context}` → `{translated, back_translation}`
- `POST /api/tts` — `{text, lang, voice?, speed?}` → audio/mpeg stream
- `GET /` — index.html 서빙

## Key Design Decisions

### 화면 분할 (Split View)
화면을 반으로 나눠 위쪽은 180도 회전(상대방용), 아래쪽은 내 뷰.
테이블에 폰을 놓으면 양쪽에서 대화를 볼 수 있는 구조.
- 위쪽: 일본어 안내 + 대화 내용 + 마이크 버튼 (일본어 고정)
- 아래쪽: 한국어 안내 + 대화 내용 + 설정 + 입력/마이크

### 언어 자동 감지
텍스트 입력 시 한글/히라가나/가타카나 유니코드 범위로 자동 판별.
마이크는 Web Speech API 특성상 사전 언어 지정 필요 → KO/JA 토글 제공.
상대방 마이크는 일본어로 고정.

### 메타 지시어 처리 (ko→ja)
GPT system prompt에서 메타 지시어 키워드(~물어봐, ~말해줘, ~전해줘 등)를 명시적으로 감지.
잘못된 번역 예시도 포함하여 오판 방지. `intent_korean` 필드로 역번역 항상 표시.

### 대화 컨텍스트
최근 3개 교환(6개 메시지)을 번역 요청에 포함하여 문맥에 맞는 번역 제공.

### TTS
- `gpt-4o-mini-tts`의 `instructions` 파라미터로 "친절한 통역사" 톤 지정
- 음성 선택 가능: 일본어(coral/onyx), 한국어(alloy/nova/ash)
- 속도 기본 1.15배속
- MediaSource API로 스트리밍 재생 (fallback: blob 방식)
- 언어별 TTS on/off 토글

### 마이크 동작
- 토글 방식: 클릭 → 녹음 시작, 다시 클릭 → 정지
- 묵음 타임아웃: auto(브라우저 기본) / 2s~7s / OFF 선택 가능
- auto: continuous=false (Web Speech API 기본 묵음 감지)
- 수동 설정: continuous=true + 커스텀 타이머

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
