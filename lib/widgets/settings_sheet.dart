import 'package:flutter/material.dart';
import '../models/language.dart';
import '../prompts.dart';

class SettingsSheet extends StatefulWidget {
  static const _tempOptions = {
    '0.0': '0.0', '0.1': '0.1', '0.3': '0.3',
    '0.5': '0.5', '0.7': '0.7', '1.0': '1.0',
  };

  static const _chatModels = {
    'gpt-5.4-nano': '5.4-nano',
    'gpt-5.4-mini': '5.4-mini',
    'gpt-5.4': '5.4',
  };

  final String mode;
  final String model;
  final String realtimeModel;
  final String sourceLang;
  final String targetLang;
  final String displayMode; // 'face' or 'one'
  final bool ttsSourceEnabled;
  final bool ttsTargetEnabled;
  final String voiceSource;
  final String voiceTarget;
  final double fontSize;
  final double ttsSpeed;
  final int pauseSeconds;
  final double noiseThreshold;
  final double vadThreshold;
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
  final ValueChanged<String> onVoiceSourceChanged;
  final ValueChanged<String> onVoiceTargetChanged;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onTtsSpeedChanged;
  final ValueChanged<int> onPauseSecondsChanged;
  final ValueChanged<double> onNoiseThresholdChanged;
  final ValueChanged<double> onVadThresholdChanged;
  final bool deleteConversationItems;
  final ValueChanged<bool> onDeleteConversationItemsChanged;
  final bool injectFewShot;
  final ValueChanged<bool> onInjectFewShotChanged;
  final bool translationContext;
  final ValueChanged<bool> onTranslationContextChanged;
  final double translationTemp;
  final ValueChanged<double> onTranslationTempChanged;
  final double classifyTemp;
  final ValueChanged<double> onClassifyTempChanged;
  final double pronunciationTemp;
  final ValueChanged<double> onPronunciationTempChanged;
  final String detectModel;
  final bool backTranslateSource;
  final bool backTranslateTarget;
  final bool showPronunciation;
  final ValueChanged<String> onDetectModelChanged;
  final ValueChanged<bool> onBackTranslateSourceChanged;
  final ValueChanged<bool> onBackTranslateTargetChanged;
  final ValueChanged<bool> onShowPronunciationChanged;
  final PromptTemplateSet promptTemplates;
  final Future<void> Function(String key, String value) onPromptChanged;
  final Future<void> Function(String key) onPromptReset;
  final VoidCallback onResetApiKey;

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
    required this.voiceSource,
    required this.voiceTarget,
    required this.fontSize,
    required this.ttsSpeed,
    required this.pauseSeconds,
    required this.noiseThreshold,
    required this.vadThreshold,
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
    required this.onVoiceSourceChanged,
    required this.onVoiceTargetChanged,
    required this.onFontSizeChanged,
    required this.onTtsSpeedChanged,
    required this.onPauseSecondsChanged,
    required this.onNoiseThresholdChanged,
    required this.onVadThresholdChanged,
    this.deleteConversationItems = true,
    required this.onDeleteConversationItemsChanged,
    this.injectFewShot = true,
    required this.onInjectFewShotChanged,
    this.translationContext = false,
    required this.onTranslationContextChanged,
    this.translationTemp = 0.3,
    required this.onTranslationTempChanged,
    this.classifyTemp = 0.1,
    required this.onClassifyTempChanged,
    this.pronunciationTemp = 0.3,
    required this.onPronunciationTempChanged,
    this.detectModel = 'gpt-5.4-nano',
    this.backTranslateSource = true,
    this.backTranslateTarget = true,
    this.showPronunciation = false,
    required this.onDetectModelChanged,
    required this.onBackTranslateSourceChanged,
    required this.onBackTranslateTargetChanged,
    required this.onShowPronunciationChanged,
    required this.promptTemplates,
    required this.onPromptChanged,
    required this.onPromptReset,
    required this.onResetApiKey,
  });

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  bool get _isRt => widget.mode == 'realtime' || widget.mode == 'realtime_dir';
  late final TextEditingController _translationPromptController;
  late final TextEditingController _assistantPromptController;
  late final TextEditingController _ttsPromptController;
  late final TextEditingController _realtimePromptController;
  late final TextEditingController _directionalPromptController;
  late final TextEditingController _postProcessPromptController;

  @override
  void initState() {
    super.initState();
    _translationPromptController = TextEditingController(text: widget.promptTemplates.translationSystem);
    _assistantPromptController = TextEditingController(text: widget.promptTemplates.assistantSystem);
    _ttsPromptController = TextEditingController(text: widget.promptTemplates.ttsInstructions);
    _realtimePromptController = TextEditingController(text: widget.promptTemplates.realtimeTranslation);
    _directionalPromptController = TextEditingController(text: widget.promptTemplates.realtimeDirectional);
    _postProcessPromptController = TextEditingController(text: widget.promptTemplates.postProcess);
  }

  @override
  void didUpdateWidget(covariant SettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController(_translationPromptController, widget.promptTemplates.translationSystem);
    _syncController(_assistantPromptController, widget.promptTemplates.assistantSystem);
    _syncController(_ttsPromptController, widget.promptTemplates.ttsInstructions);
    _syncController(_realtimePromptController, widget.promptTemplates.realtimeTranslation);
    _syncController(_directionalPromptController, widget.promptTemplates.realtimeDirectional);
    _syncController(_postProcessPromptController, widget.promptTemplates.postProcess);
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    _translationPromptController.dispose();
    _assistantPromptController.dispose();
    _ttsPromptController.dispose();
    _realtimePromptController.dispose();
    _directionalPromptController.dispose();
    _postProcessPromptController.dispose();
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
                  width: 40, height: 4,
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
                  const Text('설정', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('닫기'),
                  ),
                ],
              ),
              const Divider(height: 8),

              // === 언어 ===
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
                selected: {widget.displayMode},
                onSelectionChanged: (v) => widget.onDisplayModeChanged(v.first),
                style: SegmentedButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.displayMode == 'face'
                    ? '상대방 화면이 180° 회전 (테이블에 놓고 대화)'
                    : '양쪽 화면이 같은 방향 (내가 둘 다 봄)',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),

              // === 모드 ===
              _sectionTitle('모드 / 모델'),
              _dropdownTile('모드', widget.mode, {
                'openai': 'Ping-Pong',
                'realtime': 'Realtime',
                'realtime_dir': 'Realtime (방향)',
              }, widget.onModeChanged),
              if (_isRt)
                _dropdownTile('RT 모델', widget.realtimeModel, {
                  'gpt-realtime-mini': 'mini',
                  'gpt-realtime': 'standard',
                  'gpt-realtime-1.5': '1.5',
                }, widget.onRealtimeModelChanged)
              else
                _dropdownTile('번역 모델', widget.model, SettingsSheet._chatModels, widget.onModelChanged),
              if (!_isRt) ...[
                _switchTile('대화 맥락 주입', widget.translationContext, widget.onTranslationContextChanged),
                _dropdownTile('Temperature', widget.translationTemp.toString(), SettingsSheet._tempOptions, (v) => widget.onTranslationTempChanged(double.parse(v))),
              ],
              _dropdownTile('번역 톤', widget.toneMode, {
                'normal': '기본',
                'polite': '예의',
                'casual': '친구',
              }, widget.onToneModeChanged),
              if (widget.realtimeActive)
                const Padding(
                  padding: EdgeInsets.only(left: 80, bottom: 4),
                  child: Text('⟳ Realtime 재시작 시 적용', style: TextStyle(fontSize: 10, color: Colors.orange)),
                ),
              const SizedBox(height: 12),

              // === AI 어시스턴트 ===
              _sectionTitle('AI 어시스턴트'),
              _dropdownTile('AI 모델', widget.aiModel, SettingsSheet._chatModels, widget.onAiModelChanged),
              _dropdownTile('AI 묵음', widget.aiPauseSeconds.toString(), {
                '1': '1s',
                '2': '2s',
                '3': '3s',
                '5': '5s',
                '7': '7s',
                '10': '10s',
                '30': 'OFF',
              }, (v) => widget.onAiPauseSecondsChanged(int.parse(v))),
              const SizedBox(height: 12),

              // === 역번역 / 발음 ===
              _sectionTitle('역번역 / 발음'),
              _switchTile('${srcLang.name} 역번역', widget.backTranslateSource, widget.onBackTranslateSourceChanged),
              _switchTile('${tgtLang.name} 역번역', widget.backTranslateTarget, widget.onBackTranslateTargetChanged),
              _switchTile('한국어 발음 표시', widget.showPronunciation, widget.onShowPronunciationChanged),
              if (_isRt) ...[
                _dropdownTile('탐지 모델', widget.detectModel, SettingsSheet._chatModels, widget.onDetectModelChanged),
                _dropdownTile('분류 Temp', widget.classifyTemp.toString(), SettingsSheet._tempOptions, (v) => widget.onClassifyTempChanged(double.parse(v))),
              ],
              _dropdownTile('발음 Temp', widget.pronunciationTemp.toString(), SettingsSheet._tempOptions, (v) => widget.onPronunciationTempChanged(double.parse(v))),
              const SizedBox(height: 12),

              // === 음성 출력 ===
              _sectionTitle('음성 출력'),
              if (widget.mode == 'realtime_dir') ...[
                _switchTile('${srcLang.name} 번역 TTS', widget.ttsSourceEnabled, widget.onTtsSourceChanged),
                _switchTile('${tgtLang.name} 번역 TTS', widget.ttsTargetEnabled, widget.onTtsTargetChanged),
                _dropdownTile('RT 음성', widget.realtimeVoice, {'coral': '여', 'ash': '남', 'sage': '중성', 'verse': '부드러움'}, widget.onRealtimeVoiceChanged),
                if (widget.realtimeActive)
                  const Padding(
                    padding: EdgeInsets.only(left: 80, bottom: 4),
                    child: Text('⟳ Realtime 재시작 시 적용', style: TextStyle(fontSize: 10, color: Colors.orange)),
                  ),
              ] else if (widget.mode == 'realtime') ...[
                _switchTile('음성 출력', widget.ttsTargetEnabled, widget.onTtsTargetChanged),
                _dropdownTile('RT 음성', widget.realtimeVoice, {'coral': '여', 'ash': '남', 'sage': '중성', 'verse': '부드러움'}, widget.onRealtimeVoiceChanged),
                if (widget.realtimeActive)
                  const Padding(
                    padding: EdgeInsets.only(left: 80, bottom: 4),
                    child: Text('⟳ Realtime 재시작 시 적용', style: TextStyle(fontSize: 10, color: Colors.orange)),
                  ),
              ] else ...[
                _switchTile('${srcLang.name} TTS', widget.ttsSourceEnabled, widget.onTtsSourceChanged),
                if (widget.ttsSourceEnabled)
                  _dropdownTile('음성', widget.voiceSource, {'nova': '여', 'onyx': '남', 'ash': '남2', 'coral': '여2'}, widget.onVoiceSourceChanged),
                _switchTile('${tgtLang.name} TTS', widget.ttsTargetEnabled, widget.onTtsTargetChanged),
                if (widget.ttsTargetEnabled)
                  _dropdownTile('음성', widget.voiceTarget, {'nova': '여', 'onyx': '남', 'ash': '남2', 'coral': '여2'}, widget.onVoiceTargetChanged),
              ],
              _dropdownTile('크기', widget.fontSize.toInt().toString(), {
                '12': '12', '14': '14', '16': '16', '18': '18',
                '20': '20', '24': '24', '28': '28', '32': '32',
              }, (v) => widget.onFontSizeChanged(double.parse(v))),
              // TTS speed (legacy browser mode removed)
              const SizedBox(height: 12),

              // === 입력 감지 ===
              if (!_isRt) ...[
                _sectionTitle('입력 감지'),
                _dropdownTile('묵음 타임아웃', widget.pauseSeconds.toString(), {
                  '1': '1s', '2': '2s', '3': '3s', '5': '5s', '7': '7s', '30': 'OFF',
                }, (v) => widget.onPauseSecondsChanged(int.parse(v))),
                if (widget.mode == 'openai')
                  _dropdownTile('소음 기준', widget.noiseThreshold.toInt().toString(), {
                    '-20': '-20 (시끄러운 환경)',
                    '-30': '-30',
                    '-40': '-40',
                    '-50': '-50',
                    '-60': '-60 (웹 기본)',
                    '-70': '-70',
                    '-80': '-80 (조용한 환경)',
                  }, (v) => widget.onNoiseThresholdChanged(double.parse(v))),
              ],
              if (_isRt) ...[
                _sectionTitle('Realtime 설정'),
                _dropdownTile('VAD 감도', widget.vadThreshold.toString(), {
                  '0.3': '0.3', '0.5': '0.5', '0.7': '0.7',
                  '0.8': '0.8', '0.9': '0.9', '0.95': '0.95',
                }, (v) => widget.onVadThresholdChanged(double.parse(v))),
                _switchTile('대화 기록 삭제', widget.deleteConversationItems, widget.onDeleteConversationItemsChanged),
                _switchTile('Few-shot 주입', widget.injectFewShot, widget.onInjectFewShotChanged),
              ],
              const SizedBox(height: 12),

              // === 프롬프트 ===
              _sectionTitle('프롬프트'),
              const Text(
                '사용 가능한 placeholder: {{SOURCE_LANG}}, {{TARGET_LANG}}, {{TONE_INSTRUCTION}}, {{CONTEXT_INSTRUCTION}}',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              _promptEditor(
                title: 'translationSystem',
                storageKey: AppPrompts.translationSystemKey,
                controller: _translationPromptController,
                onChanged: widget.onPromptChanged,
                onReset: widget.onPromptReset,
                defaultValue: AppPrompts.defaults.translationSystem,
              ),
              _promptEditor(
                title: 'assistantSystem',
                storageKey: AppPrompts.assistantSystemKey,
                controller: _assistantPromptController,
                onChanged: widget.onPromptChanged,
                onReset: widget.onPromptReset,
                defaultValue: AppPrompts.defaults.assistantSystem,
              ),
              _promptEditor(
                title: 'ttsInstructions',
                storageKey: AppPrompts.ttsInstructionsKey,
                controller: _ttsPromptController,
                onChanged: widget.onPromptChanged,
                onReset: widget.onPromptReset,
                defaultValue: AppPrompts.defaults.ttsInstructions,
              ),
              _promptEditor(
                title: 'realtimeTranslation',
                storageKey: AppPrompts.realtimeTranslationKey,
                controller: _realtimePromptController,
                onChanged: widget.onPromptChanged,
                onReset: widget.onPromptReset,
                defaultValue: AppPrompts.defaults.realtimeTranslation,
              ),
              _promptEditor(
                title: 'realtimeDirectional',
                storageKey: AppPrompts.realtimeDirectionalKey,
                controller: _directionalPromptController,
                onChanged: widget.onPromptChanged,
                onReset: widget.onPromptReset,
                defaultValue: AppPrompts.defaults.realtimeDirectional,
              ),
              _promptEditor(
                title: 'postProcess',
                storageKey: AppPrompts.postProcessKey,
                controller: _postProcessPromptController,
                onChanged: widget.onPromptChanged,
                onReset: widget.onPromptReset,
                defaultValue: AppPrompts.defaults.postProcess,
              ),
              if (widget.realtimeActive)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('Realtime 프롬프트 수정은 다음 Realtime 시작부터 적용됩니다.', style: TextStyle(fontSize: 10, color: Colors.orange)),
                ),
              const SizedBox(height: 12),

              // === 기타 ===
              _sectionTitle('기타'),
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
      child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF4A90D9))),
    );
  }

  Widget _langSelector(String label, String current, ValueChanged<String> onChanged) {
    return Row(
      children: [
        SizedBox(width: 40, child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey))),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: supportedLanguages.map((lang) {
              final selected = lang.code == current;
              return ChoiceChip(
                label: Text(lang.name, style: TextStyle(fontSize: 11)),
                selected: selected,
                onSelected: (_) => onChanged(lang.code),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                labelPadding: const EdgeInsets.symmetric(horizontal: 6),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _dropdownTile(String label, String value, Map<String, String> items, ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: items.containsKey(value) ? value : items.keys.first,
              items: items.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: const TextStyle(fontSize: 12)))).toList(),
              onChanged: (v) { if (v != null) onChanged(v); },
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(),
              ),
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
                child: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
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
