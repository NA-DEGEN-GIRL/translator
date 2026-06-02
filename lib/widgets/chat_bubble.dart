import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/language.dart';

class ChatMessage {
  final String original;
  final String translated;
  final String? backTranslation;
  final String? pronunciation; // Korean pronunciation of foreign text
  final String direction; // e.g. 'ko2ja', 'en2ko', 'ai'
  final bool isAI; // AI assistant response
  final String? turnId; // response_id for Realtime turn mapping
  final String fromLang;
  final String toLang;
  final String directionLabel;
  final String neutralDirectionLabel;
  final double directionLabelWidthUnits;
  final double contentWidthUnits;
  late final Map<String, String> translationContextEntry =
      Map<String, String>.unmodifiable({
        'role': 'user',
        'content': '$original → $translated',
      });
  late final String assistantContextText = isAI
      ? 'Q: $original\nA: $translated'
      : '$direction: $original → $translated';

  factory ChatMessage({
    required String original,
    required String translated,
    String? backTranslation,
    String? pronunciation,
    required String direction,
    bool isAI = false,
    String? turnId,
  }) {
    final parts = _directionParts(direction);
    final directionLabel = _directionLabelFromParts(parts.from, parts.to, '→');
    return ChatMessage._(
      original: original,
      translated: translated,
      backTranslation: backTranslation,
      pronunciation: pronunciation,
      direction: direction,
      isAI: isAI,
      turnId: turnId,
      fromLang: parts.from,
      toLang: parts.to,
      directionLabel: directionLabel,
      neutralDirectionLabel: _directionLabelFromParts(
        parts.from,
        parts.to,
        '⇄',
      ),
      directionLabelWidthUnits: _textUnits(directionLabel),
      contentWidthUnits: _maxContentUnits(
        original: original,
        translated: translated,
        backTranslation: backTranslation,
        pronunciation: pronunciation,
      ),
    );
  }

  ChatMessage._({
    required this.original,
    required this.translated,
    this.backTranslation,
    this.pronunciation,
    required this.direction,
    required this.isAI,
    this.turnId,
    required this.fromLang,
    required this.toLang,
    required this.directionLabel,
    required this.neutralDirectionLabel,
    required this.directionLabelWidthUnits,
    required this.contentWidthUnits,
  });

  static ({String from, String to}) _directionParts(String direction) {
    final separatorIndex = direction.indexOf('2');
    final from = separatorIndex > 0
        ? direction.substring(0, separatorIndex)
        : '';
    final to = separatorIndex >= 0 && separatorIndex < direction.length - 1
        ? direction.substring(separatorIndex + 1)
        : '';
    return (from: from, to: to);
  }

  static String _directionLabelFromParts(
    String from,
    String to,
    String separator,
  ) {
    return '${from.toUpperCase()}$separator${to.toUpperCase()}';
  }

  static double _maxContentUnits({
    required String original,
    required String translated,
    String? backTranslation,
    String? pronunciation,
  }) {
    var maxUnits = _textUnits(translated);
    if (original != translated) {
      final units = _textUnits(original);
      if (units > maxUnits) maxUnits = units;
    }
    if (backTranslation != null) {
      final units = _textUnits(backTranslation);
      if (units > maxUnits) maxUnits = units;
    }
    if (pronunciation != null) {
      final units = _textUnits(pronunciation);
      if (units > maxUnits) maxUnits = units;
    }
    return maxUnits;
  }

  static double _textUnits(String text) {
    var longestLine = 0.0;
    var currentLine = 0.0;
    var currentWord = 0.0;
    var longestWord = 0.0;
    for (final rune in text.runes) {
      if (rune == 0x0A || rune == 0x0D) {
        if (currentLine > longestLine) longestLine = currentLine;
        if (currentWord > longestWord) longestWord = currentWord;
        currentLine = 0;
        currentWord = 0;
        continue;
      }
      final unit = rune <= 0x20
          ? 0.35
          : rune < 0x2E80
          ? 0.56
          : 1.0;
      currentLine += unit;
      if (rune <= 0x20) {
        if (currentWord > longestWord) longestWord = currentWord;
        currentWord = 0;
      } else {
        currentWord += unit;
      }
    }
    if (currentLine > longestLine) longestLine = currentLine;
    if (currentWord > longestWord) longestWord = currentWord;
    return longestLine > longestWord ? longestLine : longestWord;
  }
}

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final ValueChanged<ChatMessage>? onReplay;
  final ValueChanged<ChatMessage>? onRetry;
  final double fontSize;
  final double secondaryFontSize;
  final String sourceLang;
  final String selfLang;
  final String readerLang;
  final bool useRoleLabels;
  final double maxBubbleWidth;
  final double aiQuestionMaxWidth;
  final double aiAnswerMaxWidth;

  const ChatBubble({
    super.key,
    required this.message,
    this.onReplay,
    this.onRetry,
    this.fontSize = 16,
    this.secondaryFontSize = 11,
    this.sourceLang = 'ko',
    this.selfLang = 'ko',
    this.readerLang = 'ko',
    this.useRoleLabels = false,
    required this.maxBubbleWidth,
    required this.aiQuestionMaxWidth,
    required this.aiAnswerMaxWidth,
  });

  static const _latinLangs = {'en', 'de', 'fr', 'vi'};
  static final Map<String, String> _roleLabelCache = {};
  static final Map<String, double> _roleLabelUnitsCache = {};
  static final Map<int, MarkdownStyleSheet> _aiMarkdownStyleCache = {};

  static String _roleLabel({
    required bool isSelf,
    required String readerLangCode,
  }) {
    final key = '${readerLangCode}_${isSelf ? 'self' : 'other'}';
    return _roleLabelCache.putIfAbsent(
      key,
      () =>
          personLabelForReader(isSelf: isSelf, readerLangCode: readerLangCode),
    );
  }

  static double _roleLabelUnits({
    required bool isSelf,
    required String readerLangCode,
  }) {
    final key = '${readerLangCode}_${isSelf ? 'self' : 'other'}';
    return _roleLabelUnitsCache.putIfAbsent(
      key,
      () => ChatMessage._textUnits(
        _roleLabel(isSelf: isSelf, readerLangCode: readerLangCode),
      ),
    );
  }

  static MarkdownStyleSheet _aiMarkdownStyle(double fontSize) {
    final key = (fontSize * 100).round();
    final cached = _aiMarkdownStyleCache[key];
    if (cached != null) return cached;
    if (_aiMarkdownStyleCache.length > 12) _aiMarkdownStyleCache.clear();

    final bodyFontSize = key / 100 * 0.85;
    final style = MarkdownStyleSheet(
      p: TextStyle(
        fontSize: bodyFontSize,
        color: const Color(0xFF1A202C),
        height: 1.4,
      ),
      strong: TextStyle(
        fontSize: bodyFontSize,
        fontWeight: FontWeight.bold,
        color: const Color(0xFF1A202C),
      ),
      listBullet: TextStyle(
        fontSize: bodyFontSize,
        color: const Color(0xFF1A202C),
      ),
      code: TextStyle(
        fontSize: key / 100 * 0.75,
        backgroundColor: const Color(0xFFEEEEEE),
      ),
      blockSpacing: 8,
    );
    _aiMarkdownStyleCache[key] = style;
    return style;
  }

  Future<void> _copyTranslation(BuildContext context) async {
    final text = message.translated.trim();
    if (text.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();

    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, 76),
        duration: Duration(milliseconds: 900),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.copy, color: Colors.white, size: 16),
            SizedBox(width: 8),
            Text('번역 복사됨'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (message.isAI) return _buildAIBubble(context);

    final fromLang = message.fromLang;
    final toLang = message.toLang;
    final isLatinPair =
        _latinLangs.contains(fromLang) && _latinLangs.contains(toLang);
    if (isLatinPair && !useRoleLabels) {
      return _buildNeutralBubble(context);
    }

    final isFromSource = fromLang == sourceLang;
    final isSelfSpeaker = fromLang == selfLang;
    final label = useRoleLabels
        ? _roleLabel(isSelf: isSelfSpeaker, readerLangCode: readerLang)
        : message.directionLabel;
    final labelUnits = useRoleLabels
        ? _roleLabelUnits(isSelf: isSelfSpeaker, readerLangCode: readerLang)
        : message.directionLabelWidthUnits;
    final palette = isFromSource
        ? _BubblePalette.source
        : _BubblePalette.target;
    final bubbleWidth = _estimateBubbleWidth(labelUnits);

    return Align(
      alignment: isSelfSpeaker ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: bubbleWidth,
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(isSelfSpeaker ? 12 : 2),
            topRight: Radius.circular(isSelfSpeaker ? 2 : 12),
            bottomLeft: const Radius.circular(12),
            bottomRight: const Radius.circular(12),
          ),
          border: Border.all(color: palette.border, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(
              label: label,
              palette: palette,
              alignEnd: isSelfSpeaker,
            ),
            _buildCopyableTranslation(
              context: context,
              cardColor: palette.card,
              alignEnd: isSelfSpeaker,
            ),
          ],
        ),
      ),
    );
  }

  double _estimateBubbleWidth(double labelContentUnits) {
    var labelUnits = labelContentUnits + (onReplay == null ? 3 : 5);
    if (onRetry != null) {
      labelUnits +=
          ChatMessage._textUnits(retryLabelForReader(_retryLabelLang)) + 4;
    }
    final maxUnits = labelUnits > message.contentWidthUnits
        ? labelUnits
        : message.contentWidthUnits;
    final estimated = maxUnits * fontSize + 28;
    return estimated.clamp(100.0, maxBubbleWidth).toDouble();
  }

  String get _retryLabelLang =>
      message.fromLang.isEmpty ? readerLang : message.fromLang;

  Widget _buildHeader({
    required String label,
    required _BubblePalette palette,
    required bool alignEnd,
  }) {
    final replay = onReplay;
    final retry = onRetry;
    final retryLabel = retry == null
        ? ''
        : retryLabelForReader(_retryLabelLang);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      color: palette.header,
      child: Column(
        crossAxisAlignment: alignEnd
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: (secondaryFontSize * 0.75)
                      .clamp(8.0, 12.0)
                      .toDouble(),
                  fontWeight: FontWeight.w700,
                  color: palette.label,
                  letterSpacing: 0.8,
                ),
              ),
              if (replay != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => replay(message),
                  child: Icon(Icons.volume_up, size: 13, color: palette.replay),
                ),
              ],
              if (retry != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => retry(message),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.replay.withValues(alpha: 0.14),
                      border: Border.all(
                        color: palette.replay.withValues(alpha: 0.55),
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh, size: 12, color: palette.replay),
                          const SizedBox(width: 3),
                          Text(
                            retryLabel,
                            style: TextStyle(
                              fontSize: (secondaryFontSize * 0.75)
                                  .clamp(8.0, 12.0)
                                  .toDouble(),
                              fontWeight: FontWeight.w800,
                              color: palette.replay,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (message.original.trim().isNotEmpty &&
              message.original != message.translated) ...[
            const SizedBox(height: 2),
            SelectableText(
              message.original,
              style: TextStyle(
                fontSize: secondaryFontSize,
                color: palette.original,
              ),
              textAlign: alignEnd ? TextAlign.right : TextAlign.left,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCopyableTranslation({
    required BuildContext context,
    required Color cardColor,
    required bool alignEnd,
  }) {
    return Material(
      color: cardColor,
      child: InkWell(
        onTap: () => _copyTranslation(context),
        onLongPress: () => _copyTranslation(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            crossAxisAlignment: alignEnd
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                message.translated,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF1A202C),
                ),
                textAlign: alignEnd ? TextAlign.right : TextAlign.left,
              ),
              if (message.backTranslation != null) ...[
                const SizedBox(height: 3),
                SelectableText(
                  message.backTranslation!,
                  style: TextStyle(
                    fontSize: secondaryFontSize,
                    color: const Color(0xFF718096),
                  ),
                  textAlign: alignEnd ? TextAlign.right : TextAlign.left,
                ),
              ],
              if (message.pronunciation != null) ...[
                const SizedBox(height: 2),
                SelectableText(
                  message.pronunciation!,
                  style: TextStyle(
                    fontSize: (secondaryFontSize * 0.92)
                        .clamp(8.0, 20.0)
                        .toDouble(),
                    fontStyle: FontStyle.italic,
                    color: const Color(0xFF9B59B6),
                  ),
                  textAlign: alignEnd ? TextAlign.right : TextAlign.left,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNeutralBubble(BuildContext context) {
    final label = message.neutralDirectionLabel;
    const palette = _BubblePalette.neutral;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(label: label, palette: palette, alignEnd: false),
          _buildCopyableTranslation(
            context: context,
            cardColor: palette.card,
            alignEnd: false,
          ),
        ],
      ),
    );
  }

  Widget _buildAIBubble(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(maxWidth: aiQuestionMaxWidth),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                message.original,
                style: TextStyle(
                  fontSize: secondaryFontSize,
                  color: Colors.grey.shade700,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Material(
              color: const Color(0xFFF5F3FF),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _copyTranslation(context),
                onLongPress: () => _copyTranslation(context),
                child: Container(
                  constraints: BoxConstraints(maxWidth: aiAnswerMaxWidth),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.smart_toy,
                            size: 14,
                            color: const Color(0xFF8B5CF6),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'AI',
                            style: TextStyle(
                              fontSize: fontSize * 0.5,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF8B5CF6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      MarkdownBody(
                        data: message.translated,
                        selectable: true,
                        styleSheet: _aiMarkdownStyle(fontSize),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BubblePalette {
  final Color card;
  final Color border;
  final Color header;
  final Color label;
  final Color replay;
  final Color original;

  const _BubblePalette({
    required this.card,
    required this.border,
    required this.header,
    required this.label,
    required this.replay,
    required this.original,
  });

  static const source = _BubblePalette(
    card: Color(0xFFEBF4FF),
    border: Color(0x334A90D9),
    header: Color(0x1A4A90D9),
    label: Color(0x994A90D9),
    replay: Color(0x804A90D9),
    original: Color(0xA64A90D9),
  );

  static const target = _BubblePalette(
    card: Color(0xFFFFF0F3),
    border: Color(0x33E85D75),
    header: Color(0x1AE85D75),
    label: Color(0x99E85D75),
    replay: Color(0x80E85D75),
    original: Color(0xA6E85D75),
  );

  static const neutral = _BubblePalette(
    card: Color(0xFFF7F8FA),
    border: Color(0x33718096),
    header: Color(0x1A718096),
    label: Color(0x99718096),
    replay: Color(0x80718096),
    original: Color(0xA6718096),
  );
}
