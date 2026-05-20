# 다국어 실시간 통역 앱

다국어 실시간 양방향 통역 앱.
Flutter 기반으로 Android 앱과 웹 브라우저에서 동작합니다.
별도 서버 없이 앱에서 OpenAI API를 직접 호출하는 구조입니다.

**지원 언어**: 한국어, 일본어, 중국어, 영어, 독일어, 프랑스어, 베트남어, 러시아어

---

## 주요 기능

### 대면 화면
화면을 상하로 나눠 서로 마주 보고 대화할 수 있습니다.
- **대면**: 위쪽 절반을 180도 회전해 상대방이 읽기 쉬운 기존 뷰
- **대면 v2**: 큰 마이크 버튼, 얇은 중앙 구분선, 간결한 언어 표기 중심의 실험 뷰
- **단방향**: 한 사람이 전체 대화 흐름을 보는 일반 채팅 뷰
- 언어 표기는 읽는 사람 기준으로 현지화됩니다. 예: 내 화면은 `한국어 <-> 일본어`, 상대 화면은 `日本語 <-> 韓国語`

### 2가지 모드

#### 1. Ping-Pong 모드
음성 인식, 번역, 음성 합성을 모두 OpenAI API로 처리합니다.
- 음성 인식: 마이크 → 녹음 → OpenAI Whisper API (gpt-4o-mini-transcribe)
- 번역: OpenAI GPT (5.5 / 5.4 / 5.4-mini / 5.4-nano)
- 음성 출력: OpenAI gpt-4o-mini-tts
- 묵음 감지: 주변 소음 레벨(dB) 기반 자동 중지

#### 2. Realtime 모드
OpenAI Realtime API를 사용한 실시간 음성-음성 통역입니다.
- 음성 인식 + 번역 + 음성 출력이 하나의 WebRTC 세션에서 처리
- 발화 종료 자동 감지 (서버 VAD)
- Realtime 2.0 (`gpt-realtime-2`) 지원
- **방향별 TTS 제어**: 소스→타깃, 타깃→소스 음성 출력을 개별 on/off
- **프롬프트 강화**: few-shot 예제, 지식 차단, echo/meta-commentary 방지
- **원문 표시**: Whisper transcript로 실제 발화 내용 표시
- **후처리 분리**: 역번역, 발음 표기, 언어 보정은 별도 Chat Completions 모델로 처리
- TTS를 끄면 Realtime 세션을 텍스트 출력 중심으로 구성해 지연을 줄입니다

### 번역 톤 모드
- **기본**: 원문 톤 유지
- **예의**: 자연스러운 공손체 (존댓말, です/ます, vous 등)
- **친구**: 자연스러운 반말

### AI 어시스턴트
대화 중 궁금한 것을 AI에게 질문할 수 있습니다.
- 마이크 옆 AI 버튼으로 전환
- 대화 맥락 참조 가능
- 마크다운 렌더링 지원

### 텍스트 입력
마이크 외에 키보드로 직접 텍스트를 입력할 수 있습니다.
언어는 글자의 유니코드 범위로 자동 감지합니다.

### 번역 결과 표시
- **원문**: 실제 발화 내용 (Whisper transcript)
- **번역문**: 번역된 텍스트 (크게 표시)
- **역번역** (괄호): 번역 품질 확인용
- **발음 표기**: 한국어 사용자를 위한 발음 보조 표시 옵션
- 번역문 영역을 탭하면 바로 클립보드에 복사됩니다
- 모든 텍스트는 길게 눌러 **선택/복사** 가능

---

## 설정 항목

| 설정 | 설명 | 적용 모드 |
|---|---|---|
| **모드** | Ping-Pong / Realtime | 전체 |
| **화면** | 대면 / 대면 v2 / 단방향 | 전체 |
| **번역 모델** | GPT 5.5 / 5.4 / 5.4-mini / 5.4-nano | Ping-Pong |
| **RT 모델** | Realtime mini / standard / 1.5 / 2.0 | Realtime |
| **RT 후처리 모델** | Realtime 역번역, 발음, 언어 후처리용 Chat Completions 모델 | Realtime |
| **번역 톤** | 기본 / 예의 / 친구 | 전체 |
| **소스 TTS** | 소스 언어 음성 출력 on/off | 전체 |
| **타깃 TTS** | 타깃 언어 음성 출력 on/off | 전체 |
| **RT 음성** | Realtime 음성 선택 (coral/ash/sage/verse) | Realtime |
| **역번역** | 각 언어 방향의 역번역 표시 on/off | 전체 |
| **한국어 발음 표시** | 한국어 기준 발음 보조 표시 | 전체 |
| **크기** | 텍스트 표시 크기 (12~32px) | 전체 |
| **묵음** | 묵음 감지 시간 (1s~7s / OFF) | Ping-Pong |
| **소음** | 묵음 판정 기준 (-20dB~-80dB) | Ping-Pong |
| **VAD 감도** | Realtime VAD 감도 (0.3~0.95) | Realtime |
| **대화 기록 삭제** | Realtime 세션에 남은 대화 아이템 삭제 | Realtime |
| **Few-shot 주입** | Realtime 번역 품질 보정 예시 주입 | Realtime |
| **AI 모델** | AI 어시스턴트용 모델 선택 | 전체 |
| **키초기화** | 저장된 API 키 삭제 | 전체 |

---

## 설치 및 실행

### 사전 요구사항

- **Flutter SDK** 3.x 이상
- **OpenAI API Key**
- **Android Studio** (Android APK 빌드 시) 또는 **Chrome** (웹 실행 시)

### 실행

```bash
flutter pub get
flutter run -d chrome                                    # 웹
flutter run -d chrome --dart-define=OPENAI_API_KEY=...   # 키 내장, 개인용
flutter run                                               # Android
```

### 빌드

```bash
# APK (split-per-abi 권장)
flutter build apk --release --split-per-abi
flutter build apk --release --split-per-abi --dart-define=OPENAI_API_KEY=...

# 웹
flutter build web --release
```

---

## API 키 관리

- **앱 내 입력**: 첫 실행 시 API 키 입력 → Android: 키스토어 암호화 저장, Web: 로컬 스토리지
- **빌드 내장**: `--dart-define=OPENAI_API_KEY=...`로 빌드 시 내장할 수 있습니다. 개인용 APK에만 사용하세요
- **초기화**: 설정 > 키초기화

## 보안 및 커밋 주의사항

- `.env`, `.env.flutter`, `.telegram.env`, `.mcp.json`은 저장소에 커밋하지 않습니다.
- `build/`, `.dart_tool/`, Android Gradle 산출물, `*.apk`는 커밋하지 않습니다.
- API 키를 `--dart-define`으로 넣어 만든 APK나 웹 빌드는 키가 포함된 산출물이므로 배포 저장소에 올리지 않습니다.
- 커밋 전에는 `git status --short --ignored`로 ignored 상태를 확인하고, `git diff --cached`에 키/토큰/로컬 경로가 없는지 확인합니다.

---

## 프로젝트 구조

```
lib/
  main.dart                    # 앱 시작점, API 키 관리
  prompts.dart                 # 전역 프롬프트 (번역, AI, TTS, Realtime)
  models/
    language.dart              # 8개 언어 모델
  screens/
    translator_screen.dart     # 메인 화면 (분할 뷰, 모든 모드)
  services/
    openai_service.dart        # OpenAI API (번역, TTS, STT, AI)
    speech_service.dart        # 기기 내장 STT/TTS (fallback)
    realtime_service.dart      # WebRTC Realtime API
  widgets/
    chat_bubble.dart           # 채팅 말풍선
    settings_sheet.dart        # 설정 시트
```

## 사용 기술

| 구성 요소 | 기술 | 용도 |
|---|---|---|
| Flutter | 3.x | 크로스플랫폼 (Android + Web) |
| OpenAI GPT | 5.5 / 5.4 series | 다국어 번역 |
| OpenAI Chat Completions | 5.5 / 5.4 series | 역번역, 발음 표기, AI 어시스턴트 |
| OpenAI TTS | gpt-4o-mini-tts | 음성 합성 |
| OpenAI STT | gpt-4o-mini-transcribe | 음성 인식 |
| OpenAI Realtime | gpt-realtime-mini/standard/1.5/2 | 실시간 음성 통역 |
| flutter_webrtc | | WebRTC 연결 |
| record | | 오디오 녹음 |
| audioplayers | | 오디오 재생 |
| flutter_secure_storage | | API 키 암호화 (Android) |
| flutter_markdown | | AI 응답 마크다운 렌더링 |

---

## 알려진 제한사항

1. **Latin+Latin 언어 쌍** (EN↔DE 등)은 유니코드 기반 언어 감지 불가 → 소스 언어 기본값으로 fallback
2. **Realtime temperature 고정** → 프롬프트와 톤 지시로 제어
3. **Realtime 모델/톤/TTS 변경** → 세션 재시작 필요 (설정 변경 시 안내 표시)
4. **빌드 내장 API 키** → APK나 웹 산출물을 공유하면 키도 함께 노출될 수 있음

---

## License

MIT License. See [LICENSE](LICENSE).
