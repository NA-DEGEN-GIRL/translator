import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/translator_screen.dart';

const _builtInKey = String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
const _builtInGoogleKey = String.fromEnvironment(
  'GOOGLE_API_KEY',
  defaultValue: '',
);
const _storage = FlutterSecureStorage();
Future<SharedPreferences>? _prefsFuture;

Future<SharedPreferences> _prefs() {
  final current = _prefsFuture;
  if (current != null) return current;
  return _prefsFuture = SharedPreferences.getInstance();
}

Future<String?> _loadApiKey() async {
  if (_builtInKey.isNotEmpty) return _builtInKey;

  // Try secure storage first (Android/iOS)
  if (!kIsWeb) {
    final secure = await _storage.read(key: 'openai_api_key');
    if (secure != null && secure.isNotEmpty) return secure;
  }

  // Fallback to SharedPreferences (web)
  final prefs = await _prefs();
  final saved = prefs.getString('openai_api_key') ?? '';
  return saved.isNotEmpty ? saved : null;
}

Future<void> saveApiKey(String key) async {
  if (kIsWeb) {
    // Web: no secure storage, use SharedPreferences
    final prefs = await _prefs();
    await prefs.setString('openai_api_key', key);
  } else {
    // Android/iOS: secure storage only, no SharedPreferences
    await _storage.write(key: 'openai_api_key', value: key);
  }
}

Future<void> clearApiKey() async {
  if (kIsWeb) {
    final prefs = await _prefs();
    await prefs.remove('openai_api_key');
  } else {
    await _storage.delete(key: 'openai_api_key');
  }
}

// Google(Gemini) 키는 실시간 통역에서만 쓰이는 선택값 — 앱 진입을 막지 않는다.
Future<String?> loadGoogleApiKey() async {
  if (_builtInGoogleKey.isNotEmpty) return _builtInGoogleKey;
  if (!kIsWeb) {
    final secure = await _storage.read(key: 'google_api_key');
    if (secure != null && secure.isNotEmpty) return secure;
  }
  final prefs = await _prefs();
  final saved = prefs.getString('google_api_key') ?? '';
  return saved.isNotEmpty ? saved : null;
}

Future<void> saveGoogleApiKey(String key) async {
  if (kIsWeb) {
    final prefs = await _prefs();
    await prefs.setString('google_api_key', key);
  } else {
    await _storage.write(key: 'google_api_key', value: key);
  }
}

Future<void> clearGoogleApiKey() async {
  if (kIsWeb) {
    final prefs = await _prefs();
    await prefs.remove('google_api_key');
  } else {
    await _storage.delete(key: 'google_api_key');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final apiKey = await _loadApiKey();
  final googleApiKey = await loadGoogleApiKey();
  runApp(KoJaApp(apiKey: apiKey, googleApiKey: googleApiKey));
}

class KoJaApp extends StatelessWidget {
  final String? apiKey;
  final String? googleApiKey;
  const KoJaApp({super.key, this.apiKey, this.googleApiKey});

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
          ? TranslatorScreen(apiKey: apiKey!, googleApiKey: googleApiKey)
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
    final googleApiKey = await loadGoogleApiKey();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) =>
              TranslatorScreen(apiKey: key, googleApiKey: googleApiKey),
        ),
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
              const Text(
                'KO ⇄ JA',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                decoration: InputDecoration(
                  hintText: 'OpenAI API Key',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
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
