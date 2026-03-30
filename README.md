# 다국어 실시간 통역 앱

다국어 실시간 양방향 통역 앱.
Flutter 기반으로 Android 앱과 웹 브라우저에서 동작합니다.
별도 서버 없이 앱에서 OpenAI API를 직접 호출하는 구조입니다.

**지원 언어**: 한국어, 일본어, 중국어, 영어, 독일어, 프랑스어, 베트남어, 러시아어

---

## 주요 기능

### 분할 화면 (Split View)
화면을 상하로 반으로 나눕니다.
- **위쪽 절반**: 상대방이 읽을 수 있도록 180도 회전된 뷰
- **아래쪽 절반**: 내 뷰. 설정, 텍스트 입력, 마이크 버튼
- **사용 방법**: 테이블에 폰을 놓으면 양쪽에서 동시에 대화 내용을 볼 수 있습니다

### 2가지 모드

#### 1. Ping-Pong 모드
음성 인식, 번역, 음성 합성을 모두 OpenAI API로 처리합니다.
- 음성 인식: 마이크 → 녹음 → OpenAI Whisper API (gpt-4o-mini-transcribe)
- 번역: OpenAI GPT (5.4-nano / 5.4-mini / 5.4)
- 음성 출력: OpenAI gpt-4o-mini-tts
- 묵음 감지: 주변 소음 레벨(dB) 기반 자동 중지

#### 2. Realtime 모드
OpenAI Realtime API를 사용한 실시간 음성-음성 통역입니다.
- 음성 인식 + 번역 + 음성 출력이 하나의 WebRTC 세션에서 처리
- 발화 종료 자동 감지 (서버 VAD)
- **방향별 TTS 제어**: 소스→타깃, 타깃→소스 음성 출력을 개별 on/off
- **프롬프트 강화**: few-shot 예제, 지식 차단, echo/meta-commentary 방지
- **원문 표시**: Whisper transcript로 실제 발화 내용 표시

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
- 모든 텍스트는 길게 눌러 **선택/복사** 가능

---

## 설정 항목

| 설정 | 설명 | 적용 모드 |
|---|---|---|
| **모드** | Ping-Pong / Realtime | 전체 |
| **번역 모델** | GPT 5.4-nano / 5.4-mini / 5.4 | Ping-Pong |
| **RT 모델** | Realtime mini / standard / 1.5 | Realtime |
| **번역 톤** | 기본 / 예의 / 친구 | 전체 |
| **소스 TTS** | 소스 언어 음성 출력 on/off | 전체 |
| **타깃 TTS** | 타깃 언어 음성 출력 on/off | 전체 |
| **RT 음성** | Realtime 음성 선택 (coral/ash/sage/verse) | Realtime |
| **크기** | 텍스트 표시 크기 (12~32px) | 전체 |
| **묵음** | 묵음 감지 시간 (1s~7s / OFF) | Ping-Pong |
| **소음** | 묵음 판정 기준 (-20dB~-50dB) | Ping-Pong |
| **VAD 감도** | Realtime VAD 감도 (0.3~0.95) | Realtime |
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
flutter run -d chrome --dart-define=OPENAI_API_KEY=...   # 키 내장
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
- **빌드 내장**: `--dart-define=OPENAI_API_KEY=...`로 빌드 시 내장 (개인용)
- **초기화**: 설정 > 키초기화

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
| OpenAI GPT | 5.4 series | 다국어 번역 |
| OpenAI TTS | gpt-4o-mini-tts | 음성 합성 |
| OpenAI STT | gpt-4o-mini-transcribe | 음성 인식 |
| OpenAI Realtime | gpt-realtime-mini/1.5 | 실시간 음성 통역 |
| flutter_webrtc | | WebRTC 연결 |
| record | | 오디오 녹음 |
| audioplayers | | 오디오 재생 |
| flutter_secure_storage | | API 키 암호화 (Android) |
| flutter_markdown | | AI 응답 마크다운 렌더링 |

---

## 알려진 제한사항

1. **Latin+Latin 언어 쌍** (EN↔DE 등)은 유니코드 기반 언어 감지 불가 → 소스 언어 기본값으로 fallback
2. **Realtime temperature 고정** (0.8) → 프롬프트로만 제어
3. **Realtime 톤/TTS 변경** → 세션 재시작 필요 (설정 변경 시 안내 표시)

---

## License

MIT License. See [LICENSE](LICENSE).
