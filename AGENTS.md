# AGENTS.md

## Project Overview

This is a Flutter/Dart real-time translation app for Android and Web. The app calls OpenAI APIs directly from the client for Chat translation, STT, TTS, and Realtime WebRTC/WebSocket flows. Main entrypoints are `lib/main.dart`, `lib/screens/translator_screen.dart`, `lib/services/*`, `lib/prompts.dart`, and the widget files under `lib/widgets/`.

## Commands

- Install dependencies: `flutter pub get`
- Run web app: `flutter run -d chrome`
- Run with a built-in private key for local personal testing only: `flutter run -d chrome --dart-define=OPENAI_API_KEY=...`
- Format: `dart format lib test`
- Format check: `dart format --output=none --set-exit-if-changed lib test`
- Analyze: `flutter analyze`
- Test: `flutter test`
- Build web: `flutter build web --release`
- Build APK: `flutter build apk --release --split-per-abi`

Android build/run commands require a local Android SDK and device or emulator. Do not treat Android build failures from a missing SDK as code failures.

## Code Style

- Follow `analysis_options.yaml` and the default Flutter formatter.
- Keep prompts centralized in `lib/prompts.dart`; do not scatter model instructions through UI code.
- Keep supported language metadata in `lib/models/language.dart`.
- Keep model option lists in `lib/widgets/settings_sheet.dart` unless a broader model registry is intentionally introduced.
- Prefer existing service boundaries: `OpenAIService` for REST calls, `RealtimeService` for WebRTC Realtime sessions, and `RealtimePostProcessWsService` for Realtime WebSocket post-processing.
- `lib/screens/translator_screen.dart` is the highest-conflict file. Keep edits narrow, preserve mounted checks around async UI updates, and avoid unrelated refactors there.
- Preserve conditional platform boundaries in `lib/services/realtime_ws_channel*.dart`.

## Testing

- Add or update tests under `test/` for behavior changes when practical.
- Prefer unit/widget tests that do not call external OpenAI APIs.
- Good low-risk targets are prompt rendering, language labels, direction decisions, post-process JSON parsing, and API-key-screen behavior.
- Run `flutter test` before handoff for nontrivial changes. Run `flutter analyze` when touching Dart source even if unrelated existing warnings remain.
- Note any command that could not be run, especially Android builds when the SDK is unavailable.

## Safety

- Do not revert or overwrite user changes. The worktree may contain local screenshots, generated files, or unrelated edits.
- Avoid editing or committing generated/vendor/heavy directories: `build/`, `.dart_tool/`, `node_modules/`, `.venv/`, and Android/Flutter generated outputs.
- Never commit secrets or local config: `.env`, `.env.flutter`, `.telegram.env`, `.mcp.json`, API keys, tokens, or APK/web artifacts built with embedded keys.
- `--dart-define=OPENAI_API_KEY=...` embeds the key into app artifacts; use only for local personal builds.
- Preserve direct-client API-key warnings in docs unless the app architecture changes.

## Subagents

- Use explorer subagents for read-only mapping of Realtime flow, prompt behavior, settings persistence, or test gaps.
- Use worker subagents only for independent slices with clear file ownership, such as `lib/widgets/**`, `lib/services/**`, or `test/**`.
- Do not run multiple workers that edit `lib/screens/translator_screen.dart` at the same time.
- Keep final integration, product decisions, conflict resolution, and full verification in the main agent.
