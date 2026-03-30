import 'package:flutter/material.dart';
import '../models/language.dart';

class SettingsSheet extends StatelessWidget {
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
  final String aiModel;
  final int aiPauseSeconds;
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
    required this.aiModel,
    required this.aiPauseSeconds,
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
    required this.onResetApiKey,
  });

  @override
  Widget build(BuildContext context) {
    final srcLang = getLangByCode(sourceLang);
    final tgtLang = getLangByCode(targetLang);

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
              _langSelector('소스', sourceLang, onSourceLangChanged),
              const SizedBox(height: 8),
              _langSelector('타겟', targetLang, onTargetLangChanged),
              // Swap button
              Center(
                child: IconButton(
                  icon: const Icon(Icons.swap_vert, size: 20),
                  onPressed: () {
                    onSourceLangChanged(targetLang);
                    onTargetLangChanged(sourceLang);
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
                selected: {displayMode},
                onSelectionChanged: (v) => onDisplayModeChanged(v.first),
                style: SegmentedButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                displayMode == 'face'
                    ? '상대방 화면이 180° 회전 (테이블에 놓고 대화)'
                    : '양쪽 화면이 같은 방향 (내가 둘 다 봄)',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),

              // === 모드 ===
              _sectionTitle('모드 / 모델'),
              _dropdownTile('모드', mode, {
                'browser': '브라우저',
                'openai': 'OpenAI',
                'realtime': 'Realtime',
              }, onModeChanged),
              if (mode == 'realtime')
                _dropdownTile('RT 모델', realtimeModel, {
                  'gpt-realtime-mini': 'mini',
                  'gpt-realtime': 'standard',
                  'gpt-realtime-1.5': '1.5',
                }, onRealtimeModelChanged)
              else
                _dropdownTile('번역 모델', model, {
                  'gpt-4.1-nano': '4.1-nano',
                  'gpt-4.1-mini': '4.1-mini',
                  'gpt-5.4-nano': '5.4-nano',
                  'gpt-5.4-mini': '5.4-mini',
                  'gpt-5.4': '5.4',
                }, onModelChanged),
              const SizedBox(height: 12),

              // === AI 어시스턴트 ===
              _sectionTitle('AI 어시스턴트'),
              _dropdownTile('AI 모델', aiModel, {
                'gpt-4.1-nano': '4.1-nano',
                'gpt-4.1-mini': '4.1-mini',
                'gpt-5.4-nano': '5.4-nano',
                'gpt-5.4-mini': '5.4-mini',
                'gpt-5.4': '5.4',
              }, onAiModelChanged),
              _dropdownTile('AI 묵음', aiPauseSeconds.toString(), {
                '1': '1s',
                '2': '2s',
                '3': '3s',
                '5': '5s',
                '7': '7s',
                '10': '10s',
                '30': 'OFF',
              }, (v) => onAiPauseSecondsChanged(int.parse(v))),
              const SizedBox(height: 12),

              // === 음성 출력 ===
              _sectionTitle('음성 출력'),
              _switchTile('${srcLang.name} TTS', ttsSourceEnabled, onTtsSourceChanged),
              if (ttsSourceEnabled)
                _dropdownTile('음성', voiceSource, {'nova': '여', 'onyx': '남', 'ash': '남2', 'coral': '여2'}, onVoiceSourceChanged),
              _switchTile('${tgtLang.name} TTS', ttsTargetEnabled, onTtsTargetChanged),
              if (ttsTargetEnabled)
                _dropdownTile('음성', voiceTarget, {'nova': '여', 'onyx': '남', 'ash': '남2', 'coral': '여2'}, onVoiceTargetChanged),
              _dropdownTile('크기', fontSize.toInt().toString(), {
                '12': '12', '14': '14', '16': '16', '18': '18',
                '20': '20', '24': '24', '28': '28', '32': '32',
              }, (v) => onFontSizeChanged(double.parse(v))),
              if (mode == 'browser')
                _dropdownTile('속도', ttsSpeed.toString(), {
                  '0.5': '0.5x', '0.75': '0.75x', '1.0': '1x', '1.25': '1.25x', '1.5': '1.5x',
                }, (v) => onTtsSpeedChanged(double.parse(v))),
              const SizedBox(height: 12),

              // === 입력 감지 ===
              if (mode != 'realtime') ...[
                _sectionTitle('입력 감지'),
                _dropdownTile('묵음 타임아웃', pauseSeconds.toString(), {
                  '1': '1s', '2': '2s', '3': '3s', '5': '5s', '7': '7s', '30': 'OFF',
                }, (v) => onPauseSecondsChanged(int.parse(v))),
                if (mode == 'openai')
                  _dropdownTile('소음 기준', noiseThreshold.toInt().toString(), {
                    '-20': '높음 (시끄러운 환경)',
                    '-30': '보통',
                    '-40': '낮음',
                    '-50': '조용한 환경',
                  }, (v) => onNoiseThresholdChanged(double.parse(v))),
              ],
              if (mode == 'realtime') ...[
                _sectionTitle('Realtime 설정'),
                _dropdownTile('VAD 감도', vadThreshold.toString(), {
                  '0.3': '0.3', '0.5': '0.5', '0.7': '0.7',
                  '0.8': '0.8', '0.9': '0.9', '0.95': '0.95',
                }, (v) => onVadThresholdChanged(double.parse(v))),
              ],
              const SizedBox(height: 12),

              // === 기타 ===
              _sectionTitle('기타'),
              ListTile(
                leading: const Icon(Icons.key_off, color: Colors.red),
                title: const Text('API 키 초기화'),
                subtitle: const Text('저장된 키를 삭제하고 입력 화면으로'),
                onTap: onResetApiKey,
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
}
