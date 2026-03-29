# Korean-Japanese Translator (Flutter)

## Project Overview
한국어-일본어 실시간 통역 앱. Flutter로 Android + Web 지원.
서버 불필요 — 앱에서 OpenAI API 직접 호출.

## Tech Stack
- **Framework**: Flutter (Android + Web)
- **번역**: OpenAI GPT (4.1-nano ~ 5.4, 설정에서 선택)
- **TTS**: OpenAI gpt-4o-mini-tts / flutter_tts (기기 내장)
- **STT**: speech_to_text (기기) / record + Whisper API (OpenAI)
- **Realtime**: flutter_webrtc + OpenAI Realtime API (WebRTC)
- **보안**: flutter_secure_storage (Android 키스토어)

## Architecture

```
[브라우저 모드]  speech_to_text → OpenAI GPT → flutter_tts
[OpenAI 모드]   record → Whisper API → OpenAI GPT → gpt-4o-mini-tts
[Realtime 모드]  WebRTC → OpenAI Realtime API → WebRTC
```

### File Structure
```
lib/
  main.dart                    # 앱 진입점, API 키 관리
  screens/
    translator_screen.dart     # 분할 화면 UI, 모든 모드 통합
  services/
    openai_service.dart        # OpenAI API (번역, TTS, STT)
    speech_service.dart        # 기기 내장 STT/TTS
    realtime_service.dart      # WebRTC Realtime API
  widgets/
    chat_bubble.dart           # 채팅 버블 (SelectableText)
```

## Key Design Decisions

### 파이프라인 모드
드롭다운으로 브라우저/OpenAI/Realtime 선택. 각 모드가 STT+번역+TTS 전체 파이프라인을 결정.

### API 키 관리
- `--dart-define`으로 빌드 시 내장 (개인용, 편의)
- 또는 앱에서 직접 입력 → flutter_secure_storage에 암호화 저장
- 키 초기화: 설정에서 삭제 후 입력 화면으로 이동

### 음성 인식 묵음 감지
- 브라우저 모드: speech_to_text의 pauseFor
- OpenAI 모드: record의 onAmplitudeChanged로 dB 기반 감지
- Realtime 모드: OpenAI VAD (서버 측)

### TTS 플랫폼 차이
- Android: flutter_tts rate * 0.5 보정 (내부 2x 곱셈)
- Web: rate 그대로
- Android에는 voice gender 메타데이터 없음 → index 기반 선택

### Realtime 제한
- 모델이 대화로 빠질 수 있음 (번역만 하도록 프롬프트 제한)
- VAD 감도 설정으로 소음 오인식 조절
- 번역 음성 재생 중 마이크 자동 뮤트

## Development

```bash
flutter pub get
flutter run -d chrome  # 웹
flutter run -d <device>  # Android

# 릴리즈 빌드
flutter build apk --release
flutter build web --release
```

## Conventions
- 프론트엔드 전용 (서버 없음)
- OpenAI API 직접 호출
- SharedPreferences: 설정 저장
- flutter_secure_storage: API 키 저장 (Android)
- 비동기 stop은 await로 직렬화 (_stopAll)
- setState 전 mounted 체크
