import 'package:flutter/material.dart';

class ChatMessage {
  final String original;
  final String translated;
  final String? backTranslation;
  final String direction; // 'ko2ja' or 'ja2ko'

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

  const ChatBubble({
    super.key,
    required this.message,
    this.onReplay,
    this.fontSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    final isKo = message.direction == 'ko2ja';
    final color = isKo ? const Color(0xFF4A90D9) : const Color(0xFFE85D75);
    final label = isKo ? 'KO→JA' : 'JA→KO';

    return Align(
      alignment: isKo ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isKo ? 4 : 14),
            bottomRight: Radius.circular(isKo ? 14 : 4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: fontSize * 0.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white70,
                  ),
                ),
                const Spacer(),
                if (onReplay != null)
                  GestureDetector(
                    onTap: onReplay,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(
                        Icons.volume_up,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              message.original,
              style: TextStyle(
                fontSize: fontSize * 0.85,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              height: 1,
              color: Colors.white30,
            ),
            Text(
              message.translated,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
            if (message.backTranslation != null) ...[
              const SizedBox(height: 4),
              Text(
                '(${message.backTranslation})',
                style: TextStyle(
                  fontSize: fontSize * 0.7,
                  fontStyle: FontStyle.italic,
                  color: Colors.white70,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
