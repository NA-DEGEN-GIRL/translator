import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/translator_screen.dart';

// Build-time injection: flutter run --dart-define=OPENAI_API_KEY=sk-...
// If not provided, shows API key input screen
const _builtInKey = String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KoJaApp());
}

class KoJaApp extends StatelessWidget {
  const KoJaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KO⇄JA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A90D9)),
        useMaterial3: true,
      ),
      home: const EntryScreen(),
    );
  }
}

class EntryScreen extends StatefulWidget {
  const EntryScreen({super.key});

  @override
  State<EntryScreen> createState() => _EntryScreenState();
}

class _EntryScreenState extends State<EntryScreen> {
  final _controller = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 1. Built-in key (from --dart-define)
    if (_builtInKey.isNotEmpty) {
      _goToTranslator(_builtInKey);
      return;
    }
    // 2. Saved key
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('openai_api_key') ?? '';
    if (saved.isNotEmpty) {
      _goToTranslator(saved);
      return;
    }
    // 3. Show input
    setState(() => _loading = false);
  }

  Future<void> _saveAndGo() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('openai_api_key', key);
    _goToTranslator(key);
  }

  void _goToTranslator(String key) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => TranslatorScreen(apiKey: key)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
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
