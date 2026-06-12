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
- **단방향**: 한 사람이 전체 대화 흐름을 보는 일반 채팅 뷰
- 대면 모드의 제목과 말풍선은 읽는 사람 기준으로 `나 <-> 상대` / `自分 <-> 相手`처럼 현지화됩니다.

### 2가지 모드

#### 1. Ping-Pong 모드
음성 인식, 번역, 음성 합성을 모두 OpenAI API로 처리합니다.
- 음성 인식: 마이크 → 녹음 → OpenAI Transcriptions API (gpt-4o-mini-transcribe 기본)
- 번역: OpenAI GPT (5.5 / 5.4 / 5.4-mini / 5.4-nano), reasoning effort 설정 가능
- 음성 출력: OpenAI gpt-4o-mini-tts
- 묵음 감지: 주변 소음 레벨(dB) 기반 자동 중지

#### 2. 실시간 통역 모드
Google Gemini Live Translate(`gemini-3.5-live-translate-preview`) 듀얼 세션 기반 자막 중심 통역입니다.
- 8개 언어 자유 선택 (KO↔JA 고정 아님)
- **수동 방향 턴**: 연결 버튼으로 두 세션을 일시정지 상태로 연결 → 방향 턴 마이크 2개(또는 이어폰)로 턴 시작. 한 번에 활성 방향 하나만 마이크를 열어 교차 오인을 차단
- 입력 원문은 `inputAudioTranscription`으로 즉시 말풍선에 표시(지연 체감 완화)
- 번역 음성 출력 토글 (기본 ON, turn 단위 PCM 재생)
- 역번역·발음 표기는 커밋된 세그먼트에 별도 OpenAI Chat Completions 후처리로 적용(독립 요청, 먼저 끝난 결과부터 표시)
- 기존 OpenAI Realtime(`gpt-realtime-translate`/WebRTC) 실시간 경로는 제거되었습니다

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
- **원문**: 실제 발화 내용 (STT transcript)
- **번역문**: 번역된 텍스트 (크게 표시)
- **역번역** (괄호): 번역 품질 확인용
- **발음 표기**: 한국어 사용자를 위한 발음 보조 표시 옵션
- 번역문 영역을 탭하면 바로 클립보드에 복사됩니다
- 모든 텍스트는 길게 눌러 **선택/복사** 가능

---

## 설정 항목

| 설정 | 설명 | 적용 모드 |
|---|---|---|
| **모드** | Ping-Pong / 실시간 통역 | 전체 |
| **화면** | 대면 / 단방향 | 전체 |
| **번역문 크기** | 번역 결과 본문 글자 크기, 설정창에서 즉시 반영 | 전체 |
| **보조 글자 크기** | 원문, 역번역, 발음 표기 글자 크기, 설정창에서 즉시 반영 | 전체 |
| **번역 모델** | GPT 5.5 / 5.4 / 5.4-mini / 5.4-nano | Ping-Pong |
| **번역 추론** | reasoning effort 기본값(미전송) / minimal / low / medium / high, 기본 low | Ping-Pong |
| **STT 모델** | gpt-4o-mini-transcribe / gpt-4o-transcribe / whisper-1 | Ping-Pong |
| **STT 힌트** | 음성 인식용 고유명사, 자주 나오는 표현 힌트 | Ping-Pong |
| **RT 모델** | gemini-3.5-live-translate-preview 고정 | 실시간 통역 |
| **번역 음성** | 실시간 통역 번역 음성 출력 on/off (기본 ON) | 실시간 통역 |
| **번역 톤** | 기본 / 예의 / 친구 | Ping-Pong |
| **소스 TTS** | 소스 언어 음성 출력 on/off | 전체 |
| **타깃 TTS** | 타깃 언어 음성 출력 on/off | 전체 |
| **역번역** | 각 언어 방향의 역번역 표시 on/off | 전체 |
| **한국어 발음 표시** | 한국어 기준 발음 보조 표시 | 전체 |
| **후처리 모델** | 역번역 / 발음 모델과 reasoning effort 개별 선택 | 전체 |
| **묵음** | 묵음 감지 시간 (1s~7s / OFF) | Ping-Pong |
| **소음** | 묵음 판정 기준 (-20dB~-80dB) | Ping-Pong |
| **백그라운드** | 실시간 통역 백그라운드 유지 시간 | 실시간 통역 |
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
flutter run -d chrome                                       # 웹 (키는 앱에서 입력)
flutter run -d chrome --dart-define-from-file=.env.flutter  # 키 내장, 개인용
flutter run                                                  # Android
```

### 빌드

```bash
# APK (split-per-abi 권장)
flutter build apk --release --split-per-abi
flutter build apk --release --split-per-abi --dart-define-from-file=.env.flutter

# 웹
flutter build web --release
flutter build web --release --dart-define-from-file=.env.flutter   # 키 내장, 개인용

# 웹 빌드 서빙 (예시)
python3 -m http.server 8090 --directory build/web
```

---

## API 키 관리

dart-define 키 (`.env.flutter.example` 참고 → `.env.flutter`로 복사해 사용):

| 키 | 용도 | 필수 |
|---|---|---|
| `OPENAI_API_KEY` | Ping-Pong 번역/STT/TTS + 역번역·발음 후처리 | 필수 |
| `GOOGLE_API_KEY` | 실시간 통역 (gemini-3.5-live-translate-preview) | 실시간 통역 사용 시 |
| `PINGPONG_WS_PROXY_URL` | Ping-Pong 웹 WS 프록시 | 선택 |

- **앱 내 입력**: 첫 실행 시 OpenAI 키 입력 → Android 키스토어 / Web 로컬스토리지. Google 키는 설정 시트에서 입력.
- **빌드 내장(개인용)**: `--dart-define-from-file=.env.flutter` 로 한 번에 주입. 키가 산출물에 포함되므로 개인용에만 사용.
- **초기화**: 설정 > API 키 초기화 / Gemini 키는 옆 삭제 버튼.

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
| OpenAI Chat Completions | 5.5 / 5.4 series | 번역, 역번역, 발음 표기, AI 어시스턴트 |
| OpenAI TTS | gpt-4o-mini-tts | 음성 합성 |
| OpenAI STT | gpt-4o-mini-transcribe / gpt-4o-transcribe / whisper-1 | 음성 인식 |
| Gemini Live Translate | gemini-3.5-live-translate-preview | 실시간 자막 통역 (WebSocket 듀얼 세션) |
| web_socket_channel | | Gemini Live WebSocket 직결 |
| record | | 오디오 녹음 |
| audioplayers | | 오디오 재생 |
| flutter_secure_storage | | API 키 암호화 (Android) |
| flutter_markdown | | AI 응답 마크다운 렌더링 |

---

## 알려진 제한사항

1. **Latin+Latin 언어 쌍** (EN↔DE 등)은 유니코드 기반 언어 감지 불가 → 소스 언어 기본값으로 fallback
2. **실시간 통역 방향** → 수동 턴(방향 버튼/이어폰으로 전환). 두 translate 세션이 자기 소스로 환각하고 dev API에 소스 고정이 없어 단일 마이크 완전 자동 감지는 미지원 (구글 번역앱도 전환 버튼 사용)
3. **실시간 통역 출력** → 자막 중심 + 번역 음성 토글(turn 단위 재생)
4. **비원어민 발음** → 흉내/모호 발음은 Gemini ASR이 오인할 수 있음 (모델 한계)
5. **빌드 내장 API 키** → APK나 웹 산출물을 공유하면 키도 함께 노출될 수 있음

---

## License

MIT License. See [LICENSE](LICENSE).
