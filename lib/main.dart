import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/translator_screen.dart';

const _builtInKey = String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
const _storage = FlutterSecureStorage();

Future<String?> _loadApiKey() async {
  if (_builtInKey.isNotEmpty) return _builtInKey;

  // Try secure storage first (Android/iOS)
  if (!kIsWeb) {
    final secure = await _storage.read(key: 'openai_api_key');
    if (secure != null && secure.isNotEmpty) return secure;
  }

  // Fallback to SharedPreferences (web)
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('openai_api_key') ?? '';
  return saved.isNotEmpty ? saved : null;
}

Future<void> saveApiKey(String key) async {
  if (kIsWeb) {
    // Web: no secure storage, use SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('openai_api_key', key);
  } else {
    // Android/iOS: secure storage only, no SharedPreferences
    await _storage.write(key: 'openai_api_key', value: key);
  }
}

Future<void> clearApiKey() async {
  if (kIsWeb) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('openai_api_key');
  } else {
    await _storage.delete(key: 'openai_api_key');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final apiKey = await _loadApiKey();
  runApp(KoJaApp(apiKey: apiKey));
}

class KoJaApp extends StatelessWidget {
  final String? apiKey;
  const KoJaApp({super.key, this.apiKey});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KO⇄JA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A90D9)),
        useMaterial3: true,
      ),
      home: apiKey != null
          ? TranslatorScreen(apiKey: apiKey!)
          : const ApiKeyScreen(),
    );
  }
}

class ApiKeyScreen extends StatefulWidget {
  const ApiKeyScreen({super.key});

  @override
  State<ApiKeyScreen> createState() => _ApiKeyScreenState();
}

class _ApiKeyScreenState extends State<ApiKeyScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveAndGo() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    await saveApiKey(key);
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => TranslatorScreen(apiKey: key)),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('KO ⇄ JA', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                decoration: InputDecoration(
                  hintText: 'OpenAI API Key',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saveAndGo,
                  child: const Text('시작'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
