import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/openai_service.dart';
import '../services/speech_service.dart';
import '../widgets/chat_bubble.dart';

class TranslatorScreen extends StatefulWidget {
  final String apiKey;
  const TranslatorScreen({super.key, required this.apiKey});

  @override
  State<TranslatorScreen> createState() => _TranslatorScreenState();
}

class _TranslatorScreenState extends State<TranslatorScreen> {
  late OpenAIService _openai;
  final SpeechService _speech = SpeechService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _myScrollController = ScrollController();
  final ScrollController _mirrorScrollController = ScrollController();

  final List<ChatMessage> _messages = [];
  bool _isListening = false;
  bool _isMirrorListening = false;
  bool _isProcessing = false;
  String _interimText = '';
  String _mirrorInterimText = '';

  // Settings
  String _mode = 'browser'; // browser, openai
  String _model = 'gpt-5.4-nano';
  bool _ttsJaEnabled = false;
  bool _ttsKoEnabled = false;
  String _voiceJa = 'onyx';
  String _voiceKo = 'nova';
  double _fontSize = 16;
  String _micLang = 'ko';

  @override
  void initState() {
    super.initState();
    _openai = OpenAIService(widget.apiKey);
    _speech.initialize();
    _loadSettings();
  }

  @override
  void dispose() {
    _textController.dispose();
    _myScrollController.dispose();
    _mirrorScrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ttsJaEnabled = prefs.getBool('ttsJa') ?? false;
      _ttsKoEnabled = prefs.getBool('ttsKo') ?? false;
      _voiceJa = prefs.getString('voiceJa') ?? 'onyx';
      _voiceKo = prefs.getString('voiceKo') ?? 'nova';
      _fontSize = prefs.getDouble('fontSize') ?? 16;
      _mode = prefs.getString('mode') ?? 'browser';
      _model = prefs.getString('model') ?? 'gpt-5.4-nano';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setBool('ttsJa', _ttsJaEnabled);
    prefs.setBool('ttsKo', _ttsKoEnabled);
    prefs.setString('voiceJa', _voiceJa);
    prefs.setString('voiceKo', _voiceKo);
    prefs.setDouble('fontSize', _fontSize);
    prefs.setString('mode', _mode);
    prefs.setString('model', _model);
  }

  String _detectLang(String text) {
    int ko = 0, ja = 0;
    for (final ch in text.runes) {
      if ((ch >= 0xAC00 && ch <= 0xD7AF) ||
          (ch >= 0x1100 && ch <= 0x11FF) ||
          (ch >= 0x3130 && ch <= 0x318F)) ko++;
      if ((ch >= 0x3040 && ch <= 0x309F) || (ch >= 0x30A0 && ch <= 0x30FF)) {
        ja++;
      }
      if (ch >= 0x4E00 && ch <= 0x9FFF) ja++;
    }
    return ko >= ja ? 'ko' : 'ja';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_myScrollController.hasClients) {
        _myScrollController.animateTo(
          _myScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      if (_mirrorScrollController.hasClients) {
        _mirrorScrollController.animateTo(
          _mirrorScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleTranslation(String text,
      {String? forceDirection}) async {
    if (text.isEmpty || _isProcessing) return;
    setState(() => _isProcessing = true);

    final direction =
        forceDirection ?? (_detectLang(text) == 'ko' ? 'ko2ja' : 'ja2ko');

    try {
      final result = await _openai.translate(text, direction, model: _model);
      final translated = result['translated'] ?? '';

      final msg = ChatMessage(
        original: text,
        translated: translated,
        backTranslation: result['back_translation'],
        direction: direction,
      );

      setState(() {
        _messages.add(msg);
      });
      _scrollToBottom();

      // TTS
      final ttsLang = direction == 'ko2ja' ? 'ja' : 'ko';
      final shouldPlay =
          (ttsLang == 'ja' && _ttsJaEnabled) ||
          (ttsLang == 'ko' && _ttsKoEnabled);

      if (shouldPlay && translated.isNotEmpty) {
        if (_mode == 'browser') {
          await _speech.speak(translated, ttsLang);
        } else {
          await _playOpenAITTS(
              translated, ttsLang, ttsLang == 'ja' ? _voiceJa : _voiceKo);
        }
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _playOpenAITTS(String text, String lang, String voice) async {
    try {
      final audioBytes = await _openai.tts(text, lang, voice: voice);
      await _audioPlayer.play(BytesSource(audioBytes));
    } catch (e) {
      // Fallback to browser TTS
      await _speech.speak(text, lang);
    }
  }

  void _startListening() async {
    if (_isListening || _isProcessing) return;
    if (_isMirrorListening) _stopMirrorListening();

    await _speech.initialize();
    setState(() {
      _isListening = true;
      _interimText = '';
    });

    await _speech.startListening(
      locale: _micLang == 'ko' ? 'ko_KR' : 'ja_JP',
      onResult: (text, isFinal) {
        setState(() => _interimText = text);
        if (isFinal && text.isNotEmpty) {
          _stopListening();
          _handleTranslation(text);
        }
      },
      onDone: () => setState(() => _isListening = false),
    );
  }

  void _stopListening() async {
    await _speech.stopListening();
    setState(() {
      _isListening = false;
      _interimText = '';
    });
  }

  void _startMirrorListening() async {
    if (_isMirrorListening || _isProcessing) return;
    if (_isListening) _stopListening();

    await _speech.initialize();
    setState(() {
      _isMirrorListening = true;
      _mirrorInterimText = '';
    });

    await _speech.startListening(
      locale: 'ja_JP',
      onResult: (text, isFinal) {
        setState(() => _mirrorInterimText = text);
        if (isFinal && text.isNotEmpty) {
          _stopMirrorListening();
          _handleTranslation(text, forceDirection: 'ja2ko');
        }
      },
      onDone: () => setState(() => _isMirrorListening = false),
    );
  }

  void _stopMirrorListening() async {
    await _speech.stopListening();
    setState(() {
      _isMirrorListening = false;
      _mirrorInterimText = '';
    });
  }

  void _sendText() {
    final text = _textController.text.trim();
    if (text.isEmpty || _isProcessing) return;
    _textController.clear();
    _handleTranslation(text);
  }

  void _clearChat() {
    setState(() {
      _messages.clear();
      _interimText = '';
      _mirrorInterimText = '';
    });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  Future<void> _replayMessage(ChatMessage msg) async {
    final lang = msg.direction == 'ko2ja' ? 'ja' : 'ko';
    if (_mode == 'browser') {
      await _speech.speak(msg.translated, lang);
    } else {
      await _playOpenAITTS(
          msg.translated, lang, lang == 'ja' ? _voiceJa : _voiceKo);
    }
  }

  Widget _buildChatList(ScrollController controller) {
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          '한국어 또는 일본어로 입력하세요',
          style: TextStyle(color: Colors.grey, fontSize: 14),
        ),
      );
    }
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return ChatBubble(
          message: msg,
          fontSize: _fontSize,
          onReplay: () => _replayMessage(msg),
        );
      },
    );
  }

  Widget _buildSettingsRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          // Mode
          _buildDropdown<String>(
            value: _mode,
            items: {'browser': '브라우저', 'openai': 'OpenAI'},
            onChanged: (v) => setState(() {
              _mode = v!;
              _saveSettings();
            }),
          ),
          // Model
          _buildDropdown<String>(
            value: _model,
            items: {
              'gpt-4.1-nano': '4.1n',
              'gpt-4.1-mini': '4.1m',
              'gpt-5.4-nano': '5.4n',
              'gpt-5.4-mini': '5.4m',
              'gpt-5.4': '5.4',
            },
            onChanged: (v) => setState(() {
              _model = v!;
              _saveSettings();
            }),
          ),
          // TTS JA
          _buildToggle('J', _ttsJaEnabled, () {
            setState(() => _ttsJaEnabled = !_ttsJaEnabled);
            _saveSettings();
          }),
          // Voice JA
          _buildDropdown<String>(
            value: _voiceJa,
            items: {'onyx': '남', 'coral': '여'},
            onChanged: (v) => setState(() {
              _voiceJa = v!;
              _saveSettings();
            }),
          ),
          // TTS KO
          _buildToggle('K', _ttsKoEnabled, () {
            setState(() => _ttsKoEnabled = !_ttsKoEnabled);
            _saveSettings();
          }),
          // Voice KO
          _buildDropdown<String>(
            value: _voiceKo,
            items: {'nova': '여', 'ash': '남'},
            onChanged: (v) => setState(() {
              _voiceKo = v!;
              _saveSettings();
            }),
          ),
          // Font size
          _buildDropdown<double>(
            value: _fontSize,
            items: {12.0: '12', 14.0: '14', 16.0: '16', 18.0: '18', 20.0: '20', 24.0: '24', 28.0: '28', 32.0: '32'},
            onChanged: (v) => setState(() {
              _fontSize = v!;
              _saveSettings();
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildToggle(String label, bool value, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? Colors.green : Colors.grey.shade300,
              ),
            ),
            const SizedBox(width: 3),
            Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<T>(
        value: value,
        underline: const SizedBox(),
        isDense: true,
        style: const TextStyle(fontSize: 11, color: Colors.black87),
        items: items.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildInputRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Text input
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: '한국어 또는 일본어 입력...',
                  hintStyle: const TextStyle(fontSize: 13),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                style: const TextStyle(fontSize: 14),
                onSubmitted: (_) => _sendText(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Send
          _buildCircleButton(
            icon: Icons.send,
            size: 36,
            color: const Color(0xFF4A90D9),
            onTap: _sendText,
          ),
          const SizedBox(width: 4),
          // Mic
          _buildCircleButton(
            icon: Icons.mic,
            size: 36,
            color: _isListening ? Colors.red : const Color(0xFF4A90D9),
            onTap: _isListening ? _stopListening : _startListening,
          ),
          const SizedBox(width: 4),
          // Language toggle
          GestureDetector(
            onTap: () {
              if (_isListening) return;
              setState(() => _micLang = _micLang == 'ko' ? 'ja' : 'ko');
            },
            child: Container(
              width: 28,
              height: 36,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _micLang == 'ko'
                      ? const Color(0xFF4A90D9)
                      : const Color(0xFFE85D75),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                _micLang.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: _micLang == 'ko'
                      ? const Color(0xFF4A90D9)
                      : const Color(0xFFE85D75),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Clear
          _buildCircleButton(
            icon: Icons.clear_all,
            size: 24,
            color: Colors.grey,
            onTap: _clearChat,
            outlined: true,
          ),
        ],
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required double size,
    required Color color,
    required VoidCallback onTap,
    bool outlined = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: outlined ? Colors.transparent : color,
          border: outlined ? Border.all(color: color) : null,
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: size * 0.5,
          color: outlined ? color : Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // === Mirror half (rotated) ===
            Expanded(
              child: Transform.rotate(
                angle: 3.14159,
                child: Column(
                  children: [
                    // Label
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                      ),
                      child: Text(
                        '韓国語⇄日本語通訳 / 한국어⇄일본어통역',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    // Chat
                    Expanded(child: _buildChatList(_mirrorScrollController)),
                    // Mirror mic
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: Colors.grey.shade300)),
                      ),
                      child: Column(
                        children: [
                          if (_mirrorInterimText.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                _mirrorInterimText,
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildCircleButton(
                                icon: Icons.mic,
                                size: 36,
                                color: _isMirrorListening
                                    ? Colors.red
                                    : const Color(0xFFE85D75),
                                onTap: _isMirrorListening
                                    ? _stopMirrorListening
                                    : _startMirrorListening,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '押して話す→翻訳',
                                style: TextStyle(fontSize: 10, color: Colors.grey),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // === Divider ===
            Container(
              height: 3,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF4A90D9), Color(0xFFE85D75)],
                ),
              ),
            ),
            // === My half ===
            Expanded(
              child: Column(
                children: [
                  // Label
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                    ),
                    child: Text(
                      '한국어⇄일본어통역 / 韓国語⇄日本語通訳',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  // Chat
                  Expanded(child: _buildChatList(_myScrollController)),
                  // Interim text
                  if (_interimText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        _interimText,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  // Processing indicator
                  if (_isProcessing)
                    const Padding(
                      padding: EdgeInsets.all(4),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  // Settings
                  _buildSettingsRow(),
                  // Input
                  _buildInputRow(),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
