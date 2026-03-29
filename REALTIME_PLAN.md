# Realtime API Integration Plan

## 현재 vs Realtime 비교

```
[현재 - 핑퐁 모드]
마이크 → Browser STT → POST /api/translate (GPT-4.1-mini) → POST /api/tts (gpt-4o-mini-tts) → 스피커
         (각 단계 대기)    (각 단계 대기)                      (각 단계 대기)

[Realtime 모드]
마이크 → WebRTC → OpenAI Realtime API (gpt-4o-mini-realtime-preview) → WebRTC → 스피커
         (직통, 실시간)    (STT + 번역 + TTS 한번에)                    (직통, 실시간)
```

핵심 차이: 핑퐁은 3단계 API를 순차 호출. Realtime은 음성이 들어가면 번역된 음성이 바로 나옴.

## 구현 방식

### Backend (최소 변경)
- `POST /api/realtime/session` 엔드포인트 1개 추가
- 역할: OpenAI에 임시 토큰(ephemeral key)을 요청해서 프론트에 전달
- 백엔드는 **오디오를 전혀 안 만짐** — 브라우저 ↔ OpenAI 직통 WebRTC

```python
# main.py에 추가
@app.post("/api/realtime/session")
async def create_realtime_session(req: RealtimeSessionRequest):
    response = httpx.post(
        "https://api.openai.com/v1/realtime/sessions",
        headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
        json={
            "model": "gpt-4o-mini-realtime-preview",
            "voice": req.voice,
            "instructions": REALTIME_SYSTEM_PROMPT,
            "input_audio_transcription": {"model": "whisper-1"},
            "modalities": ["text", "audio"],
            "turn_detection": {
                "type": "server_vad",
                "threshold": 0.5,
                "silence_duration_ms": 800,
            },
        },
    )
    return response.json()  # { client_secret, session_id, ... }
```

### Frontend (WebRTC)

```
1. 마이크 버튼 클릭 (Realtime 모드)
2. POST /api/realtime/session → 임시 토큰 받음
3. RTCPeerConnection 생성
4. getUserMedia()로 마이크 스트림 연결
5. DataChannel로 서버 이벤트 수신
6. SDP offer 생성 → OpenAI에 전송 → SDP answer 수신
7. 연결 완료 — 말하면 바로 번역 음성 출력
```

### System Prompt (Realtime용)

```
You are a real-time Korean-Japanese interpreter.

RULES:
1. When you hear Korean, respond ONLY with the Japanese translation.
2. When you hear Japanese, respond ONLY with the Korean translation.
3. Translate naturally as a warm, friendly interpreter.
4. NEVER add commentary, questions, or explanations. Output ONLY the translation.

META-INSTRUCTION (Korean input only):
When Korean contains ~해줘, ~물어봐, ~말해줘, ~전해줘:
Extract the INTENT and translate that intent.
"화장실이 어딨는지 물어봐줘" → speak "トイレはどこですか？"
"고맙다고 전해줘" → speak "ありがとうございます"
```

## 사용자 경험 차이

| | 핑퐁 모드 (기존) | Realtime 모드 |
|---|---|---|
| 지연 | 3~5초 (STT→번역→TTS) | ~1초 이내 |
| 대화 흐름 | 말하기→기다리기→듣기 | 거의 동시통역 |
| 턴 전환 | 수동 (버튼 클릭) | 자동 (묵음 감지) |
| 음성 품질 | gpt-4o-mini-tts (고품질) | Realtime 내장 TTS (다를 수 있음) |
| 텍스트 표시 | 번역 후 바로 표시 | 음성과 함께 점진적 표시 |
| 비용 | 저렴 (3개 API 호출) | 상대적으로 비쌈 (초당 과금) |
| 메타 지시어 | 정확 (텍스트 기반 프롬프트) | 덜 정확할 수 있음 |

## UI 변경

### STT 드롭다운
```
현재: [Browser ▾] [OpenAI ▾]
변경: [일반 ▾] [Realtime ▾]
```
- "일반" = 기존 핑퐁 (Browser STT + translate + TTS)
- "Realtime" = WebRTC 실시간 통역

### Realtime 모드일 때
- 마이크 버튼 = 세션 시작/종료 (한번 누르면 세션 시작, 대화 지속, 다시 누르면 종료)
- 묵음 타임아웃/TTS on-off/음성 선택 → 비활성화 (Realtime API가 자체 관리)
- 마이크 언어 토글(KO/JA) → 불필요 (자동 감지)
- 양쪽 마이크 중 하나만 세션 시작하면, 그 세션에서 양쪽 언어 모두 처리

### 텍스트 표시
- DataChannel 이벤트로부터:
  - `input_audio_transcription.completed` → 원문 (내가 한 말)
  - `response.audio_transcript.done` → 번역문 (AI가 번역한 말)
- 이 두 개를 합쳐서 기존 chat bubble 형태로 표시

## 구현 순서

### Step 1: Backend 엔드포인트
- `prompts.py`에 `REALTIME_SYSTEM_PROMPT` 추가
- `main.py`에 `/api/realtime/session` 추가
- `httpx` 의존성 추가
- curl로 토큰 생성 테스트

### Step 2: Frontend WebRTC 핵심
- `startRealtimeSession()` / `stopRealtimeSession()` 구현
- WebRTC 연결 + 오디오 입출력
- DataChannel 이벤트 파싱
- 마이크 버튼 연동

### Step 3: 텍스트 표시 연동
- DataChannel 이벤트 → chat bubble 생성
- 양쪽 뷰(chatContainer + chatMirror) 동기화
- `detectLang()`으로 방향 판별

### Step 4: UI 정리
- Realtime 모드 시 불필요한 설정 숨기기
- 연결 상태 표시 (연결 중 / 활성 / 종료)
- 모드 전환 시 기존 세션 정리

### Step 5: 에러 처리
- 연결 실패 → 일반 모드로 fallback
- 세션 만료 → 자동 재연결 또는 안내
- 오디오 피드백 루프 방지

## 리스크

### 1. 오디오 피드백 루프
스피커에서 나온 번역 음성을 마이크가 다시 잡아서 무한 번역될 수 있음.
→ WebRTC 에코 캔슬링이 기본 지원. 실기기 테스트 필수.

### 2. 음성 품질 차이
Realtime API의 TTS가 gpt-4o-mini-tts보다 자연스럽지 않을 수 있음.
→ 테스트 후 판단. 핑퐁 모드가 백업.

### 3. 비용
Realtime은 연결 시간 기반 과금. 장시간 세션 = 높은 비용.
→ 세션 타이머 표시, 일정 시간 후 자동 종료 옵션.

### 4. 메타 지시어
음성 기반이라 텍스트 프롬프트보다 메타 지시어 감지가 덜 정확할 수 있음.
→ 정확성이 중요하면 핑퐁 모드 사용 권장.

### 5. 두 사람 구분 불가
하나의 마이크로 두 사람이 말하면 누가 한국어 화자인지 일본어 화자인지 구분이 어려울 수 있음.
→ Realtime API가 언어를 자동 감지하므로 대부분 동작하지만, 한국어로 일본어 단어를 말하는 경우 혼동 가능.

## 파일 변경 목록

| 파일 | 변경 내용 |
|---|---|
| `prompts.py` | `REALTIME_SYSTEM_PROMPT` 추가 |
| `main.py` | `/api/realtime/session` 엔드포인트 추가 |
| `requirements.txt` | `httpx` 추가 |
| `static/index.html` | STT 드롭다운 → "일반/Realtime" 변경 |
| `static/app.js` | WebRTC 로직, DataChannel 핸들링, 모드 전환 로직 |
| `static/style.css` | Realtime 모드 상태 표시 스타일 |
