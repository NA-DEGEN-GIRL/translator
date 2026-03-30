# Korean-Japanese Translator (Flutter)

## Project Overview
다국어 실시간 통역 앱. Flutter로 Android + Web 지원.
서버 불필요 — 앱에서 OpenAI API 직접 호출.
8개 언어 지원: KO, JA, ZH, EN, DE, FR, VI, RU.

## Tech Stack
- **Framework**: Flutter (Android + Web)
- **번역**: OpenAI GPT (5.4-nano ~ 5.4, 설정에서 선택)
- **TTS**: OpenAI gpt-4o-mini-tts / flutter_tts (기기 내장 fallback)
- **STT**: record + Whisper API (OpenAI gpt-4o-mini-transcribe)
- **Realtime**: flutter_webrtc + OpenAI Realtime API (WebRTC)
- **보안**: flutter_secure_storage (Android 키스토어)
- **프롬프트**: lib/prompts.dart에 중앙 관리

## Architecture

```
[Ping-Pong 모드]  record → Whisper API → OpenAI GPT → gpt-4o-mini-tts
[Realtime 모드]   WebRTC → OpenAI Realtime API (VAD+번역+TTS 일체) → WebRTC
```

### File Structure
```
lib/
  main.dart                    # 앱 진입점, API 키 관리
  prompts.dart                 # 전역 프롬프트 (번역, AI 어시스턴트, TTS, Realtime)
  models/
    language.dart              # 8개 언어 모델 (code, name, sttLocale, ttsLocale)
  screens/
    translator_screen.dart     # 분할 화면 UI, 모든 모드 통합
  services/
    openai_service.dart        # OpenAI API (번역, TTS, STT, AI 어시스턴트)
    speech_service.dart        # 기기 내장 STT/TTS (legacy fallback)
    realtime_service.dart      # WebRTC Realtime API
  widgets/
    chat_bubble.dart           # 채팅 버블 (SelectableText, AI 마크다운)
    settings_sheet.dart        # 설정 시트 (DraggableScrollableSheet)
```

## Key Design Decisions

### 파이프라인 모드
Ping-Pong / Realtime 선택. 브라우저 모드는 legacy로 자동 마이그레이션.

### 번역 톤 모드
기본/예의/친구 3단계. ToneMode enum으로 prompts.dart에서 관리.
- 기본: 원문 톤 유지
- 예의: 자연스러운 공손체 (ko: -요체, ja: です/ます)
- 친구: 자연스러운 반말

### Realtime 프롬프트 설계
- "stateless function" 프레이밍 (temperature 0.8 고정 환경)
- "incapable of" 금지 표현 (NEVER보다 효과적)
- Few-shot 5개 data channel 주입 (양방향, 함정질문 포함)
- 지식 차단 + echo/meta-commentary 방지
- Closing reinforcement (recency bias 활용)

### 방향별 오디오 제어 (Realtime)
- 양쪽 TTS 모두 ON → create_response: true (자동)
- 한쪽만 OFF → create_response: false, 입력 언어 감지 후 수동 response.create
- modalities: ['text'] (음성 없음) 또는 기본 (음성+텍스트) 분기
- session.update로 런타임 TTS 토글 변경 반영

### API 키 관리
- `--dart-define`으로 빌드 시 내장 (개인용, 편의)
- 또는 앱에서 직접 입력 → flutter_secure_storage에 암호화 저장

### 음성 인식 묵음 감지
- Ping-Pong 모드: record의 onAmplitudeChanged로 dB 기반 감지
- Realtime 모드: OpenAI server_vad (서버 측)

### TTS 플랫폼 차이
- Android: flutter_tts rate * 0.5 보정 (내부 2x 곱셈)
- Web: rate 그대로
- Realtime: API 내장 TTS (coral/ash/sage/verse)

### Realtime 세션 관리
- session.created 이벤트까지 대기 후 활성화 (Completer)
- input_audio_transcription: whisper-1 (원문 transcript 확보)
- AI hold 모드: AI 어시스턴트 활성 시 Realtime 마이크 뮤트
- Watchdog timer (5s): 영구 뮤트 방지

## Development

```bash
flutter pub get
flutter run -d chrome  # 웹
flutter run -d <device>  # Android

# 릴리즈 빌드
flutter build apk --release --split-per-abi
flutter build web --release
```

## Conventions
- 프론트엔드 전용 (서버 없음)
- OpenAI API 직접 호출
- SharedPreferences: 설정 저장
- flutter_secure_storage: API 키 저장 (Android)
- 비동기 stop은 await로 직렬화 (_stopAll)
- setState 전 mounted 체크
- 프롬프트는 prompts.dart에서만 관리
- 모델 목록은 settings_sheet.dart의 _chatModels에서 단일 관리
