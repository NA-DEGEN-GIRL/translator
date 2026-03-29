import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/translator_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KoJaApp());
}

class KoJaApp extends StatelessWidget {
  const KoJaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KO⇄JA Translator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A90D9)),
        useMaterial3: true,
      ),
      home: const ApiKeyScreen(),
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('openai_api_key') ?? '';
    if (key.isNotEmpty) {
      _goToTranslator(key);
    } else {
      setState(() => _loading = false);
    }
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
      MaterialPageRoute(
        builder: (_) => TranslatorScreen(apiKey: key),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

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
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saveAndGo,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('시작', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
