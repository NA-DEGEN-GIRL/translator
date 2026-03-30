import 'package:flutter/material.dart';

class ChatMessage {
  final String original;
  final String translated;
  final String? backTranslation;
  final String direction; // e.g. 'ko2ja', 'en2ko'

  ChatMessage({
    required this.original,
    required this.translated,
    this.backTranslation,
    required this.direction,
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

  @override
  Widget build(BuildContext context) {
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

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // === Original text (small, muted) ===
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.12),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(2),
                topRight: Radius.circular(10),
              ),
              border: Border(
                left: BorderSide(color: accentColor, width: 4),
              ),
            ),
            child: Row(
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
                const Spacer(),
                if (onReplay != null)
                  GestureDetector(
                    onTap: onReplay,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(Icons.volume_up, size: 13, color: accentColor),
                    ),
                  ),
              ],
            ),
          ),
          // Original text
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.12),
              border: Border(
                left: BorderSide(color: accentColor, width: 4),
              ),
            ),
            child: SelectableText(
              message.original,
              style: TextStyle(
                fontSize: fontSize * 0.7,
                color: accentColor.withOpacity(0.7),
              ),
            ),
          ),

          // === Translation (large, prominent) ===
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(10),
                bottomRight: Radius.circular(10),
              ),
              border: Border(
                left: BorderSide(color: accentColor.withOpacity(0.3), width: 4),
              ),
            ),
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
                  const SizedBox(height: 4),
                  SelectableText(
                    '(${message.backTranslation})',
                    style: TextStyle(
                      fontSize: fontSize * 0.65,
                      fontStyle: FontStyle.italic,
                      color: const Color(0xFF718096),
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
}
