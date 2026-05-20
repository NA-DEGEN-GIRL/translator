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

  ChatMessage({
    required this.original,
    required this.translated,
    this.backTranslation,
    this.pronunciation,
    required this.direction,
    this.isAI = false,
    this.turnId,
  });
}

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onReplay;
  final double fontSize;
  final double secondaryFontSize;
  final String sourceLang;
  final String selfLang;
  final String readerLang;
  final bool useRoleLabels;

  const ChatBubble({
    super.key,
    required this.message,
    this.onReplay,
    this.fontSize = 16,
    this.secondaryFontSize = 11,
    this.sourceLang = 'ko',
    this.selfLang = 'ko',
    this.readerLang = 'ko',
    this.useRoleLabels = false,
  });

  static const _latinLangs = {'en', 'de', 'fr', 'vi'};

  bool get _isLatinPair {
    final parts = message.direction.split('2');
    final from = parts.isNotEmpty ? parts[0] : '';
    final to = parts.length > 1 ? parts[1] : '';
    return _latinLangs.contains(from) && _latinLangs.contains(to);
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
    if (_isLatinPair && !useRoleLabels) return _buildNeutralBubble(context);

    final parts = message.direction.split('2');
    final fromLang = parts.isNotEmpty ? parts[0] : '';
    final toLang = parts.length > 1 ? parts[1] : '';

    final isFromSource = fromLang == sourceLang;
    final isSelfSpeaker = fromLang == selfLang;
    final label = useRoleLabels
        ? personLabelForReader(
            isSelf: isSelfSpeaker,
            readerLangCode: readerLang,
          )
        : '${fromLang.toUpperCase()}→${toLang.toUpperCase()}';
    final accentColor = isFromSource
        ? const Color(0xFF4A90D9)
        : const Color(0xFFE85D75);
    final cardColor = isFromSource
        ? const Color(0xFFEBF4FF)
        : const Color(0xFFFFF0F3);

    return Align(
      alignment: isSelfSpeaker ? Alignment.centerRight : Alignment.centerLeft,
      child: IntrinsicWidth(
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.8,
            minWidth: 100,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(isSelfSpeaker ? 12 : 2),
              topRight: Radius.circular(isSelfSpeaker ? 2 : 12),
              bottomLeft: const Radius.circular(12),
              bottomRight: const Radius.circular(12),
            ),
            border: Border.all(color: accentColor.withOpacity(0.2), width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(
                label: label,
                accentColor: accentColor,
                alignEnd: isSelfSpeaker,
              ),
              _buildCopyableTranslation(
                context: context,
                cardColor: cardColor,
                alignEnd: isSelfSpeaker,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader({
    required String label,
    required Color accentColor,
    required bool alignEnd,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      color: accentColor.withOpacity(0.1),
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
                  color: accentColor.withOpacity(0.6),
                  letterSpacing: 0.8,
                ),
              ),
              if (onReplay != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onReplay,
                  child: Icon(
                    Icons.volume_up,
                    size: 13,
                    color: accentColor.withOpacity(0.5),
                  ),
                ),
              ],
            ],
          ),
          if (message.original != message.translated) ...[
            const SizedBox(height: 2),
            SelectableText(
              message.original,
              style: TextStyle(
                fontSize: secondaryFontSize,
                color: accentColor.withOpacity(0.65),
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
    final parts = message.direction.split('2');
    final fromLang = parts.isNotEmpty ? parts[0] : '';
    final toLang = parts.length > 1 ? parts[1] : '';
    final label = '${fromLang.toUpperCase()}⇄${toLang.toUpperCase()}';
    const accentColor = Color(0xFF718096);
    const cardColor = Color(0xFFF7F8FA);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accentColor.withOpacity(0.2), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(label: label, accentColor: accentColor, alignEnd: false),
          _buildCopyableTranslation(
            context: context,
            cardColor: cardColor,
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
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
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
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.85,
                  ),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF8B5CF6).withOpacity(0.3),
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
                        styleSheet: MarkdownStyleSheet(
                          p: TextStyle(
                            fontSize: fontSize * 0.85,
                            color: const Color(0xFF1A202C),
                            height: 1.4,
                          ),
                          strong: TextStyle(
                            fontSize: fontSize * 0.85,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1A202C),
                          ),
                          listBullet: TextStyle(
                            fontSize: fontSize * 0.85,
                            color: const Color(0xFF1A202C),
                          ),
                          code: TextStyle(
                            fontSize: fontSize * 0.75,
                            backgroundColor: Colors.grey.shade200,
                          ),
                          blockSpacing: 8,
                        ),
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
