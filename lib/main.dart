import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/translator_screen.dart';

const _builtInKey = String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Resolve API key before building the app
  String? apiKey;
  if (_builtInKey.isNotEmpty) {
    apiKey = _builtInKey;
  } else {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('openai_api_key') ?? '';
    if (saved.isNotEmpty) apiKey = saved;
  }

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

  Future<void> _saveAndGo() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('openai_api_key', key);
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => TranslatorScreen(apiKey: key)),
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
