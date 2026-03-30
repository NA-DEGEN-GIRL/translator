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
                      '(${message.backTranslation})',
                      style: TextStyle(
                        fontSize: fontSize * 0.6,
                        fontStyle: FontStyle.italic,
                        color: const Color(0xFF718096),
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
}
