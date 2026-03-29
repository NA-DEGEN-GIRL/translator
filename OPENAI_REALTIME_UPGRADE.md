# OpenAI-Only Realtime Upgrade Notes

## 결론

이 앱은 OpenAI만으로도 충분히 "실시간 통역기"에 가까운 수준까지 끌어올릴 수 있다.

다만 현재 구조인 `Web Speech API -> /api/translate -> /api/tts` 는 한계가 분명하다.
병목은 모델 자체보다 아키텍처에 더 가깝다.

- 현재 구조의 문제
  - 브라우저 음성 인식 품질이 환경 의존적이다.
  - 음성 인식, 번역, TTS가 각각 따로 놀아서 지연이 누적된다.
  - 턴 전환, 끼어들기, 중간 상태 제어가 약하다.
  - 브라우저별 재생 안정성이 흔들린다.

- OpenAI-only로 개선 가능한 방향
  - `Realtime API + gpt-realtime` 로 speech-to-speech 경로를 만든다.
  - 또는 `OpenAI STT + 번역 + OpenAI TTS` 조합으로 현재 UI를 유지하면서 품질을 높인다.

## 추천안

### 1. 권장안: Realtime API

가장 통역기답게 만들려면 `Realtime API + gpt-realtime + WebRTC` 가 맞다.

- 장점
  - 가장 낮은 지연시간 기대치
  - 음성 입력과 음성 출력을 한 세션에서 처리 가능
  - 실시간 대화형 UX에 적합
  - 현재 구조보다 턴 관리가 자연스럽다

- 적합한 경우
  - 사용자가 "말하면 거의 바로 상대 언어로 들려야 하는" 경험을 원할 때
  - 브라우저에서 대면 통역 UX를 만들 때

- 유의점
  - 현재 바닐라 JS 구조보다 세션 관리가 복잡해진다
  - 프론트엔드 이벤트 설계를 다시 잡아야 한다

## 2. 차선안: OpenAI STT + 번역 + TTS

현재 UI를 많이 바꾸고 싶지 않다면 다음 조합이 현실적이다.

- STT: `gpt-4o-transcribe` 또는 `gpt-4o-mini-transcribe`
- 번역: 현재의 번역 호출 유지
- TTS: `gpt-4o-mini-tts`

장점은 구현이 단순하고, 원문/번역문을 화면에 안정적으로 남기기 쉽다는 점이다.
대신 speech-to-speech direct path보다는 지연시간이 더 길 가능성이 높다.

## 현재 프로젝트 기준 판단

이 프로젝트에서 OpenAI만으로도 충분한 이유:

- 이미 번역과 TTS를 OpenAI로 사용 중이다.
- 가장 약한 부분은 `Web Speech API` 기반 STT다.
- 즉시 체감되는 개선은 STT 교체만으로도 발생할 가능성이 높다.
- 최종적으로 Realtime API까지 가면 현재보다 훨씬 자연스러운 통역 UX를 만들 수 있다.

즉, 외부 벤더를 섞기 전에 OpenAI-only로 먼저 한 번 정리하는 것이 합리적이다.

## 단계별 전환안

### Phase 1. 최소 변경

목표: 현재 구조는 유지하고, 품질이 낮은 부분만 교체한다.

- `Web Speech API` 제거
- 서버 또는 브라우저 업로드 경로에서 OpenAI 전사 API 사용
- 현재 `/api/translate`, `/api/tts` 구조는 유지
- 기존 대화 버블 UI는 그대로 사용

예상 효과:

- 음성 인식 품질 개선
- 브라우저 의존성 감소
- 디버깅 용이성 증가

### Phase 2. 준실시간

목표: 지연을 더 줄이고 상태 관리를 정리한다.

- 마이크 입력을 짧은 청크로 나눠 전사
- 중간 전사 결과와 최종 전사 결과를 분리 표시
- 번역 요청 중 중복 입력 차단
- 양쪽 마이크 상호 배타 처리

예상 효과:

- 실제 사용감이 더 빨라짐
- 동시 입력 꼬임 감소
- 사용자 혼란 감소

### Phase 3. Realtime 전환

목표: speech-to-speech 통역기로 재구성한다.

- `Realtime API` 세션 도입
- 브라우저는 `WebRTC` 기반 연결
- 텍스트 자막은 보조 정보로 표시
- 음성 출력은 세션에서 직접 재생
- turn detection, interruption, silence handling 재설계

예상 효과:

- 가장 자연스러운 실시간 통역 UX
- 현재 구조 대비 지연 감소
- 대면 통역 앱다운 경험 확보

## 권장 구현 순서

1. `Web Speech API` 의존성 제거
2. 마이크 동시 사용 방지
3. 서버 예외 처리 강화
4. TTS 재생 경로 단순화
5. 이후 `Realtime API` 로 전환

이 순서가 맞는 이유는, 지금 당장 가장 취약한 부분이 STT와 상태 경쟁이기 때문이다.
Realtime으로 바로 가는 것도 가능하지만, 현재 코드 구조를 생각하면 한 번 중간 정리를 하고 가는 편이 리스크가 낮다.

## 이 프로젝트에 대한 최종 판단

- "OpenAI만으로 충분한가?" -> 예, 충분하다.
- "바로 체감될 만큼 좋아질 수 있는가?" -> 예, 특히 STT와 realtime 구조 전환에서 차이가 크다.
- "타사 API가 반드시 필요한가?" -> 아니다. 적어도 현재 단계에서는 아니다.

현재 앱은 모델보다 입출력 구조가 더 큰 제약이다.
따라서 우선순위는 "벤더 교체"가 아니라 "OpenAI 기능을 더 맞는 방식으로 쓰도록 구조를 바꾸는 것"이다.

## 참고 문서

- OpenAI Realtime guide: https://developers.openai.com/api/docs/guides/realtime-conversations
- OpenAI Realtime WebRTC guide: https://developers.openai.com/api/docs/guides/realtime-webrtc
- OpenAI `gpt-realtime`: https://developers.openai.com/api/docs/models/gpt-realtime
- OpenAI `gpt-4o-transcribe`: https://developers.openai.com/api/docs/models/gpt-4o-transcribe
- OpenAI `gpt-4o-mini-transcribe`: https://developers.openai.com/api/docs/models/gpt-4o-mini-transcribe
- OpenAI `gpt-4o-mini-tts`: https://developers.openai.com/api/docs/models/gpt-4o-mini-tts
