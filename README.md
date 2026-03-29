# Korean-Japanese Interpreter

한국어-일본어 실시간 양방향 통역 앱 (Flutter — Android / Web)

## Features

- **분할 화면** — 위쪽(상대방용, 180도 회전) / 아래쪽(내 뷰)으로 테이블에 놓고 양쪽에서 대화 가능
- **3가지 모드** — 브라우저 / OpenAI / Realtime
- **음성 인식** — 양쪽 모두 마이크 버튼으로 음성 입력
- **텍스트 입력** — 키보드로 직접 입력, 언어 자동 감지
- **역번역 검증** — 번역 결과 아래에 역번역 표시
- **GPT 모델 선택** — gpt-4.1-nano ~ gpt-5.4 중 선택 가능 (기본: gpt-5.4-nano)
- **TTS 음성 선택** — 언어별 남/여 음성, on/off, 속도 조절
- **글자 크기 조절** — 12~32px
- **묵음 타임아웃** — 2s~7s / OFF (브라우저 모드)
- **설정 토글** — 기어 버튼으로 설정 줄 접기/펼치기
- **서버 불필요** — 앱에서 OpenAI API 직접 호출

## Pipeline Modes

| 모드 | STT (음성인식) | 번역 | TTS (음성합성) |
|---|---|---|---|
| **브라우저** | speech_to_text (기기 내장) | OpenAI GPT | flutter_tts (기기 내장) |
| **OpenAI** | record → OpenAI Whisper API | OpenAI GPT | OpenAI gpt-4o-mini-tts |
| **Realtime** | OpenAI Realtime API (WebRTC, speech-to-speech 통합) |||

## Quick Start

### 요구사항
- Flutter 3.x+
- OpenAI API Key
- Android Studio (APK 빌드 시) 또는 Chrome (웹)

### 설치 및 실행

```bash
git clone https://github.com/NA-DEGEN-GIRL/translator.git
cd translator
git checkout flutter-app

flutter pub get
```

### 웹에서 실행

```bash
# API 키 내장
flutter run -d chrome --dart-define=OPENAI_API_KEY=sk-proj-...

# 또는 웹 서버 모드
flutter run -d web-server --web-port 8002 --dart-define=OPENAI_API_KEY=sk-proj-...
```

### APK 빌드

```bash
flutter build apk --dart-define=OPENAI_API_KEY=sk-proj-...
# → build/app/outputs/flutter-apk/app-release.apk
```

### API 키 없이 실행

```bash
flutter run -d chrome
# → 앱에서 API 키 입력 화면 표시, SharedPreferences에 저장
```

## 화면 구성

```
┌──────────────────────────┐
│  (180도 회전 - 상대방용)    │
│  韓国語⇄日本語通訳         │
│  [대화 내용]               │
│  [마이크] 押して話す→翻訳   │
├──────────────────────────┤
│  한국어⇄일본어통역          │
│  [대화 내용]               │
│  [⚙설정] [입력] [마이크]    │
└──────────────────────────┘
```

## 설정

| 설정 | 설명 |
|---|---|
| 모드 | 브라우저 / OpenAI / RT |
| GPT 모델 | 4.1n / 4.1m / 5.4n / 5.4m / 5.4 |
| J / K 토글 | 언어별 TTS on/off |
| 음성 | 남/여 선택 |
| 글자 크기 | 12~32px |
| TTS 속도 | 0.5x~1.5x (브라우저 모드) |
| 묵음 타임아웃 | 2s~7s / OFF (브라우저 모드) |

## Tech Stack

| 구성 요소 | 기술 |
|---|---|
| Framework | Flutter (Android + Web) |
| 번역 | OpenAI GPT-4.1 / GPT-5.4 |
| TTS (OpenAI) | gpt-4o-mini-tts |
| TTS (브라우저) | flutter_tts |
| STT (브라우저) | speech_to_text |
| STT (OpenAI) | record + Whisper API |
| Realtime | flutter_webrtc + OpenAI Realtime API |
| 상태 저장 | shared_preferences |
| 오디오 재생 | audioplayers |

## Branches

| 브랜치 | 설명 |
|---|---|
| `main` | Python FastAPI 웹앱 (원본) |
| `flutter-app` | Flutter 앱 (Android + Web) |

## Notes

- **서버 불필요**: Flutter 앱이 OpenAI API를 직접 호출 (API 키는 앱에 내장 또는 입력)
- **브라우저 모드**: 기기 내장 STT/TTS 사용, API 비용은 번역만 발생
- **OpenAI 모드**: STT + 번역 + TTS 모두 OpenAI API (고품질, 비용 높음)
- **Realtime 모드**: WebRTC speech-to-speech (최저 지연, 모델이 대화로 빠질 수 있음)
- **HTTPS**: 모바일 웹에서 마이크 사용 시 HTTPS 필요
- **사용 시나리오**: 여행, 식당, 호텔 등에서 테이블에 폰을 놓고 양쪽에서 대화
