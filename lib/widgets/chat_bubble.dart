import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

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
  final String sourceLang;

  const ChatBubble({
    super.key,
    required this.message,
    this.onReplay,
    this.fontSize = 16,
    this.sourceLang = 'ko',
  });

  static const _latinLangs = {'en', 'de', 'fr', 'vi'};

  bool get _isLatinPair {
    final parts = message.direction.split('2');
    final from = parts.isNotEmpty ? parts[0] : '';
    final to = parts.length > 1 ? parts[1] : '';
    return _latinLangs.contains(from) && _latinLangs.contains(to);
  }

  @override
  Widget build(BuildContext context) {
    if (message.isAI) return _buildAIBubble(context);
    if (_isLatinPair) return _buildNeutralBubble(context);

    final parts = message.direction.split('2');
    final fromLang = parts.isNotEmpty ? parts[0] : '';
    final toLang = parts.length > 1 ? parts[1] : '';
    final label = '${fromLang.toUpperCase()}→${toLang.toUpperCase()}';

    final isFromSource = fromLang == sourceLang;
    final accentColor = isFromSource
        ? const Color(0xFF4A90D9)
        : const Color(0xFFE85D75);
    final cardColor = isFromSource
        ? const Color(0xFFEBF4FF)
        : const Color(0xFFFFF0F3);

    return Align(
      alignment: isFromSource ? Alignment.centerRight : Alignment.centerLeft,
      child: IntrinsicWidth(
        child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
          minWidth: 100,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(isFromSource ? 12 : 2),
            topRight: Radius.circular(isFromSource ? 2 : 12),
            bottomLeft: const Radius.circular(12),
            bottomRight: const Radius.circular(12),
          ),
          border: Border.all(color: accentColor.withOpacity(0.2), width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // === Header: label + original (small) ===
            Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              color: accentColor.withOpacity(0.1),
              child: Column(
                crossAxisAlignment: isFromSource
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: fontSize * 0.45,
                          fontWeight: FontWeight.w700,
                          color: accentColor.withOpacity(0.6),
                          letterSpacing: 0.8,
                        ),
                      ),
                      if (onReplay != null) ...[
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: onReplay,
                          child: Icon(Icons.volume_up, size: 13, color: accentColor.withOpacity(0.5)),
                        ),
                      ],
                    ],
                  ),
                  // Show original only if different from translated
                  if (message.original != message.translated) ...[
                    const SizedBox(height: 2),
                    SelectableText(
                      message.original,
                      style: TextStyle(
                        fontSize: fontSize * 0.7,
                        color: accentColor.withOpacity(0.65),
                      ),
                      textAlign: isFromSource ? TextAlign.right : TextAlign.left,
                    ),
                  ],
                ],
              ),
            ),

            // === Translation (large) ===
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              color: cardColor,
              child: Column(
                crossAxisAlignment: isFromSource
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    message.translated,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF1A202C),
                    ),
                    textAlign: isFromSource ? TextAlign.right : TextAlign.left,
                  ),
                  if (message.backTranslation != null) ...[
                    const SizedBox(height: 3),
                    SelectableText(
                      message.backTranslation!,
                      style: TextStyle(
                        fontSize: fontSize * 0.6,
                        color: const Color(0xFF718096),
                      ),
                      textAlign: isFromSource ? TextAlign.right : TextAlign.left,
                    ),
                  ],
                  if (message.pronunciation != null) ...[
                    const SizedBox(height: 2),
                    SelectableText(
                      message.pronunciation!,
                      style: TextStyle(
                        fontSize: fontSize * 0.55,
                        fontStyle: FontStyle.italic,
                        color: const Color(0xFF9B59B6), // purple for pronunciation
                      ),
                      textAlign: isFromSource ? TextAlign.right : TextAlign.left,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }

  /// Latin+Latin 쌍: 방향 구분 불가 → 행 전체 너비, 중성 색상
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
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            color: accentColor.withOpacity(0.08),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: fontSize * 0.45,
                        fontWeight: FontWeight.w700,
                        color: accentColor.withOpacity(0.6),
                        letterSpacing: 0.8,
                      ),
                    ),
                    if (onReplay != null) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: onReplay,
                        child: Icon(Icons.volume_up, size: 13, color: accentColor.withOpacity(0.5)),
                      ),
                    ],
                  ],
                ),
                if (message.original != message.translated) ...[
                  const SizedBox(height: 2),
                  SelectableText(
                    message.original,
                    style: TextStyle(
                      fontSize: fontSize * 0.7,
                      color: accentColor.withOpacity(0.65),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Translation
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            color: cardColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  message.translated,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF1A202C),
                  ),
                ),
                if (message.backTranslation != null) ...[
                  const SizedBox(height: 3),
                  SelectableText(
                    message.backTranslation!,
                    style: TextStyle(
                      fontSize: fontSize * 0.6,
                      color: const Color(0xFF718096),
                    ),
                  ),
                ],
                if (message.pronunciation != null) ...[
                  const SizedBox(height: 2),
                  SelectableText(
                    message.pronunciation!,
                    style: TextStyle(
                      fontSize: fontSize * 0.55,
                      fontStyle: FontStyle.italic,
                      color: const Color(0xFF9B59B6),
                    ),
                  ),
                ],
              ],
            ),
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
          // Question (small, right-aligned)
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
                style: TextStyle(fontSize: fontSize * 0.75, color: Colors.grey.shade700),
                textAlign: TextAlign.right,
              ),
            ),
          ),
          const SizedBox(height: 4),
          // AI Answer (left-aligned, distinct style)
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.85,
              ),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F3FF), // light purple
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.smart_toy, size: 14, color: const Color(0xFF8B5CF6)),
                      const SizedBox(width: 4),
                      Text('AI', style: TextStyle(
                        fontSize: fontSize * 0.5,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF8B5CF6),
                      )),
                    ],
                  ),
                  const SizedBox(height: 4),
                  MarkdownBody(
                    data: message.translated,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(fontSize: fontSize * 0.85, color: const Color(0xFF1A202C), height: 1.4),
                      strong: TextStyle(fontSize: fontSize * 0.85, fontWeight: FontWeight.bold, color: const Color(0xFF1A202C)),
                      listBullet: TextStyle(fontSize: fontSize * 0.85, color: const Color(0xFF1A202C)),
                      code: TextStyle(fontSize: fontSize * 0.75, backgroundColor: Colors.grey.shade200),
                      blockSpacing: 8,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
