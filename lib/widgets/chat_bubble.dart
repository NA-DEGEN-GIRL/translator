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

    // Color: source language = blue, target language = red
    final isFromSource = fromLang == sourceLang;
    final accentColor = isFromSource
        ? const Color(0xFF4A90D9)
        : const Color(0xFFE85D75);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // === Source bubble (colored) ===
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(2),
                topRight: Radius.circular(12),
                bottomRight: Radius.circular(12),
                bottomLeft: Radius.circular(2),
              ),
              border: Border(
                left: BorderSide(color: accentColor, width: 4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Direction label + replay
                Row(
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: fontSize * 0.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white70,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const Spacer(),
                    if (onReplay != null)
                      GestureDetector(
                        onTap: onReplay,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(Icons.volume_up, size: 14, color: Colors.white),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                // Original text
                SelectableText(
                  message.original,
                  style: TextStyle(
                    fontSize: fontSize * 0.85,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 2),

          // === Translated card (gray) ===
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F4F8),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(0),
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  message.translated,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w400,
                    color: const Color(0xFF2D3748),
                  ),
                ),
                if (message.backTranslation != null) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    '(${message.backTranslation})',
                    style: TextStyle(
                      fontSize: fontSize * 0.7,
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
