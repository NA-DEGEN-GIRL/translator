# Korean-Japanese Interpreter

한국어-일본어 실시간 양방향 통역 웹앱

## Features

- **분할 화면** — 위쪽(상대방용, 180도 회전) / 아래쪽(내 뷰)으로 테이블에 놓고 양쪽에서 대화 가능
- **4가지 파이프라인** — 브라우저 / 로컬 / OpenAI / Realtime
- **음성 인식** — 양쪽 모두 마이크 버튼으로 음성 입력 가능
- **텍스트 입력** — 키보드로 직접 입력, 언어 자동 감지
- **역번역 검증** — 번역 결과 아래에 역번역을 표시하여 의도 전달 확인
- **대화 컨텍스트** — 이전 대화를 기억하여 문맥에 맞는 번역 (브라우저/OpenAI 모드)
- **글자 크기 조절** — 12~32px
- **묵음 타임아웃** — auto / 2s~7s / OFF (브라우저 모드)
- **비밀번호 보호** — APP_PASSWORD 설정 시 로그인 필요

## Pipeline Modes

| 모드 | STT (음성인식) | 번역 | TTS (음성합성) | 비용 | 오프라인 |
|---|---|---|---|---|---|
| **브라우저** | Browser Web Speech API | OpenAI GPT-4.1-mini | Browser speechSynthesis | API 과금 | X |
| **로컬** | Whisper (local) | TranslateGemma-4B (local) | Kokoro (JA) + Browser (KO) | 무료 | O |
| **OpenAI** | OpenAI Whisper | GPT-4.1-mini | gpt-4o-mini-tts | API 과금 | X |
| **Realtime** | OpenAI Realtime API (WebRTC speech-to-speech, 통합) ||| API 과금 | X |

## Quick Start

### 1. 요구사항
- Python 3.11+
- OpenAI API Key (브라우저/OpenAI/Realtime 모드)
- Chrome 브라우저 (브라우저 모드 음성 인식)
- GPU 권장 (로컬 모드 — Whisper, TranslateGemma-4B, Kokoro)

### 2. 설치

```bash
cd kor-jap-translator

uv venv
source .venv/bin/activate
uv pip install -r requirements.txt

# 로컬 모드 사용 시 (선택)
uv pip install -r requirements-local.txt
```

### 3. API 키 설정

```bash
cp .env.example .env
# OPENAI_API_KEY=sk-proj-...
# APP_PASSWORD=your-password  (선택, 비워두면 비밀번호 없음)
```

### 4. 실행

```bash
python main.py
```

브라우저에서 http://localhost:8001 접속

### 5. 배포 (Docker)

```bash
docker build -t translator .
docker run -d -p 443:443 --env-file .env translator
```

## Usage

### 화면 구성

```
┌──────────────────────────┐
│  (180도 회전 - 상대방용)    │
│  韓国語⇄日本語通訳         │
│  [대화 내용]               │
│  [마이크] 押して話す→翻訳   │
├──────────────────────────┤
│  한국어⇄일본어통역          │
│  [대화 내용]               │
│  [설정] [입력창] [마이크]    │
└──────────────────────────┘
```

### 한국어 화자 (아래쪽)
1. 텍스트 입력 또는 마이크 버튼으로 한국어 입력
2. 언어 자동 감지 → 일본어로 번역 + 음성 재생
3. 역번역으로 의도 전달 확인

### 일본어 화자 (위쪽)
1. 마이크 버튼 클릭 → 일본어로 말하기
2. 자동으로 한국어 번역 + 음성 재생

## Tech Stack

| 구성 요소 | 기술 |
|---|---|
| Backend | Python FastAPI |
| Frontend | Vanilla HTML/CSS/JS |
| 번역 (OpenAI/브라우저) | OpenAI GPT-4.1-mini |
| 번역 (로컬) | TranslateGemma-4B |
| TTS (OpenAI) | gpt-4o-mini-tts |
| TTS (로컬 JA) | Kokoro TTS |
| TTS (브라우저/로컬 KO) | Browser speechSynthesis |
| STT (OpenAI) | OpenAI Whisper |
| STT (로컬) | Whisper (local) |
| STT (브라우저) | Web Speech API |
| Realtime | OpenAI Realtime API (WebRTC) |

## Notes

- **브라우저 호환성**: Chrome/Edge 권장 (Web Speech API 지원)
- **비용**: OpenAI/브라우저 모드는 API 과금. 로컬 모드는 무료 (GPU 필요)
- **네트워크**: 로컬 모드는 오프라인 가능. 나머지 모드는 인터넷 필요
- **HTTPS**: 모바일 마이크 사용 시 HTTPS 필요 (localhost 제외)
- **사용 시나리오**: 여행, 식당, 호텔 등에서 테이블에 폰을 놓고 양쪽에서 대화
