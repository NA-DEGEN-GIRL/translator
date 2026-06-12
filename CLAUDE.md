# Korean-Japanese Translator (Flutter)

## Project Overview
다국어 실시간 통역 앱. Flutter로 Android + Web 지원.
서버 불필요 — 앱에서 OpenAI / Google API 직접 호출.
8개 언어 지원: KO, JA, ZH, EN, DE, FR, VI, RU.

## Tech Stack
- **Framework**: Flutter (Android + Web)
- **번역(Ping-Pong)**: OpenAI GPT (5.4-nano ~ 5.4, 설정에서 선택)
- **TTS**: OpenAI gpt-4o-mini-tts / flutter_tts (기기 내장 fallback)
- **STT**: record + OpenAI Transcriptions API (gpt-4o-mini-transcribe 기본)
- **실시간 통역**: Google Gemini Live Translate (gemini-3.5-live-translate-preview) WebSocket
- **후처리(역번역/발음)**: OpenAI GPT (실시간/Ping-Pong 공용)
- **보안**: flutter_secure_storage (Android 키스토어) — OpenAI 키 + Google 키
- **프롬프트**: lib/prompts.dart에 중앙 관리

## Architecture

```
[Ping-Pong 모드]  record → OpenAI Transcriptions → OpenAI GPT → gpt-4o-mini-tts
[실시간 통역]     record(16kHz) → 2개 Gemini Live 세션 → translated transcript + audio
                  세션 a: target=target (source→target), 세션 b: target=source (target→source)
                  수동 턴: 활성 방향 세션만 마이크 open(나머지 muteMic) → 교차 오인 차단
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
    gemini_live_translate_service.dart # 실시간 통역 (Gemini Live, 세션당 1방향)
    realtime_audio_output.dart # PCM 재생/팬/부스트 (provider 무관, 공용)
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

### 실시간 통역 경계 (Gemini Live Translate 전용)
- 앱의 실시간 경로는 `gemini_live_translate_service.dart` (Gemini Live Translate)뿐입니다. OpenAI realtime(`gpt-realtime-translate`/WebRTC)은 삭제됨.
- **수동 방향 턴**: 연결 버튼(`lt-connect-button`)은 두 세션을 일시정지 상태로 연결만. 방향 턴 마이크 2개(`lt-turn-mic-a/b`)·이어폰으로 턴 시작. 한 번에 **활성 방향 하나만 마이크 open**(`_openLiveTranslateMic`가 비활성 세션 `muteMic(true)`+`setAudioAllowed(false)`) → 비활성 세션은 입력을 못 받아 환각·echo 자체가 없음. 전환은 `_switchLiveTranslateSessionAsync`(시작/일시정지/전환/재개).
- **자동 양방향 감지는 폐기**(translate 세션이 자기 소스로 환각 + dev API에 소스 고정 없음, 구글 번역앱도 전환버튼 사용). 중립 감지기·방향 락 코드 전부 제거.
- 이어폰: ping-pong과 동일 — 1탭=상대(target, b), 2탭=나(source, a), 3탭=일시정지.
- 캡처는 translator_screen이 16kHz mono PCM 스트림 1개를 두 세션에 fan-out(`appendPcm16`, 비활성은 muteMic로 자체 폐기). 세션별 독립 버퍼(`_LtBuffer`).
- echo 가드: 출력≈입력이면 폐기(`_isLiveTranslateEchoArtifact`).
- 입력 원문은 `inputAudioTranscription`으로 받아 말풍선 `original` 슬롯에 표시(지연 체감 완화). 역번역/발음은 Ping-Pong과 동일하게 후처리 모델 선택.
- 언어: 8개 전체 자유 선택 (KO↔JA 고정 아님). 음성 출력 토글(기본 ON) — turn 단위 PCM→WAV 재생.

### API 키 관리
- OpenAI 키(필수, Ping-Pong/후처리): `--dart-define OPENAI_API_KEY` 또는 앱 입력 → secure storage `openai_api_key`
- Google 키(선택, 실시간 통역): `--dart-define GOOGLE_API_KEY` 또는 설정 시트에서 입력 → secure storage `google_api_key`
- raw 키로 Gemini WebSocket 직결(`?key=`). WS는 CORS preflight 대상 아님 → Flutter Web도 직결.

### 음성 인식 묵음 감지
- Ping-Pong 모드: record의 onAmplitudeChanged로 dB 기반 감지
- 실시간 통역 모드: Gemini 서버측 VAD(자동) — 클라이언트 묵음 감지 불필요

### TTS 플랫폼 차이
- Android: flutter_tts rate * 0.5 보정 (내부 2x 곱셈)
- Web: rate 그대로
- 실시간 통역: 번역 음성을 turn 단위로 재생(toggle, 기본 ON). web=playBufferedAudio(Web Audio), Android=audioplayers BytesSource

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
