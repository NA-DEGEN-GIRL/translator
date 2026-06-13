// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:koja_translator/main.dart';
import 'package:koja_translator/prompts.dart';
import 'package:koja_translator/widgets/settings_sheet.dart';

void _ignore<T>(T value) {}

void _ignoreVoid() {}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows API key screen when no key is available', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KoJaApp());

    expect(find.text('KO ⇄ JA'), findsOneWidget);
    expect(find.text('OpenAI API Key'), findsOneWidget);
    expect(find.text('시작'), findsOneWidget);
  });

  testWidgets('opens translator with input controls collapsed by default', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    expect(find.text('KO ⇄ JA'), findsNothing);
    expect(find.byKey(const ValueKey('input-toggle')), findsOneWidget);
    expect(find.textContaining('입력창'), findsNothing);
    expect(find.byKey(const ValueKey('pingpong-mic-source')), findsOneWidget);
    expect(find.byKey(const ValueKey('pingpong-mic-target')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bottom-face-pingpong-mic-source')),
      findsNothing,
    );
  });

  testWidgets('input toggle expands text entry and persists state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('input-toggle')));
    await tester.pump();

    expect(find.textContaining('입력창'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 400));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('inputExpanded'), isTrue);
  });

  testWidgets('legacy realtime mode migrates to realtime translate UI', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'mode': 'realtime_dir',
      'displayMode': 'one',
      'inputExpanded': false,
    });

    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    expect(find.byKey(const ValueKey('directional-mic-a')), findsNothing);
    expect(find.byKey(const ValueKey('directional-mic-b')), findsNothing);
    // 실시간 통역(수동 턴): 연결 버튼 + 방향 턴 마이크 2개.
    expect(find.byKey(const ValueKey('translate-mic-source')), findsNothing);
    expect(find.byKey(const ValueKey('translate-mic-target')), findsNothing);
    expect(find.byKey(const ValueKey('lt-connect-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('lt-turn-mic-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('lt-turn-mic-b')), findsOneWidget);
  });

  testWidgets('legacy face v2 display migrates to face view', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'mode': 'openai',
      'displayMode': 'face_v2',
      'inputExpanded': false,
    });

    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    expect(find.byKey(const ValueKey('face-v2-mic-ko')), findsNothing);
    expect(
      find.byKey(const ValueKey('bottom-face-pingpong-mic-source')),
      findsOneWidget,
    );
  });

  testWidgets('ping-pong single view shows large language mics', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'mode': 'openai',
      'displayMode': 'one',
      'inputExpanded': false,
    });

    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    expect(find.byKey(const ValueKey('pingpong-mic-source')), findsOneWidget);
    expect(find.byKey(const ValueKey('pingpong-mic-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('rt-power-button')), findsNothing);
  });

  testWidgets('realtime translate single view shows connect + turn mics', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'mode': 'realtime_translate',
      'displayMode': 'one',
      'inputExpanded': false,
      'sourceLang': 'en',
      'targetLang': 'zh',
    });

    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    // 수동 턴: 연결 버튼 + 방향 턴 마이크 2개(레거시 자동감지 마이크 키 없음).
    expect(find.byKey(const ValueKey('translate-mic-source')), findsNothing);
    expect(find.byKey(const ValueKey('translate-mic-target')), findsNothing);
    expect(find.byKey(const ValueKey('lt-connect-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('lt-turn-mic-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('lt-turn-mic-b')), findsOneWidget);
  });

  testWidgets('legacy removed live mode migrates to realtime translate UI', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'mode': 'google_translate',
      'displayMode': 'one',
      'inputExpanded': false,
      'sourceLang': 'en',
      'targetLang': 'zh',
    });

    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    // 레거시 google_translate 모드는 realtime_translate(Gemini)로 마이그레이션 → 단일 버튼.
    expect(find.byKey(const ValueKey('translate-mic-source')), findsNothing);
    expect(find.byKey(const ValueKey('translate-mic-target')), findsNothing);
    expect(find.byKey(const ValueKey('lt-connect-button')), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('realtime translate expanded input keeps single connect button', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'mode': 'realtime_translate',
      'displayMode': 'one',
      'inputExpanded': true,
    });

    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    expect(find.byKey(const ValueKey('translate-mic-source')), findsNothing);
    expect(find.byKey(const ValueKey('translate-mic-target')), findsNothing);
    expect(find.byKey(const ValueKey('lt-connect-button')), findsOneWidget);
  });

  testWidgets('realtime translate face view uses compact direction mics', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'mode': 'realtime_translate',
      'displayMode': 'face',
      'inputExpanded': false,
    });

    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('bottom-face-translate-mic-source')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom-face-translate-mic-target')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('translate-mic-source')), findsNothing);
    expect(find.byKey(const ValueKey('translate-mic-target')), findsNothing);
    expect(find.byKey(const ValueKey('rt-power-button')), findsOneWidget);
  });

  testWidgets('realtime translate settings hide unsupported controls', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSheet(
            mode: 'realtime_translate',
            model: 'gpt-5.4-nano',
            realtimeModel: 'unused',
            sourceLang: 'ko',
            targetLang: 'ja',
            displayMode: 'one',
            ttsSourceEnabled: false,
            ttsTargetEnabled: false,
            liveTranslateAudioEnabled: false,
            liveTranslateAudioRoute: 'mono',
            liveTranslateAudioBoostGain: 1.65,
            liveTranslateAudioBoostMs: 1100,
            liveTranslateInputNoiseReduction: 'near_field',
            liveTranslateCaptionFontSize: 28,
            ttsModel: 'gpt-4o-mini-tts',
            ttsAudioRoute: 'mono',
            voiceSource: 'nova',
            voiceTarget: 'onyx',
            fontSize: 20,
            secondaryFontSize: 11,
            ttsSpeed: 1,
            pauseSeconds: 2,
            noiseThreshold: -60,
            vadThreshold: 0.5,
            realtimeBackgroundGraceSeconds: 300,
            toneMode: 'normal',
            realtimeActive: false,
            realtimeVoice: 'coral',
            onRealtimeVoiceChanged: _ignore<String>,
            aiModel: 'gpt-5.4-nano',
            aiPauseSeconds: 5,
            onToneModeChanged: _ignore<String>,
            onAiModelChanged: _ignore<String>,
            onAiPauseSecondsChanged: _ignore<int>,
            onModeChanged: _ignore<String>,
            onModelChanged: _ignore<String>,
            onRealtimeModelChanged: _ignore<String>,
            onSourceLangChanged: _ignore<String>,
            onTargetLangChanged: _ignore<String>,
            onDisplayModeChanged: _ignore<String>,
            onTtsSourceChanged: _ignore<bool>,
            onTtsTargetChanged: _ignore<bool>,
            onLiveTranslateAudioEnabledChanged: _ignore<bool>,
            onLiveTranslateAudioRouteChanged: _ignore<String>,
            onLiveTranslateEarphoneMicExperimentChanged: _ignore<bool>,
            onLiveTranslateAudioBoostGainChanged: _ignore<double>,
            onLiveTranslateAudioBoostMsChanged: _ignore<int>,
            onLiveTranslateInputNoiseReductionChanged: _ignore<String>,
            onLiveTranslateCaptionFontSizeChanged: _ignore<double>,
            onTtsModelChanged: _ignore<String>,
            onTtsAudioRouteChanged: _ignore<String>,
            onVoiceSourceChanged: _ignore<String>,
            onVoiceTargetChanged: _ignore<String>,
            onFontSizeChanged: _ignore<double>,
            onSecondaryFontSizeChanged: _ignore<double>,
            onTtsSpeedChanged: _ignore<double>,
            onPauseSecondsChanged: _ignore<int>,
            onNoiseThresholdChanged: _ignore<double>,
            onVadThresholdChanged: _ignore<double>,
            turnDetectionType: 'server_vad',
            vadEagerness: 'low',
            silenceDurationMs: 500,
            onTurnDetectionTypeChanged: _ignore<String>,
            onVadEagernessChanged: _ignore<String>,
            onSilenceDurationMsChanged: _ignore<int>,
            onRealtimeBackgroundGraceSecondsChanged: _ignore<int>,
            pingPongTransportOptimized: true,
            pingPongWsBackgroundGraceSeconds: 300,
            onPingPongTransportOptimizedChanged: _ignore<bool>,
            onPingPongWsBackgroundGraceSecondsChanged: _ignore<int>,
            headsetButtonControlEnabled: false,
            headsetButtonManualStopEnabled: true,
            onHeadsetButtonControlEnabledChanged: _ignore<bool>,
            onHeadsetButtonManualStopEnabledChanged: _ignore<bool>,
            deleteConversationItems: true,
            onDeleteConversationItemsChanged: _ignore<bool>,
            injectFewShot: true,
            onInjectFewShotChanged: _ignore<bool>,
            translationContext: false,
            onTranslationContextChanged: _ignore<bool>,
            translationTemp: 0.3,
            onTranslationTempChanged: _ignore<double>,
            translationReasoningEffort: 'low',
            onTranslationReasoningEffortChanged: _ignore<String>,
            translationBenchmarkEnabled: false,
            onTranslationBenchmarkEnabledChanged: _ignore<bool>,
            sttModel: 'gpt-4o-mini-transcribe',
            onSttModelChanged: _ignore<String>,
            sttBenchmarkEnabled: false,
            onSttBenchmarkEnabledChanged: _ignore<bool>,
            androidSystemSttFastInterim: true,
            onAndroidSystemSttFastInterimChanged: _ignore<bool>,
            realtimeSttDelay: 'minimal',
            onRealtimeSttDelayChanged: _ignore<String>,
            sttPrompt: '',
            onSttPromptChanged: _ignore<String>,
            classifyTemp: 0.1,
            onClassifyTempChanged: _ignore<double>,
            pronunciationTemp: 0.3,
            onPronunciationTempChanged: _ignore<double>,
            postProcessBackTranslationModel: 'gpt-5.4-nano',
            onPostProcessBackTranslationModelChanged: _ignore<String>,
            postProcessBackTranslationReasoningEffort: 'low',
            onPostProcessBackTranslationReasoningEffortChanged: _ignore<String>,
            postProcessPronunciationModel: 'gpt-5.4-nano',
            onPostProcessPronunciationModelChanged: _ignore<String>,
            postProcessPronunciationReasoningEffort: 'minimal',
            onPostProcessPronunciationReasoningEffortChanged: _ignore<String>,
            rtPostProcessMode: 'chat',
            onRtPostProcessModeChanged: _ignore<String>,
            backTranslateSource: true,
            backTranslateTarget: true,
            showPronunciation: false,
            onBackTranslateSourceChanged: _ignore<bool>,
            onBackTranslateTargetChanged: _ignore<bool>,
            onShowPronunciationChanged: _ignore<bool>,
            promptTemplates: AppPrompts.defaults,
            onPromptChanged: (_, _) async {},
            onPromptReset: (_) async {},
            onResetApiKey: _ignoreVoid,
            onSetGoogleApiKey: (_) {},
            onClearGoogleApiKey: _ignoreVoid,
          ),
        ),
      ),
    );

    expect(find.text('실시간 모델'), findsOneWidget);
    expect(find.text('gemini-3.5-live-translate'), findsOneWidget);
    // 실시간 통역도 8개 언어 자유 선택 — 언어 셀렉터가 노출된다.
    expect(find.text('소스'), findsOneWidget);
    expect(find.text('타겟'), findsOneWidget);
    expect(find.text('AI 어시스턴트'), findsNothing);
    expect(find.text('번역 톤'), findsNothing);
    expect(find.text('프롬프트'), findsNothing);
    expect(find.text('대면 v2'), findsNothing);
    expect(find.text('마이크 투명도'), findsNothing);
    expect(find.text('번역 추론'), findsNothing);
    expect(find.text('번역 벤치마크'), findsNothing);
    expect(find.text('Temperature'), findsNothing);
    expect(find.text('STT 모델'), findsNothing);
    expect(find.text('STT 힌트'), findsNothing);
    expect(find.text('Ping-Pong 전송 최적화'), findsNothing);
    expect(find.text('감지 모델'), findsNothing);
    expect(find.text('감지 추론'), findsNothing);
    expect(find.text('역번역 모델'), findsOneWidget);
    expect(find.text('역번역 Temp'), findsNothing);
    expect(find.text('발음 모델'), findsOneWidget);
    expect(find.text('발음 Temp'), findsNothing);
    expect(find.text('백그라운드'), findsOneWidget);
    expect(find.text('입력 소음 보정'), findsOneWidget);
    expect(find.text('번역 음성 출력'), findsOneWidget);
    expect(find.text('이어폰 공유'), findsNothing);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    expect(find.text('Ping-Pong'), findsOneWidget);
    expect(find.text('실시간 통역'), findsWidgets);
    expect(find.text('Realtime'), findsNothing);
    expect(find.text('Realtime (방향)'), findsNothing);
  });
}
