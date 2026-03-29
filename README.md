# KO⇄JA Translator

한국어-일본어 실시간 양방향 통역 앱.
Flutter 기반으로 Android 앱과 웹 브라우저에서 동작합니다.
별도 서버 없이 앱에서 OpenAI API를 직접 호출하는 구조입니다.

---

## 주요 기능

### 분할 화면 (Split View)
화면을 상하로 반으로 나눕니다.
- **위쪽 절반**: 상대방(일본어 화자)이 읽을 수 있도록 180도 회전된 뷰. 마이크 버튼과 간단한 안내문이 있습니다.
- **아래쪽 절반**: 내(한국어 화자) 뷰. 설정, 텍스트 입력, 마이크 버튼이 있습니다.
- **사용 방법**: 테이블에 폰을 놓으면 양쪽에서 동시에 대화 내용을 볼 수 있습니다.

### 3가지 모드

#### 1. 브라우저 모드
기기에 내장된 음성 인식(speech_to_text)과 음성 합성(flutter_tts)을 사용합니다.
번역만 OpenAI API를 호출하므로 API 비용이 가장 적습니다.
- 음성 인식: 마이크 버튼을 누르고 말하면 기기가 음성을 텍스트로 변환
- 번역: OpenAI GPT가 텍스트를 번역
- 음성 출력: 기기 내장 TTS가 번역 결과를 읽어줌
- 묵음 감지: 설정한 시간(1초~7초) 동안 말이 없으면 자동으로 번역 시작

#### 2. OpenAI 모드
음성 인식, 번역, 음성 합성을 모두 OpenAI API로 처리합니다.
기기 내장보다 인식 품질이 높지만 API 비용이 더 듭니다.
- 음성 인식: 마이크 버튼을 누르면 녹음 시작 → 다시 누르면 녹음 중지 → 녹음 파일을 OpenAI Whisper API로 전송
- 번역: OpenAI GPT가 텍스트를 번역
- 음성 출력: OpenAI gpt-4o-mini-tts가 자연스러운 음성으로 읽어줌
- 묵음 감지: 주변 소음 레벨(dB)을 측정하여 설정한 시간 동안 조용하면 자동 중지

#### 3. Realtime 모드
OpenAI Realtime API를 사용한 실시간 음성-음성 통역입니다.
마이크 버튼을 한 번 누르면 세션이 시작되고, 말하면 거의 바로 번역된 음성이 출력됩니다.
- 음성 인식 + 번역 + 음성 출력이 하나의 WebRTC 세션에서 동시에 처리
- 별도로 버튼을 누르지 않아도 AI가 발화 종료를 자동 감지 (VAD)
- 다시 마이크 버튼을 누르면 세션 종료
- **주의**: Realtime API 모델이 번역 대신 대화를 시도할 수 있음. 이 경우 모드를 바꿔서 사용하세요.

### 텍스트 입력
마이크 외에 키보드로 직접 텍스트를 입력할 수 있습니다.
한국어를 입력하면 자동으로 일본어로, 일본어를 입력하면 한국어로 번역됩니다.
언어는 글자의 유니코드 범위로 자동 감지합니다 (한글 / 히라가나·가타카나).

### 번역 결과 표시
- **원문**: 내가 말하거나 입력한 텍스트
- **번역문**: 번역된 텍스트 (크게 표시)
- **역번역** (괄호): 번역이 의도대로 됐는지 확인용 (Realtime 모드에서만, 원문이 없을 때)
- 모든 텍스트는 길게 눌러 **선택/복사** 가능

### 다시 듣기
각 번역 결과 옆의 스피커 아이콘을 누르면 번역문을 다시 읽어줍니다.
현재 선택된 모드에 맞는 TTS를 사용합니다.

---

## 설정 항목

설정은 기어(⚙) 아이콘을 눌러 열고 닫을 수 있습니다.

| 설정 | 설명 | 적용 모드 |
|---|---|---|
| **모드** | 브라우저 / OpenAI / RT (Realtime) | 전체 |
| **모델** | 번역에 사용할 GPT 모델 선택. 숫자가 클수록 고품질+고비용 | 브라우저, OpenAI |
| **RT 모델** | Realtime 모델 선택 (mini/std/1.5) | Realtime |
| **J (토글)** | 일본어 음성 출력 on/off. 초록 점 = on | 전체 |
| **JA 음성** | 일본어 TTS 음성 (남/여) | 전체 |
| **K (토글)** | 한국어 음성 출력 on/off | 전체 |
| **KO 음성** | 한국어 TTS 음성 (남/여) | 전체 |
| **크기** | 텍스트 표시 크기 (12~32px) | 전체 |
| **속도** | 기기 내장 TTS 읽기 속도 (0.5x~1.5x) | 브라우저 |
| **묵음** | 묵음 감지 시간 (1s~7s / OFF). 설정 시간 동안 조용하면 자동 번역 | 브라우저, OpenAI |
| **소음** | 묵음 판정 기준 (-20dB~-50dB). 시끄러운 환경에서는 '높음' 선택 | OpenAI |
| **감도** | Realtime VAD 감도 (0.3~0.95). 높을수록 큰 소리만 감지 | Realtime |
| **키초기화** | 저장된 API 키를 삭제하고 입력 화면으로 돌아감 | 전체 |

---

## 설치 및 실행

### 사전 요구사항

- **Flutter SDK** 3.x 이상 ([설치 가이드](https://docs.flutter.dev/get-started/install))
- **OpenAI API Key** ([발급 페이지](https://platform.openai.com/api-keys))
- **Android Studio** (Android APK 빌드 시) 또는 **Chrome** (웹 실행 시)

### 1. 소스 코드 다운로드

```bash
git clone https://github.com/NA-DEGEN-GIRL/translator.git
cd translator
```

### 2. 의존성 설치

```bash
flutter pub get
```

### 3. 실행

#### 웹에서 실행 (개발용)

```bash
# API 키를 앱에서 직접 입력하는 경우
flutter run -d chrome

# API 키를 빌드에 내장하는 경우 (개인용)
flutter run -d chrome --dart-define=OPENAI_API_KEY=여기에_키_입력
```

#### Android 기기에서 실행

USB로 Android 폰을 연결한 뒤:
```bash
flutter run
```

### 4. APK 빌드 (Android 설치 파일)

```bash
# 권장: API 키를 앱에서 입력하도록 (보안)
flutter build apk --release

# 또는: API 키를 APK에 내장 (개인용, 편리하지만 보안 약함)
flutter build apk --release --dart-define=OPENAI_API_KEY=여기에_키_입력
```

빌드된 파일 위치: `build/app/outputs/flutter-apk/app-release.apk`
이 파일을 폰에 전송하여 설치합니다 (설정에서 "알 수 없는 출처" 허용 필요).

### 5. 웹 빌드 (정적 파일 배포)

```bash
flutter build web --release
```

빌드 결과: `build/web/` 폴더
이 폴더를 웹 서버에 올리면 브라우저에서 접속 가능합니다.
단, 마이크 사용을 위해 **HTTPS**가 필요합니다 (localhost는 예외).

---

## API 키 관리

### 키 입력
앱을 처음 실행하면 API 키 입력 화면이 나타납니다.
[OpenAI Platform](https://platform.openai.com/api-keys)에서 발급받은 키를 입력하세요.

### 키 저장 방식
- **Android**: `flutter_secure_storage`를 사용하여 OS 키스토어에 암호화 저장
- **Web**: `SharedPreferences`에 저장 (브라우저 로컬 스토리지)

### 키 변경/초기화
설정(⚙)을 열고 맨 아래의 `키초기화`를 누르면:
1. "API 키를 초기화하시겠습니까?" 확인 대화상자가 나타남
2. 확인하면 저장된 키가 삭제되고 입력 화면으로 돌아감
3. 새 키를 입력하면 다시 사용 가능

### `--dart-define` 내장 키
`flutter build apk --dart-define=OPENAI_API_KEY=...`로 빌드하면 키가 APK에 포함됩니다.
이 경우 키 입력 화면 없이 바로 시작됩니다.
**주의**: APK를 디컴파일하면 키를 추출할 수 있으므로 공개 배포 시에는 사용하지 마세요.

---

## 비용 안내

이 앱은 OpenAI API를 사용하므로 사용량에 따라 과금됩니다.

| 항목 | 모델 | 대략적 비용 (1M 토큰당) |
|---|---|---|
| 번역 | gpt-5.4-nano (기본) | 입력 $0.20 / 출력 $1.25 |
| 번역 | gpt-5.4-mini | 입력 $0.75 / 출력 $4.50 |
| TTS | gpt-4o-mini-tts | 별도 과금 |
| STT | gpt-4o-mini-transcribe | 별도 과금 |
| Realtime | gpt-realtime-mini | 오디오 입력 $10 / 출력 $20 |

- **브라우저 모드**가 가장 저렴 (번역 API만 사용)
- **OpenAI 모드**는 STT + 번역 + TTS 모두 API 사용
- **Realtime 모드**는 연결 시간 동안 지속 과금

---

## 알려진 제한사항

1. **Realtime 모드에서 AI가 대화를 시도할 수 있음**
   Realtime API 모델이 번역 대신 질문에 대답하거나 대화를 이어가려 할 수 있습니다.
   프롬프트로 제한하고 있지만 100% 방지는 어렵습니다.

2. **브라우저 모드 첫 TTS가 씹힐 수 있음 (웹)**
   브라우저 `speechSynthesis` API의 첫 호출이 무시되는 경우가 있습니다.
   마이크 버튼이나 전송 버튼을 눌러 사용자 인터랙션을 발생시킨 후에는 정상 동작합니다.

3. **Android TTS 성별 선택이 정확하지 않을 수 있음**
   Android TTS 엔진은 음성 메타데이터에 성별 정보가 없어서 정확한 남/여 구분이 어렵습니다.

4. **웹에서 마이크 사용 시 HTTPS 필요**
   `localhost`를 제외하고, 브라우저에서 마이크(`getUserMedia`)를 사용하려면 HTTPS가 필요합니다.

5. **CJK 한자 언어 감지 한계**
   한자만으로 이루어진 텍스트는 일본어로 감지될 수 있습니다. 히라가나/가타카나가 포함되어야 일본어로 정확히 판별됩니다.

---

## 프로젝트 구조

```
translator/
├── lib/
│   ├── main.dart                      # 앱 시작점, API 키 관리
│   ├── screens/
│   │   └── translator_screen.dart     # 메인 화면 (분할 뷰, 설정, 모든 모드)
│   ├── services/
│   │   ├── openai_service.dart        # OpenAI API 호출 (번역, TTS, STT)
│   │   ├── speech_service.dart        # 기기 내장 음성 인식/합성
│   │   └── realtime_service.dart      # WebRTC Realtime API
│   └── widgets/
│       └── chat_bubble.dart           # 채팅 말풍선 위젯
├── android/                           # Android 네이티브 설정
├── web/                               # 웹 빌드 설정
├── pubspec.yaml                       # Flutter 의존성
├── CLAUDE.md                          # 개발 컨텍스트 (Claude Code용)
└── README.md                          # 이 파일
```

## 사용 기술

| 구성 요소 | 기술 | 용도 |
|---|---|---|
| Flutter | 3.x | 크로스플랫폼 프레임워크 (Android + Web) |
| OpenAI GPT | 4.1 / 5.4 | 한국어↔일본어 텍스트 번역 |
| OpenAI gpt-4o-mini-tts | | 자연스러운 음성 합성 |
| OpenAI Whisper | gpt-4o-mini-transcribe | 음성을 텍스트로 변환 |
| OpenAI Realtime API | gpt-realtime-mini/1.5 | 실시간 음성-음성 통역 |
| flutter_tts | | 기기 내장 음성 합성 |
| speech_to_text | | 기기 내장 음성 인식 |
| flutter_webrtc | | WebRTC 연결 (Realtime 모드) |
| record | | 오디오 녹음 (OpenAI STT) |
| audioplayers | | 오디오 파일 재생 (OpenAI TTS) |
| flutter_secure_storage | | API 키 암호화 저장 (Android) |
| shared_preferences | | 설정값 로컬 저장 |

---

## License

Private use.
