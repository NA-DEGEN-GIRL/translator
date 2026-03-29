# Korean-Japanese Interpreter

한국어-일본어 실시간 양방향 통역 웹앱

## Features

- **음성 인식** — 마이크로 한국어/일본어 실시간 인식 (Web Speech API)
- **텍스트 입력** — 키보드로 직접 입력 가능, Enter로 전송
- **메타 지시어 이해** — "화장실이 어딨는지 물어봐줘" → 의도를 파악하여 "トイレはどこですか？"로 번역
- **역번역 검증** — 번역 결과 아래에 한국어 의도를 표시하여 의도 전달 확인
- **자연스러운 TTS** — OpenAI gpt-4o-mini-tts로 ChatGPT 대화 모드 수준의 자연스러운 음성
- **대화 컨텍스트** — 이전 대화를 기억하여 문맥에 맞는 번역

## Quick Start

### 1. 요구사항
- Python 3.11+
- OpenAI API Key
- Chrome 브라우저 (음성 인식 지원)

### 2. 설치

```bash
# 저장소 클론 후
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

### 4. 실행

```bash
python main.py
```

브라우저에서 http://localhost:8001 접속

## Usage

### 기본 사용법
1. 상단 버튼으로 **한국어 화자** / **일본어 화자** 모드 전환
2. 하단 **마이크 버튼** 클릭 → 말하기 → 자동 번역 + 음성 재생
3. 또는 **텍스트 입력창**에 직접 타이핑 후 Enter 또는 전송 버튼 클릭

### 메타 지시어 (한국어 → 일본어)
일반 문장뿐 아니라 지시형 표현도 이해합니다:

| 입력 (한국어) | 번역 결과 (일본어) |
|---|---|
| 화장실이 어딨는지 물어봐줘 | トイレはどこですか？ |
| 고맙다고 전해줘 | ありがとうございます |
| 이거 얼마인지 물어봐 | これはいくらですか？ |
| 체크인 하고 싶다고 말해줘 | チェックインしたいのですが |

### 역번역 검증
한국어→일본어 번역 시, 번역문 아래에 `(화장실이 어디에 있나요?)`처럼 AI가 이해한 의도를 한국어로 표시합니다.

## Tech Stack

| 구성 요소 | 기술 |
|---|---|
| Backend | Python FastAPI |
| Frontend | Vanilla HTML/CSS/JS |
| 번역 | OpenAI GPT-4.1-mini |
| TTS | OpenAI gpt-4o-mini-tts |
| 음성 인식 | Web Speech API (브라우저) |

## API Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | 메인 페이지 |
| `POST` | `/api/translate` | 번역 요청 |
| `POST` | `/api/tts` | 음성 합성 요청 |

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
{ "text": "トイレはどこですか？", "lang": "ja" }

// Response: audio/mpeg stream
```

## Notes

- **브라우저 호환성**: Chrome/Edge 권장 (Web Speech API 지원). Safari/Firefox는 음성 인식 제한적
- **비용**: OpenAI API 사용량에 따라 과금 (GPT-4.1-mini는 저렴, gpt-4o-mini-tts는 자연스러운 음성)
- **네트워크**: 번역과 TTS 모두 OpenAI API를 호출하므로 인터넷 연결 필요
