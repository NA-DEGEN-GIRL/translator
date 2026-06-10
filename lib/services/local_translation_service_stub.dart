class LocalTranslationService {
  bool get isSupportedPlatform => false;

  bool supportsLanguageCode(String code) => false;

  Future<String> translate(
    String text, {
    required String sourceLangCode,
    required String targetLangCode,
  }) {
    throw UnsupportedError(
      'Local translation is not available on this platform',
    );
  }

  Future<void> dispose() async {}
}
