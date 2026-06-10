import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

class LocalTranslationService {
  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();
  final Map<String, OnDeviceTranslator> _translators = {};
  final Set<String> _downloadedModels = {};

  bool get isSupportedPlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool supportsLanguageCode(String code) => _languageForCode(code) != null;

  Future<String> translate(
    String text, {
    required String sourceLangCode,
    required String targetLangCode,
  }) async {
    if (!isSupportedPlatform) {
      throw UnsupportedError(
        'ML Kit local translation is available only on Android/iOS',
      );
    }
    final source = _languageForCode(sourceLangCode);
    final target = _languageForCode(targetLangCode);
    if (source == null || target == null) {
      throw UnsupportedError(
        'Unsupported ML Kit language pair: $sourceLangCode->$targetLangCode',
      );
    }
    final normalizedText = text.trim();
    if (normalizedText.isEmpty || source == target) return normalizedText;

    await Future.wait([_ensureModel(source), _ensureModel(target)]);
    final translator = _translatorFor(source, target);
    return translator.translateText(normalizedText);
  }

  Future<void> dispose() async {
    final translators = _translators.values.toList();
    _translators.clear();
    await Future.wait([
      for (final translator in translators)
        translator.close().catchError((_) {}),
    ]);
  }

  Future<void> _ensureModel(TranslateLanguage language) async {
    final model = language.bcpCode;
    if (_downloadedModels.contains(model)) return;
    final downloaded = await _modelManager.isModelDownloaded(model);
    if (!downloaded) {
      await _modelManager.downloadModel(model, isWifiRequired: false);
    }
    _downloadedModels.add(model);
  }

  OnDeviceTranslator _translatorFor(
    TranslateLanguage source,
    TranslateLanguage target,
  ) {
    final key = '${source.bcpCode}->${target.bcpCode}';
    return _translators[key] ??= OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );
  }

  TranslateLanguage? _languageForCode(String code) {
    final normalized = code.toLowerCase().split('-').first;
    return switch (normalized) {
      'ko' => TranslateLanguage.korean,
      'ja' => TranslateLanguage.japanese,
      'zh' => TranslateLanguage.chinese,
      'en' => TranslateLanguage.english,
      'de' => TranslateLanguage.german,
      'fr' => TranslateLanguage.french,
      'vi' => TranslateLanguage.vietnamese,
      'ru' => TranslateLanguage.russian,
      _ => null,
    };
  }
}
