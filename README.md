# Korean-Japanese Interpreter

한국어-일본어 실시간 양방향 통역 웹앱

## Features

- **분할 화면** — 위쪽(상대방용, 180도 회전) / 아래쪽(내 뷰)으로 테이블에 놓고 양쪽에서 대화 가능
- **4가지 파이프라인** — 브라우저 / 로컬 / OpenAI (드롭다운) + Realtime (독립 토글)
- **음성 인식** — 양쪽 모두 마이크 버튼으로 음성 입력 가능
- **텍스트 입력** — 키보드로 직접 입력, 언어 자동 감지
- **메타 지시어 이해** — "화장실이 어딨는지 물어봐줘" → 의도를 파악하여 번역 (브라우저/OpenAI 모드)
- **역번역 검증** — 번역 결과 아래에 한국어 의도를 항상 표시
- **대화 컨텍스트** — 이전 대화를 기억하여 문맥에 맞는 번역
- **글자 크기 조절** — 12~32px, 모든 텍스트에 적용
- **묵음 타임아웃** — auto / 2s~7s / OFF 선택 가능

## Pipeline Modes

| 모드 | STT (음성인식) | 번역 | TTS (음성합성) | 비용 | 오프라인 |
|---|---|---|---|---|---|
| **브라우저** | Browser Web Speech API | OpenAI GPT-4.1-mini | Browser speechSynthesis | API 과금 | X |
| **로컬** | Whisper (local) | TranslateGemma-4B (local) | Kokoro (JA) + Browser (KO) | 무료 | O (KO TTS 제외) |
| **OpenAI** | OpenAI Whisper | GPT-4.1-mini | gpt-4o-mini-tts | API 과금 | X |
| **Realtime** | OpenAI Realtime API | WebRTC speech-to-speech | (통합) | API 과금 | X |

- **메타 지시어**: 브라우저/OpenAI 모드에서만 지원. 로컬/Realtime 모드에서는 미지원
- **Realtime**: 드롭다운과 별도의 독립 토글로 on/off

## Quick Start

### 1. 요구사항
- Python 3.11+
- OpenAI API Key (브라우저/OpenAI/Realtime 모드)
- Chrome 브라우저 (브라우저 모드 음성 인식)
- GPU 권장 (로컬 모드 — Whisper, TranslateGemma-4B, Kokoro)

### 2. 설치

```bash
cd kor-jap-translator

# 가상환경 생성 및 의존성 설치
uv venv
source .venv/bin/activate
uv pip install -r requirements.txt
```

### 3. API 키 설정

```bash
cp .env.example .env
# .env 파일을 열고 OpenAI API 키 입력
# OPENAI_API_KEY=sk-proj-...
```

API 키는 [OpenAI Platform](https://platform.openai.com/api-keys)에서 발급받을 수 있습니다.
로컬 모드만 사용할 경우 API 키 없이도 동작합니다 (KO TTS는 브라우저 speechSynthesis 사용).

### 4. 실행

```bash
python main.py
```

브라우저에서 http://localhost:8001 접속

## Usage

### 화면 구성

```
┌──────────────────────────┐
│  (180도 회전 - 상대방용)    │
│  韓国語⇄日本語 通訳アプリ   │
│  [대화 내용]               │
│  [マイク] このボタンを...    │
├──────────────────────────┤  ← 구분선
│  한국어⇄일본어 통역앱       │
│  [대화 내용]               │
│  [설정: 모드/TTS/음성/크기]  │
│  [입력창] [전송] [마이크]    │
└──────────────────────────┘
```

### 한국어 화자 (아래쪽)
1. 텍스트 입력 또는 마이크 버튼으로 한국어 입력
2. 언어 자동 감지 → 일본어로 번역 + 음성 재생
3. 역번역으로 의도 전달 확인

### 일본어 화자 (위쪽)
1. 마이크 버튼 클릭 → 일본어로 말하기
2. 자동으로 한국어 번역 + 음성 재생

### 메타 지시어 (한국어 → 일본어)
일반 문장뿐 아니라 지시형 표현도 이해합니다 (브라우저/OpenAI 모드):

| 입력 (한국어) | 번역 결과 (일본어) |
|---|---|
| 화장실이 어딨는지 물어봐줘 | トイレはどこですか？ |
| 여기서 뭐가 제일 맛있는지 물어봐줘 | ここで一番美味しいものは何ですか？ |
| 고맙다고 전해줘 | ありがとうございます |
| 체크인 하고 싶다고 말해줘 | チェックインしたいのですが |

### 설정

| 설정 | 설명 |
|---|---|
| 파이프라인 드롭다운 | 브라우저 / 로컬 / OpenAI 모드 선택 |
| Realtime 토글 | OpenAI Realtime API on/off (독립 토글) |
| JA / KO 토글 | 언어별 TTS 음성 출력 on/off |
| 음성 선택 | 일본어(여/남), 한국어(중성/여/남) |
| A (크기) | 텍스트 크기 12~32px |
| 시계 (묵음) | auto / 2s~7s / OFF |
| KO/JA 버튼 | 마이크 인식 언어 전환 (아래쪽만) |

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

## API Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | 메인 페이지 |
| `POST` | `/api/translate` | 번역 요청 (OpenAI) |
| `POST` | `/api/tts` | 음성 합성 (OpenAI) |
| `POST` | `/api/stt` | 음성 인식 (OpenAI Whisper) |
| `POST` | `/api/realtime/session` | Realtime 세션 생성 |
| `POST` | `/api/local/translate` | 번역 요청 (로컬 TranslateGemma) |
| `POST` | `/api/local/stt` | 음성 인식 (로컬 Whisper) |
| `POST` | `/api/local/tts` | 음성 합성 (로컬 Kokoro) |

### POST /api/translate
```json
// Request
{ "text": "화장실이 어딨는지 물어봐줘", "direction": "ko2ja", "context": [] }

// Response
{ "translated": "トイレはどこですか？", "back_translation": "화장실이 어디에 있나요?" }
```

### POST /api/tts
```json
// Request
{ "text": "トイレはどこですか？", "lang": "ja", "voice": "coral", "speed": 1.15 }

// Response: audio/mpeg stream
```

## Notes

- **브라우저 호환성**: Chrome/Edge 권장 (Web Speech API 지원). Safari/Firefox는 음성 인식 제한적
- **비용**: OpenAI/브라우저 모드는 API 과금. 로컬 모드는 무료 (GPU 필요)
- **네트워크**: 로컬 모드는 오프라인 가능 (KO TTS만 브라우저 speechSynthesis 사용). 나머지 모드는 인터넷 필요
- **사용 시나리오**: 여행, 식당, 호텔 등에서 테이블에 폰을 놓고 양쪽에서 대화
