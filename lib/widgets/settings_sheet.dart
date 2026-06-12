import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import '../models/language.dart';
import '../prompts.dart';

class SettingsSheet extends StatefulWidget {
  static const _tempOptions = {
    '0.0': '0.0',
    '0.1': '0.1',
    '0.3': '0.3',
    '0.5': '0.5',
    '0.7': '0.7',
    '1.0': '1.0',
  };

  static const _chatModels = {
    'gpt-5.5': '5.5',
    'gpt-5.4': '5.4',
    'gpt-5.4-mini': '5.4-mini',
    'gpt-5.4-nano': '5.4-nano',
  };

  static const _translationModels = {
    ..._chatModels,
    'mlkit-local': 'ML Kit 로컬 (Android/iOS)',
  };

  static const _reasoningEffortOptions = {
    '': '기본값 (미전송)',
    'minimal': 'minimal',
    'low': 'low (추천)',
    'medium': 'medium',
    'high': 'high',
    'xhigh': 'xhigh',
  };

  static const _sttModels = {
    'gpt-4o-transcribe': '4o transcribe (추천)',
    'gpt-4o-mini-transcribe': '4o-mini transcribe',
    'system-stt': '시스템 STT (실험)',
    'gpt-realtime-whisper': 'Realtime Whisper',
    'whisper-1': 'Whisper',
  };

  static const _realtimeSttDelayOptions = {
    'minimal': 'minimal (최저지연)',
    'low': 'low',
    'medium': 'medium',
    'high': 'high',
    'xhigh': 'xhigh',
  };

  static const _ttsModels = {
    'gpt-4o-mini-tts': '4o-mini TTS (추천)',
    'tts-1': 'TTS-1 (저지연)',
    'tts-1-hd': 'TTS-1 HD (고품질)',
    'system-tts': '시스템 TTS (로컬/실험)',
  };

  static const _systemTtsEngines = {
    'flutter': 'Flutter 플러그인',
    'direct_web': '직접 JS Web Speech (웹/실험)',
  };

  static const _realtimeNoiseReductionOptions = {
    'near_field': '근거리/이어폰 마이크 (추천)',
    'far_field': '노트북/원거리 마이크',
    'none': 'OFF',
  };

  final String mode;
  final String model;
  final String realtimeModel;
  final String sourceLang;
  final String targetLang;
  final String displayMode; // 'face' or 'one'
  final bool ttsSourceEnabled;
  final bool ttsTargetEnabled;
  final bool liveTranslateAudioEnabled;
  final String liveTranslateAudioRoute;
  final double liveTranslateAudioBoostGain;
  final int liveTranslateAudioBoostMs;
  final String liveTranslateInputNoiseReduction;
  final double liveTranslateCaptionFontSize;
  final String ttsModel;
  final String ttsAudioRoute;
  final String systemTtsEngine;
  final bool systemTtsSilentPrimeEnabled;
  final String voiceSource;
  final String voiceTarget;
  final double fontSize;
  final double secondaryFontSize;
  final double ttsSpeed;
  final int pauseSeconds;
  final double noiseThreshold;
  final double vadThreshold;
  final String turnDetectionType;
  final String vadEagerness;
  final int silenceDurationMs;
  final int realtimeBackgroundGraceSeconds;
  final bool pingPongTransportOptimized;
  final int pingPongWsBackgroundGraceSeconds;
  final String pingPongWebWsProxyUrl;
  final bool headsetButtonControlEnabled;
  final bool headsetButtonManualStopEnabled;
  final String toneMode;
  final bool realtimeActive;
  final String realtimeVoice;
  final ValueChanged<String> onRealtimeVoiceChanged;
  final String aiModel;
  final int aiPauseSeconds;
  final ValueChanged<String> onToneModeChanged;
  final ValueChanged<String> onAiModelChanged;
  final ValueChanged<int> onAiPauseSecondsChanged;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onRealtimeModelChanged;
  final ValueChanged<String> onSourceLangChanged;
  final ValueChanged<String> onTargetLangChanged;
  final ValueChanged<String> onDisplayModeChanged;
  final ValueChanged<bool> onTtsSourceChanged;
  final ValueChanged<bool> onTtsTargetChanged;
  final ValueChanged<bool> onLiveTranslateAudioEnabledChanged;
  final ValueChanged<String> onLiveTranslateAudioRouteChanged;
  final ValueChanged<double> onLiveTranslateAudioBoostGainChanged;
  final ValueChanged<int> onLiveTranslateAudioBoostMsChanged;
  final ValueChanged<String> onLiveTranslateInputNoiseReductionChanged;
  final ValueChanged<double> onLiveTranslateCaptionFontSizeChanged;
  final ValueChanged<String> onTtsModelChanged;
  final ValueChanged<String> onTtsAudioRouteChanged;
  final ValueChanged<String>? onSystemTtsEngineChanged;
  final ValueChanged<bool>? onSystemTtsSilentPrimeEnabledChanged;
  final ValueChanged<String> onVoiceSourceChanged;
  final ValueChanged<String> onVoiceTargetChanged;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onSecondaryFontSizeChanged;
  final ValueChanged<double> onTtsSpeedChanged;
  final ValueChanged<int> onPauseSecondsChanged;
  final ValueChanged<double> onNoiseThresholdChanged;
  final ValueChanged<double> onVadThresholdChanged;
  final ValueChanged<String> onTurnDetectionTypeChanged;
  final ValueChanged<String> onVadEagernessChanged;
  final ValueChanged<int> onSilenceDurationMsChanged;
  final ValueChanged<int> onRealtimeBackgroundGraceSecondsChanged;
  final ValueChanged<bool> onPingPongTransportOptimizedChanged;
  final ValueChanged<int> onPingPongWsBackgroundGraceSecondsChanged;
  final ValueChanged<String>? onPingPongWebWsProxyUrlChanged;
  final ValueChanged<bool> onHeadsetButtonControlEnabledChanged;
  final ValueChanged<bool> onHeadsetButtonManualStopEnabledChanged;
  final bool deleteConversationItems;
  final ValueChanged<bool> onDeleteConversationItemsChanged;
  final bool injectFewShot;
  final ValueChanged<bool> onInjectFewShotChanged;
  final bool translationContext;
  final ValueChanged<bool> onTranslationContextChanged;
  final double translationTemp;
  final ValueChanged<double> onTranslationTempChanged;
  final String translationReasoningEffort;
  final ValueChanged<String> onTranslationReasoningEffortChanged;
  final bool translationBenchmarkEnabled;
  final ValueChanged<bool> onTranslationBenchmarkEnabledChanged;
  final String sttModel;
  final ValueChanged<String> onSttModelChanged;
  final bool sttBenchmarkEnabled;
  final ValueChanged<bool> onSttBenchmarkEnabledChanged;
  final bool androidSystemSttFastInterim;
  final ValueChanged<bool> onAndroidSystemSttFastInterimChanged;
  final String realtimeSttDelay;
  final ValueChanged<String> onRealtimeSttDelayChanged;
  final String sttPrompt;
  final ValueChanged<String> onSttPromptChanged;
  final double classifyTemp;
  final ValueChanged<double> onClassifyTempChanged;
  final double pronunciationTemp;
  final ValueChanged<double> onPronunciationTempChanged;
  final String postProcessBackTranslationModel;
  final ValueChanged<String> onPostProcessBackTranslationModelChanged;
  final String postProcessBackTranslationReasoningEffort;
  final ValueChanged<String> onPostProcessBackTranslationReasoningEffortChanged;
  final String postProcessPronunciationModel;
  final ValueChanged<String> onPostProcessPronunciationModelChanged;
  final String postProcessPronunciationReasoningEffort;
  final ValueChanged<String> onPostProcessPronunciationReasoningEffortChanged;
  final String rtPostProcessMode;
  final ValueChanged<String> onRtPostProcessModeChanged;
  final bool backTranslateSource;
  final bool backTranslateTarget;
  final bool showPronunciation;
  final ValueChanged<bool> onBackTranslateSourceChanged;
  final ValueChanged<bool> onBackTranslateTargetChanged;
  final ValueChanged<bool> onShowPronunciationChanged;
  final PromptTemplateSet promptTemplates;
  final Future<void> Function(String key, String value) onPromptChanged;
  final Future<void> Function(String key) onPromptReset;
  final VoidCallback? onShowLogs;
  final VoidCallback onResetApiKey;
  final bool googleApiKeySet;
  final ValueChanged<String> onSetGoogleApiKey;
  final VoidCallback onClearGoogleApiKey;

  const SettingsSheet({
    super.key,
    required this.mode,
    required this.model,
    required this.realtimeModel,
    required this.sourceLang,
    required this.targetLang,
    required this.displayMode,
    required this.ttsSourceEnabled,
    required this.ttsTargetEnabled,
    this.liveTranslateAudioEnabled = false,
    this.liveTranslateAudioRoute = 'mono',
    this.liveTranslateAudioBoostGain = 1.65,
    this.liveTranslateAudioBoostMs = 1100,
    this.liveTranslateInputNoiseReduction = 'near_field',
    this.liveTranslateCaptionFontSize = 28,
    this.ttsModel = 'gpt-4o-mini-tts',
    this.ttsAudioRoute = 'mono',
    this.systemTtsEngine = 'flutter',
    this.systemTtsSilentPrimeEnabled = false,
    required this.voiceSource,
    required this.voiceTarget,
    required this.fontSize,
    this.secondaryFontSize = 11,
    required this.ttsSpeed,
    required this.pauseSeconds,
    required this.noiseThreshold,
    required this.vadThreshold,
    this.turnDetectionType = 'server_vad',
    this.vadEagerness = 'low',
    this.silenceDurationMs = 500,
    this.realtimeBackgroundGraceSeconds = 300,
    this.pingPongTransportOptimized = true,
    this.pingPongWsBackgroundGraceSeconds = 300,
    this.pingPongWebWsProxyUrl = '',
    this.headsetButtonControlEnabled = false,
    this.headsetButtonManualStopEnabled = true,
    required this.toneMode,
    this.realtimeActive = false,
    this.realtimeVoice = 'coral',
    required this.onRealtimeVoiceChanged,
    required this.aiModel,
    required this.aiPauseSeconds,
    required this.onToneModeChanged,
    required this.onAiModelChanged,
    required this.onAiPauseSecondsChanged,
    required this.onModeChanged,
    required this.onModelChanged,
    required this.onRealtimeModelChanged,
    required this.onSourceLangChanged,
    required this.onTargetLangChanged,
    required this.onDisplayModeChanged,
    required this.onTtsSourceChanged,
    required this.onTtsTargetChanged,
    required this.onLiveTranslateAudioEnabledChanged,
    required this.onLiveTranslateAudioRouteChanged,
    required this.onLiveTranslateAudioBoostGainChanged,
    required this.onLiveTranslateAudioBoostMsChanged,
    required this.onLiveTranslateInputNoiseReductionChanged,
    required this.onLiveTranslateCaptionFontSizeChanged,
    required this.onTtsModelChanged,
    required this.onTtsAudioRouteChanged,
    this.onSystemTtsEngineChanged,
    this.onSystemTtsSilentPrimeEnabledChanged,
    required this.onVoiceSourceChanged,
    required this.onVoiceTargetChanged,
    required this.onFontSizeChanged,
    required this.onSecondaryFontSizeChanged,
    required this.onTtsSpeedChanged,
    required this.onPauseSecondsChanged,
    required this.onNoiseThresholdChanged,
    required this.onVadThresholdChanged,
    required this.onTurnDetectionTypeChanged,
    required this.onVadEagernessChanged,
    required this.onSilenceDurationMsChanged,
    required this.onRealtimeBackgroundGraceSecondsChanged,
    required this.onPingPongTransportOptimizedChanged,
    required this.onPingPongWsBackgroundGraceSecondsChanged,
    this.onPingPongWebWsProxyUrlChanged,
    required this.onHeadsetButtonControlEnabledChanged,
    required this.onHeadsetButtonManualStopEnabledChanged,
    this.deleteConversationItems = true,
    required this.onDeleteConversationItemsChanged,
    this.injectFewShot = true,
    required this.onInjectFewShotChanged,
    this.translationContext = false,
    required this.onTranslationContextChanged,
    this.translationTemp = 0.3,
    required this.onTranslationTempChanged,
    this.translationReasoningEffort = 'low',
    required this.onTranslationReasoningEffortChanged,
    this.translationBenchmarkEnabled = false,
    required this.onTranslationBenchmarkEnabledChanged,
    this.sttModel = 'gpt-4o-transcribe',
    required this.onSttModelChanged,
    this.sttBenchmarkEnabled = false,
    required this.onSttBenchmarkEnabledChanged,
    this.androidSystemSttFastInterim = true,
    required this.onAndroidSystemSttFastInterimChanged,
    this.realtimeSttDelay = 'minimal',
    required this.onRealtimeSttDelayChanged,
    this.sttPrompt = '',
    required this.onSttPromptChanged,
    this.classifyTemp = 0.1,
    required this.onClassifyTempChanged,
    this.pronunciationTemp = 0.3,
    required this.onPronunciationTempChanged,
    this.postProcessBackTranslationModel = 'gpt-5.4-mini',
    required this.onPostProcessBackTranslationModelChanged,
    this.postProcessBackTranslationReasoningEffort = 'low',
    required this.onPostProcessBackTranslationReasoningEffortChanged,
    this.postProcessPronunciationModel = 'gpt-5.4-mini',
    required this.onPostProcessPronunciationModelChanged,
    this.postProcessPronunciationReasoningEffort = 'minimal',
    required this.onPostProcessPronunciationReasoningEffortChanged,
    this.rtPostProcessMode = 'chat',
    required this.onRtPostProcessModeChanged,
    this.backTranslateSource = true,
    this.backTranslateTarget = true,
    this.showPronunciation = false,
    required this.onBackTranslateSourceChanged,
    required this.onBackTranslateTargetChanged,
    required this.onShowPronunciationChanged,
    required this.promptTemplates,
    required this.onPromptChanged,
    required this.onPromptReset,
    this.onShowLogs,
    required this.onResetApiKey,
    this.googleApiKeySet = false,
    required this.onSetGoogleApiKey,
    required this.onClearGoogleApiKey,
  });

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  static const _silenceOptions = {
    '1': '1s',
    '2': '2s',
    '3': '3s',
    '5': '5s',
    '7': '7s',
    '30': 'OFF',
  };

  static const _androidSystemSttSilenceOptions = {
    '3': 'auto',
    '31': '1초 대기',
    '32': '2초 대기',
    '33': '3초 대기',
    '34': '4초 대기',
    '35': '5초 대기',
    '30': 'off(실험)',
  };

  bool get _isAndroidSystemStt =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      widget.sttModel == 'system-stt';
  bool get _supportsHeadsetButtons =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isRealtimeTranslate => widget.mode == 'realtime_translate';
  bool get _isLiveTranslate => _isRealtimeTranslate;
  bool get _isRt => _isLiveTranslate;
  bool get _isLocalTranslationModel => widget.model == 'mlkit-local';
  bool get _supportsTranslationTemperature =>
      !_isLocalTranslationModel && _supportsCustomTemperature(widget.model);
  bool get _supportsBackTranslationTemperature =>
      _supportsCustomTemperature(widget.postProcessBackTranslationModel);
  bool get _supportsPronunciationTemperature =>
      _supportsCustomTemperature(widget.postProcessPronunciationModel);
  bool _showPromptEditors = false;
  TextEditingController? _translationPromptController;
  TextEditingController? _assistantPromptController;
  TextEditingController? _ttsPromptController;

  @override
  void didUpdateWidget(covariant SettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.promptTemplates, widget.promptTemplates)) return;
    _syncControllerIfReady(
      _translationPromptController,
      widget.promptTemplates.translationSystem,
    );
    _syncControllerIfReady(
      _assistantPromptController,
      widget.promptTemplates.assistantSystem,
    );
    _syncControllerIfReady(
      _ttsPromptController,
      widget.promptTemplates.ttsInstructions,
    );
  }

  void _syncControllerIfReady(TextEditingController? controller, String value) {
    if (controller == null) return;
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  TextEditingController _controllerFor(
    TextEditingController? current,
    String value,
    void Function(TextEditingController controller) store,
  ) {
    if (current != null) return current;
    final controller = TextEditingController(text: value);
    store(controller);
    return controller;
  }

  TextEditingController get _translationController => _controllerFor(
    _translationPromptController,
    widget.promptTemplates.translationSystem,
    (controller) => _translationPromptController = controller,
  );

  TextEditingController get _assistantController => _controllerFor(
    _assistantPromptController,
    widget.promptTemplates.assistantSystem,
    (controller) => _assistantPromptController = controller,
  );

  TextEditingController get _ttsController => _controllerFor(
    _ttsPromptController,
    widget.promptTemplates.ttsInstructions,
    (controller) => _ttsPromptController = controller,
  );

  bool _supportsCustomTemperature(String model) {
    final id = model.toLowerCase();
    return !id.startsWith('gpt-5') &&
        !id.startsWith('o1') &&
        !id.startsWith('o3') &&
        !id.startsWith('o4');
  }

  @override
  void dispose() {
    _translationPromptController?.dispose();
    _assistantPromptController?.dispose();
    _ttsPromptController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final srcLang = getLangByCode(widget.sourceLang);
    final tgtLang = getLangByCode(widget.targetLang);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header with close button
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '설정',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('닫기'),
                  ),
                ],
              ),
              const Divider(height: 8),

              // === 언어 === (실시간 통역도 8개 언어 자유 선택)
              _sectionTitle('언어'),
              _langSelector('소스', widget.sourceLang, widget.onSourceLangChanged),
              const SizedBox(height: 8),
              _langSelector('타겟', widget.targetLang, widget.onTargetLangChanged),
              // Swap button
              Center(
                child: IconButton(
                  icon: const Icon(Icons.swap_vert, size: 20),
                  onPressed: () {
                    widget.onSourceLangChanged(widget.targetLang);
                    widget.onTargetLangChanged(widget.sourceLang);
                  },
                ),
              ),

              // === 화면 ===
              _sectionTitle('화면'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'face', label: Text('대면')),
                  ButtonSegment(value: 'one', label: Text('단방향')),
                ],
                selected: {widget.displayMode == 'one' ? 'one' : 'face'},
                onSelectionChanged: (v) => widget.onDisplayModeChanged(v.first),
                style: SegmentedButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 4),
              Text(switch (widget.displayMode) {
                'face' => '상대방 화면이 180° 회전 (테이블에 놓고 대화)',
                _ => '양쪽 화면이 같은 방향 (내가 둘 다 봄)',
              }, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              _sliderTile(
                '번역문',
                widget.fontSize,
                min: 12,
                max: 34,
                divisions: 22,
                onChanged: widget.onFontSizeChanged,
                valueLabel: widget.fontSize.round().toString(),
              ),
              _sliderTile(
                '보조글자',
                widget.secondaryFontSize,
                min: 8,
                max: 22,
                divisions: 14,
                onChanged: widget.onSecondaryFontSizeChanged,
                valueLabel: widget.secondaryFontSize.round().toString(),
              ),
              if (_isLiveTranslate)
                _sliderTile(
                  '청취 자막',
                  widget.liveTranslateCaptionFontSize,
                  min: 16,
                  max: 42,
                  divisions: 26,
                  onChanged: widget.onLiveTranslateCaptionFontSizeChanged,
                  valueLabel: widget.liveTranslateCaptionFontSize
                      .round()
                      .toString(),
                ),
              const SizedBox(height: 12),

              // === 모드 ===
              _sectionTitle('모드 / 모델'),
              _dropdownTile('모드', widget.mode, {
                'openai': 'Ping-Pong',
                'realtime_translate': '실시간 통역',
              }, widget.onModeChanged),
              if (_isRealtimeTranslate)
                _readonlyTile('실시간 모델', 'gemini-3.5-live-translate')
              else ...[
                _dropdownTile(
                  '번역 모델',
                  widget.model,
                  SettingsSheet._translationModels,
                  widget.onModelChanged,
                ),
                if (!_isLocalTranslationModel) ...[
                  _dropdownTile(
                    '번역 추론',
                    widget.translationReasoningEffort,
                    SettingsSheet._reasoningEffortOptions,
                    widget.onTranslationReasoningEffortChanged,
                  ),
                  _switchTile(
                    '번역 벤치마크',
                    widget.translationBenchmarkEnabled,
                    widget.onTranslationBenchmarkEnabledChanged,
                  ),
                ],
              ],
              if (!_isRt) ...[
                if (!_isLocalTranslationModel)
                  _switchTile(
                    '대화 맥락 주입',
                    widget.translationContext,
                    widget.onTranslationContextChanged,
                  ),
                if (_supportsTranslationTemperature)
                  _dropdownTile(
                    'Temperature',
                    widget.translationTemp.toString(),
                    SettingsSheet._tempOptions,
                    (v) => widget.onTranslationTempChanged(double.parse(v)),
                  ),
              ],
              if (!_isLiveTranslate && !_isLocalTranslationModel)
                _dropdownTile('번역 톤', widget.toneMode, {
                  'normal': '기본',
                  'polite': '예의',
                  'casual': '친구',
                }, widget.onToneModeChanged),
              if (!_isRt) ...[
                _switchTile(
                  'Ping-Pong 전송 최적화',
                  widget.pingPongTransportOptimized,
                  widget.onPingPongTransportOptimizedChanged,
                ),
                if (widget.pingPongTransportOptimized)
                  _dropdownTile(
                    'WS 백그라운드',
                    widget.pingPongWsBackgroundGraceSeconds.toString(),
                    {
                      '0': 'OFF (즉시 해제)',
                      '30': '30s',
                      '60': '60s',
                      '300': '5분',
                      '600': '10분',
                    },
                    (v) => widget.onPingPongWsBackgroundGraceSecondsChanged(
                      int.parse(v),
                    ),
                  ),
                if (kIsWeb &&
                    widget.pingPongTransportOptimized &&
                    widget.onPingPongWebWsProxyUrlChanged != null)
                  _textInputTile(
                    'Web WS Proxy',
                    widget.pingPongWebWsProxyUrl,
                    widget.onPingPongWebWsProxyUrlChanged!,
                    hintText: 'wss://your-domain.example/v1/responses',
                  ),
                if (_supportsHeadsetButtons) ...[
                  _switchTile(
                    '이어폰 발화 제어',
                    widget.headsetButtonControlEnabled,
                    widget.onHeadsetButtonControlEnabledChanged,
                  ),
                  if (widget.headsetButtonControlEnabled)
                    _switchTile(
                      '같은 버튼으로 종료',
                      widget.headsetButtonManualStopEnabled,
                      widget.onHeadsetButtonManualStopEnabledChanged,
                    ),
                  if (widget.headsetButtonControlEnabled)
                    _readonlyTile('이어폰 매핑', '1탭=상대, 2탭=나, 3탭=다시/취소'),
                ],
              ],
              if (widget.realtimeActive)
                const Padding(
                  padding: EdgeInsets.only(left: 80, bottom: 4),
                  child: Text(
                    '⟳ Realtime 재시작 시 적용',
                    style: TextStyle(fontSize: 10, color: Colors.orange),
                  ),
                ),
              const SizedBox(height: 12),

              if (!_isLiveTranslate) ...[
                // === AI 어시스턴트 ===
                _sectionTitle('AI 어시스턴트'),
                _dropdownTile(
                  'AI 모델',
                  widget.aiModel,
                  SettingsSheet._chatModels,
                  widget.onAiModelChanged,
                ),
                _dropdownTile(
                  'AI 묵음',
                  widget.aiPauseSeconds.toString(),
                  {
                    '1': '1s',
                    '2': '2s',
                    '3': '3s',
                    '5': '5s',
                    '7': '7s',
                    '10': '10s',
                    '30': 'OFF',
                  },
                  (v) => widget.onAiPauseSecondsChanged(int.parse(v)),
                ),
                const SizedBox(height: 12),
              ],

              // 역번역/발음은 라이브(실시간통역)에서도 커밋된 세그먼트에
              // 비동기 post-process로 적용된다.
              ...[
                // === 역번역 / 발음 ===
                _sectionTitle('역번역 / 발음'),
                _switchTile(
                  '${srcLang.name} 역번역',
                  widget.backTranslateSource,
                  widget.onBackTranslateSourceChanged,
                ),
                _switchTile(
                  '${tgtLang.name} 역번역',
                  widget.backTranslateTarget,
                  widget.onBackTranslateTargetChanged,
                ),
                _switchTile(
                  '한국어 발음 표시',
                  widget.showPronunciation,
                  widget.onShowPronunciationChanged,
                ),
                _dropdownTile(
                  '역번역 모델',
                  widget.postProcessBackTranslationModel,
                  SettingsSheet._chatModels,
                  widget.onPostProcessBackTranslationModelChanged,
                ),
                _dropdownTile(
                  '역번역 추론',
                  widget.postProcessBackTranslationReasoningEffort,
                  SettingsSheet._reasoningEffortOptions,
                  widget.onPostProcessBackTranslationReasoningEffortChanged,
                ),
                if (_supportsBackTranslationTemperature)
                  _dropdownTile(
                    '역번역 Temp',
                    widget.classifyTemp.toString(),
                    SettingsSheet._tempOptions,
                    (v) => widget.onClassifyTempChanged(double.parse(v)),
                  ),
                _dropdownTile(
                  '발음 모델',
                  widget.postProcessPronunciationModel,
                  SettingsSheet._chatModels,
                  widget.onPostProcessPronunciationModelChanged,
                ),
                _dropdownTile(
                  '발음 추론',
                  widget.postProcessPronunciationReasoningEffort,
                  SettingsSheet._reasoningEffortOptions,
                  widget.onPostProcessPronunciationReasoningEffortChanged,
                ),
                if (_supportsPronunciationTemperature)
                  _dropdownTile(
                    '발음 Temp',
                    widget.pronunciationTemp.toString(),
                    SettingsSheet._tempOptions,
                    (v) => widget.onPronunciationTempChanged(double.parse(v)),
                  ),
                const SizedBox(height: 12),
              ],

              // === 음성 출력 ===
              _sectionTitle('음성 출력'),
              if (_isLiveTranslate) ...[
                _readonlyTile('자막', '${srcLang.name} ↔ ${tgtLang.name}'),
                _switchTile(
                  '번역 음성 출력',
                  widget.liveTranslateAudioEnabled,
                  widget.onLiveTranslateAudioEnabledChanged,
                ),
                if (widget.liveTranslateAudioEnabled)
                  _dropdownTile(
                    '이어폰 공유',
                    widget.liveTranslateAudioRoute,
                    const {
                      'mono': '양쪽 같은 음성',
                      'mine_left': '왼쪽=내 귀 / 오른쪽=상대',
                      'mine_right': '오른쪽=내 귀 / 왼쪽=상대',
                    },
                    widget.onLiveTranslateAudioRouteChanged,
                  ),
                if (widget.liveTranslateAudioEnabled)
                  _dropdownTile(
                    '초반 보정',
                    widget.liveTranslateAudioBoostGain.toStringAsFixed(2),
                    const {
                      '1.00': 'OFF',
                      '1.25': '약하게',
                      '1.65': '기본',
                      '2.00': '강하게',
                      '2.35': '매우 강하게',
                    },
                    (v) => widget.onLiveTranslateAudioBoostGainChanged(
                      double.parse(v),
                    ),
                  ),
                if (widget.liveTranslateAudioEnabled)
                  _dropdownTile(
                    '보정 시간',
                    widget.liveTranslateAudioBoostMs.toString(),
                    const {
                      '0': 'OFF',
                      '500': '0.5s',
                      '800': '0.8s',
                      '1100': '1.1s',
                      '1500': '1.5s',
                      '2000': '2.0s',
                    },
                    (v) =>
                        widget.onLiveTranslateAudioBoostMsChanged(int.parse(v)),
                  ),
              ] else ...[
                _dropdownTile(
                  'TTS 모델',
                  widget.ttsModel,
                  SettingsSheet._ttsModels,
                  widget.onTtsModelChanged,
                ),
                if (widget.ttsModel == 'system-tts')
                  _dropdownTile(
                    '시스템 TTS 엔진',
                    widget.systemTtsEngine,
                    SettingsSheet._systemTtsEngines,
                    widget.onSystemTtsEngineChanged ?? (_) {},
                  ),
                if (widget.ttsModel == 'system-tts' &&
                    widget.systemTtsEngine != 'direct_web')
                  _switchTile(
                    '무음 프라임 (실험)',
                    widget.systemTtsSilentPrimeEnabled,
                    widget.onSystemTtsSilentPrimeEnabledChanged ?? (_) {},
                  ),
                _dropdownTile('TTS 이어폰 공유', widget.ttsAudioRoute, const {
                  'mono': '양쪽 같은 음성',
                  'mine_left': '왼쪽=내 귀 / 오른쪽=상대',
                  'mine_right': '오른쪽=내 귀 / 왼쪽=상대',
                }, widget.onTtsAudioRouteChanged),
                _switchTile(
                  '${srcLang.name} TTS',
                  widget.ttsSourceEnabled,
                  widget.onTtsSourceChanged,
                ),
                if (widget.ttsSourceEnabled)
                  _dropdownTile('음성', widget.voiceSource, {
                    'nova': '여',
                    'onyx': '남',
                    'ash': '남2',
                    'coral': '여2',
                  }, widget.onVoiceSourceChanged),
                _switchTile(
                  '${tgtLang.name} TTS',
                  widget.ttsTargetEnabled,
                  widget.onTtsTargetChanged,
                ),
                if (widget.ttsTargetEnabled)
                  _dropdownTile('음성', widget.voiceTarget, {
                    'nova': '여',
                    'onyx': '남',
                    'ash': '남2',
                    'coral': '여2',
                  }, widget.onVoiceTargetChanged),
              ],
              // TTS speed (legacy browser mode removed)
              const SizedBox(height: 12),

              // === 입력 감지 ===
              if (!_isRt) ...[
                _sectionTitle('입력 감지'),
                _dropdownTile(
                  'STT 모델',
                  widget.sttModel,
                  SettingsSheet._sttModels,
                  widget.onSttModelChanged,
                ),
                if (widget.sttModel == 'gpt-4o-mini-transcribe' ||
                    widget.sttModel == 'gpt-4o-transcribe')
                  _switchTile(
                    '4o STT 벤치마크',
                    widget.sttBenchmarkEnabled,
                    widget.onSttBenchmarkEnabledChanged,
                  ),
                if (_isAndroidSystemStt)
                  _switchTile(
                    '빠른 말풍선 (실험)',
                    widget.androidSystemSttFastInterim,
                    widget.onAndroidSystemSttFastInterimChanged,
                  ),
                if (widget.sttModel == 'gpt-realtime-whisper' &&
                    widget.pingPongTransportOptimized)
                  _dropdownTile(
                    'STT 지연',
                    widget.realtimeSttDelay,
                    SettingsSheet._realtimeSttDelayOptions,
                    widget.onRealtimeSttDelayChanged,
                  ),
                _textInputTile(
                  'STT 힌트',
                  widget.sttPrompt,
                  widget.onSttPromptChanged,
                  hintText: '고유명사, 자주 나오는 표현 등',
                ),
                _dropdownTile(
                  _isAndroidSystemStt ? '묵음 감지' : '묵음 타임아웃',
                  widget.pauseSeconds.toString(),
                  _isAndroidSystemStt
                      ? _androidSystemSttSilenceOptions
                      : _silenceOptions,
                  (v) => widget.onPauseSecondsChanged(int.parse(v)),
                ),
                if (widget.mode == 'openai')
                  _dropdownTile(
                    '소음 기준',
                    widget.noiseThreshold.toInt().toString(),
                    {
                      '-20': '-20 (시끄러운 환경)',
                      '-30': '-30',
                      '-40': '-40',
                      '-50': '-50',
                      '-60': '-60 (웹 기본)',
                      '-70': '-70',
                      '-80': '-80 (조용한 환경)',
                    },
                    (v) => widget.onNoiseThresholdChanged(double.parse(v)),
                  ),
              ],
              if (_isRt) ...[
                _sectionTitle('Realtime 설정'),
                if (_isLiveTranslate)
                  _dropdownTile(
                    '입력 소음 보정',
                    widget.liveTranslateInputNoiseReduction,
                    SettingsSheet._realtimeNoiseReductionOptions,
                    widget.onLiveTranslateInputNoiseReductionChanged,
                  ),
                _dropdownTile(
                  '백그라운드',
                  widget.realtimeBackgroundGraceSeconds.toString(),
                  {
                    '0': 'OFF (즉시 해제)',
                    '30': '30s',
                    '60': '60s',
                    '300': '5분',
                    '600': '10분',
                  },
                  (v) => widget.onRealtimeBackgroundGraceSecondsChanged(
                    int.parse(v),
                  ),
                ),
              ],
              const SizedBox(height: 12),

              if (!_isLiveTranslate) ...[
                // === 프롬프트 ===
                _sectionTitle('프롬프트'),
                const Text(
                  '사용 가능한 placeholder: {{SOURCE_LANG}}, {{TARGET_LANG}}, {{TONE_INSTRUCTION}}, {{CONTEXT_INSTRUCTION}}',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      setState(() => _showPromptEditors = !_showPromptEditors),
                  icon: Icon(
                    _showPromptEditors ? Icons.expand_less : Icons.tune,
                    size: 16,
                  ),
                  label: Text(_showPromptEditors ? '프롬프트 접기' : '프롬프트 편집'),
                ),
                if (_showPromptEditors) ...[
                  const SizedBox(height: 8),
                  _promptEditor(
                    title: 'translationSystem',
                    storageKey: AppPrompts.translationSystemKey,
                    controller: _translationController,
                    onChanged: widget.onPromptChanged,
                    onReset: widget.onPromptReset,
                    defaultValue: AppPrompts.defaults.translationSystem,
                  ),
                  _promptEditor(
                    title: 'assistantSystem',
                    storageKey: AppPrompts.assistantSystemKey,
                    controller: _assistantController,
                    onChanged: widget.onPromptChanged,
                    onReset: widget.onPromptReset,
                    defaultValue: AppPrompts.defaults.assistantSystem,
                  ),
                  _promptEditor(
                    title: 'ttsInstructions',
                    storageKey: AppPrompts.ttsInstructionsKey,
                    controller: _ttsController,
                    onChanged: widget.onPromptChanged,
                    onReset: widget.onPromptReset,
                    defaultValue: AppPrompts.defaults.ttsInstructions,
                  ),
                ],
                if (_showPromptEditors && widget.realtimeActive)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Realtime 프롬프트 수정은 다음 Realtime 시작부터 적용됩니다.',
                      style: TextStyle(fontSize: 10, color: Colors.orange),
                    ),
                  ),
                const SizedBox(height: 12),
              ],

              // === 기타 ===
              _sectionTitle('기타'),
              if (widget.onShowLogs != null)
                ListTile(
                  leading: const Icon(Icons.article_outlined),
                  title: const Text('로그 보기'),
                  subtitle: const Text('Ping-Pong/TTS/후처리 로그 확인'),
                  onTap: widget.onShowLogs,
                  dense: true,
                ),
              ListTile(
                leading: Icon(
                  Icons.translate,
                  color: widget.googleApiKeySet ? Colors.green : Colors.grey,
                ),
                title: const Text('Gemini(Google) API 키'),
                subtitle: Text(
                  widget.googleApiKeySet
                      ? '설정됨 · 실시간 통역 사용 가능 (탭하여 변경)'
                      : '미설정 · 실시간 통역에 필요 (탭하여 입력)',
                ),
                trailing: widget.googleApiKeySet
                    ? IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: '삭제',
                        onPressed: widget.onClearGoogleApiKey,
                      )
                    : null,
                onTap: _showGoogleApiKeyDialog,
                dense: true,
              ),
              ListTile(
                leading: const Icon(Icons.key_off, color: Colors.red),
                title: const Text('API 키 초기화'),
                subtitle: const Text('저장된 키를 삭제하고 입력 화면으로'),
                onTap: widget.onResetApiKey,
                dense: true,
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Color(0xFF4A90D9),
        ),
      ),
    );
  }

  Widget _langSelector(
    String label,
    String current,
    ValueChanged<String> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final lang in supportedLanguages)
                ChoiceChip(
                  label: Text(lang.name, style: TextStyle(fontSize: 11)),
                  selected: lang.code == current,
                  onSelected: (_) => onChanged(lang.code),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dropdownTile(
    String label,
    String value,
    Map<String, String> items,
    ValueChanged<String> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: items.containsKey(value) ? value : items.keys.first,
              items: [
                for (final e in items.entries)
                  DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value, style: const TextStyle(fontSize: 12)),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textInputTile(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    String? hintText,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: 80,
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
          ),
          Expanded(
            child: TextFormField(
              initialValue: value,
              minLines: 1,
              maxLines: 3,
              onChanged: onChanged,
              decoration: InputDecoration(
                isDense: true,
                hintText: hintText,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: const OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showGoogleApiKeyDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gemini(Google) API 키'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: 'AIza... 또는 Gemini API 키',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty) {
      widget.onSetGoogleApiKey(result);
    }
  }

  Widget _readonlyTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                value,
                style: const TextStyle(fontSize: 12, color: Colors.black87),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sliderTile(
    String label,
    double value, {
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required String valueLabel,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              divisions: divisions,
              label: valueLabel,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(
              valueLabel,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchTile(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(label, style: const TextStyle(fontSize: 12)),
      value: value,
      onChanged: onChanged,
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _promptEditor({
    required String title,
    required String storageKey,
    required TextEditingController controller,
    required Future<void> Function(String key, String value) onChanged,
    required Future<void> Function(String key) onReset,
    required String defaultValue,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () async {
                  await onReset(storageKey);
                  if (!mounted) return;
                  setState(() => controller.text = defaultValue);
                },
                child: const Text('리셋'),
              ),
            ],
          ),
          TextField(
            controller: controller,
            minLines: 4,
            maxLines: 10,
            onChanged: (value) => onChanged(storageKey, value),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(10),
            ),
            style: const TextStyle(fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }
}
