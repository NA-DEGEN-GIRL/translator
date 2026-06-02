# Realtime Interpretation Boundary

The app keeps only two user-facing modes:

- `openai`: Ping-Pong mode using record -> OpenAI Transcriptions -> Chat
  translation -> TTS.
- `realtime_translate`: live subtitle interpretation using the dedicated OpenAI
  Realtime Translations path.

General `gpt-realtime-*` voice-agent sessions are no longer a product path for
translation in this app. They are optimized as realtime voice agents, not as a
deterministic interpreter. Existing saved values for removed live modes are
migrated to `realtime_translate`.

## Active Live Path

`RealtimeTranslationService` owns the active live path. It requests a client
secret from `/v1/realtime/translations/client_secrets`, connects with WebRTC,
and forwards translated transcript events into the chat UI.

The current product boundary is Korean <-> Japanese subtitle interpretation:

- the UI is push-to-talk: one button for source -> target and one button for
  target -> source;
- both translation sessions are warmed muted, and only the pressed direction
  sends mic audio;
- only translated transcript deltas are requested and rendered quickly;
- committed segments are stored as chat bubbles immediately from the realtime
  output;
- translated audio output is optional. In shared-earbud mode, source -> target
  audio is routed to the other ear and target -> source audio is routed to the
  local user's ear. Web uses per-session stereo panning; Android applies the
  current direction's pan to the native WebRTC output path, which matches the
  push-to-talk one-direction-at-a-time flow;
- back-translation and pronunciation are optional Chat Completions
  post-processing steps, issued as separate requests; live back-translation
  updates the bubble's original-text slot and does not use the separate
  back-translation slot;
- automatic language routing, REST fallback translation, Realtime voice-agent
  TTS, prompt injection, and VAD tuning are not exposed.

## Dormant Experiments

Some legacy service files may still exist while the app is being simplified.
Do not re-enable them from settings or new UI without an explicit product
decision.
