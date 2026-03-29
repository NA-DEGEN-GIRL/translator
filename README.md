# KO⇄JA Translator

한국어-일본어 실시간 양방향 통역 앱 (Flutter — Android / Web)

## Features

- **분할 화면** — 위쪽(상대방용, 180도 회전) / 아래쪽(내 뷰), 테이블에 놓고 양쪽에서 대화
- **3가지 모드** — 브라우저 / OpenAI / Realtime
- **음성 인식** — 양쪽 마이크 버튼으로 음성 입력
- **텍스트 입력** — 키보드 입력, 언어 자동 감지
- **역번역 검증** — 번역 결과 아래에 역번역 표시
- **GPT 모델 선택** — gpt-4.1-nano ~ gpt-5.4
- **TTS 음성 선택** — 언어별 남/여, on/off, 속도 조절
- **Realtime** — OpenAI Realtime API (WebRTC speech-to-speech)
- **API 키 보안** — flutter_secure_storage (Android 키스토어 암호화)
- **텍스트 선택/복사** — 번역 결과 길게 눌러 복사

## Pipeline Modes

| 모드 | STT | 번역 | TTS |
|---|---|---|---|
| **브라우저** | 기기 내장 (speech_to_text) | OpenAI GPT | 기기 내장 (flutter_tts) |
| **OpenAI** | 녹음 → OpenAI Whisper | OpenAI GPT | OpenAI gpt-4o-mini-tts |
| **Realtime** | WebRTC (통합) | Realtime API | WebRTC (통합) |

## Quick Start

### 요구사항
- Flutter 3.x+
- OpenAI API Key
- Android Studio (APK) 또는 Chrome (웹)

### 설치

```bash
git clone https://github.com/NA-DEGEN-GIRL/translator.git
cd translator
flutter pub get
```

### 실행 (웹)

```bash
# API 키 없이 — 앱에서 직접 입력
flutter run -d chrome

# API 키 내장 (개인용)
flutter run -d chrome --dart-define=OPENAI_API_KEY=your-key-here
```

### APK 빌드

```bash
# API 키 없이 (권장 — 앱에서 입력)
flutter build apk --release

# API 키 내장 (개인용 — 디컴파일 시 키 추출 가능, 주의)
flutter build apk --release --dart-define=OPENAI_API_KEY=your-key-here
```

### API 키 관리

- **첫 실행**: API 키 입력 화면 표시
- **저장**: Android — flutter_secure_storage (키스토어 암호화), Web — SharedPreferences
- **변경**: 설정 → `키초기화` → 새 키 입력
- **`--dart-define`으로 빌드 시**: 내장 키 우선 사용 (입력 화면 스킵)

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
| 모델 | GPT 4.1n~5.4 / Realtime mini~1.5 |
| J / K | TTS on/off |
| 음성 | 남/여 |
| 크기 | 12~32px |
| 속도 | 0.5x~1.5x (브라우저) |
| 묵음 | 1s~7s / OFF |
| 소음 | 높/보통/낮/조용 (OpenAI) |
| 감도 | 0.3~0.95 (Realtime VAD) |
| 키초기화 | API 키 삭제 + 입력 화면 |

## Tech Stack

| 구성 요소 | 기술 |
|---|---|
| Framework | Flutter (Android + Web) |
| 번역 | OpenAI GPT-4.1 / GPT-5.4 |
| TTS (OpenAI) | gpt-4o-mini-tts |
| TTS (기기) | flutter_tts |
| STT (기기) | speech_to_text |
| STT (OpenAI) | record + Whisper API |
| Realtime | flutter_webrtc + OpenAI Realtime API |
| 키 저장 | flutter_secure_storage |
| 설정 저장 | shared_preferences |
| 오디오 재생 | audioplayers |

## Security

- **API 키**: 앱에서 직접 입력 → OS 키스토어 암호화 저장 (Android)
- **`--dart-define`**: 편의용. APK에 평문 포함되므로 공개 배포 시 사용 금지
- **저장소**: 실제 API 키 없음. `.env`, `.pem` 등은 `.gitignore`
- **권장**: 키 미내장 빌드 (`flutter build apk --release`) + 앱에서 키 입력

## License

Private use.
