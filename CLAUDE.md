# Korean-Japanese Translator (Flutter)

## Project Overview
다국어 실시간 통역 앱. Flutter로 Android + Web 지원.
서버 불필요 — 앱에서 OpenAI API 직접 호출.
8개 언어 지원: KO, JA, ZH, EN, DE, FR, VI, RU.

## Tech Stack
- **Framework**: Flutter (Android + Web)
- **번역**: OpenAI GPT (5.4-nano ~ 5.4, 설정에서 선택)
- **TTS**: OpenAI gpt-4o-mini-tts / flutter_tts (기기 내장 fallback)
- **STT**: record + OpenAI Transcriptions API (gpt-4o-mini-transcribe 기본)
- **실시간 통역**: flutter_webrtc + OpenAI Realtime Translations
- **보안**: flutter_secure_storage (Android 키스토어)
- **프롬프트**: lib/prompts.dart에 중앙 관리

## Architecture

```
[Ping-Pong 모드]  record → OpenAI Transcriptions → OpenAI GPT → gpt-4o-mini-tts
[실시간 통역]     OpenAI Realtime Translations → translated transcript stream
```

### File Structure
```
lib/
  main.dart                    # 앱 진입점, API 키 관리
  prompts.dart                 # 전역 프롬프트 (번역, AI 어시스턴트, TTS)
  models/
    language.dart              # 8개 언어 모델 (code, name, sttLocale, ttsLocale)
  screens/
    translator_screen.dart     # 분할 화면 UI, 모든 모드 통합
  services/
    openai_service.dart        # OpenAI API (번역, TTS, STT, AI 어시스턴트)
    speech_service.dart        # 기기 내장 STT/TTS (legacy fallback)
    realtime_translation_service.dart # 실시간 통역 API
  widgets/
    chat_bubble.dart           # 채팅 버블 (SelectableText, AI 마크다운)
    settings_sheet.dart        # 설정 시트 (DraggableScrollableSheet)
```

## Key Design Decisions

### 파이프라인 모드
Ping-Pong / 실시간 통역 선택. 브라우저, 일반 Realtime, 방향 Realtime, Google 통역 모드는 legacy로 자동 마이그레이션.

Ping-Pong은 번역 모델 reasoning effort, STT 모델/힌트, 후처리 역번역/발음 모델과 reasoning effort를 설정에서 선택한다. 감지 모델은 사용자 옵션으로 노출하지 않는다. 역번역과 발음 표기는 같은 JSON 후처리 요청으로 묶지 않고 독립 요청으로 처리하며, 먼저 끝난 결과부터 말풍선에 반영한다.

### 번역 톤 모드
기본/예의/친구 3단계. ToneMode enum으로 prompts.dart에서 관리.
- 기본: 원문 톤 유지
- 예의: 자연스러운 공손체 (ko: -요체, ja: です/ます)
- 친구: 자연스러운 반말

### 실시간 통역 경계
- 일반 `gpt-realtime-*` 음성 에이전트 세션으로 번역기를 만들지 않습니다.
- 앱에서 노출하는 실시간 경로는 `realtime_translation_service.dart`의 실시간 번역 전용 API입니다.
- 실시간 통역은 현재 한국어↔일본어 자막 중심 흐름으로 고정합니다.

### API 키 관리
- `--dart-define`으로 빌드 시 내장 (개인용, 편의)
- 또는 앱에서 직접 입력 → flutter_secure_storage에 암호화 저장

### 음성 인식 묵음 감지
- Ping-Pong 모드: record의 onAmplitudeChanged로 dB 기반 감지
- 실시간 통역 모드: 번역 전용 스트림 이벤트를 사용

### TTS 플랫폼 차이
- Android: flutter_tts rate * 0.5 보정 (내부 2x 곱셈)
- Web: rate 그대로
- 실시간 통역: 현재 자막 중심, 일반 Realtime 음성 에이전트식 TTS는 비활성화

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
