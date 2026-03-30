class Language {
  final String code;      // 'ko', 'ja', 'en', etc.
  final String name;      // '한국어', '日本語', etc.
  final String localName; // Native name for display
  final String sttLocale; // 'ko_KR', 'ja_JP', etc.
  final String ttsLocale; // 'ko-KR', 'ja-JP', etc.

  const Language({
    required this.code,
    required this.name,
    required this.localName,
    required this.sttLocale,
    required this.ttsLocale,
  });

  @override
  bool operator ==(Object other) =>
      other is Language && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

const supportedLanguages = [
  Language(code: 'ko', name: '한국어', localName: '한국어', sttLocale: 'ko_KR', ttsLocale: 'ko-KR'),
  Language(code: 'ja', name: '日本語', localName: '일본어', sttLocale: 'ja_JP', ttsLocale: 'ja-JP'),
  Language(code: 'zh', name: '中文', localName: '중국어', sttLocale: 'zh_CN', ttsLocale: 'zh-CN'),
  Language(code: 'en', name: 'English', localName: '영어', sttLocale: 'en_US', ttsLocale: 'en-US'),
  Language(code: 'de', name: 'Deutsch', localName: '독일어', sttLocale: 'de_DE', ttsLocale: 'de-DE'),
  Language(code: 'fr', name: 'Français', localName: '프랑스어', sttLocale: 'fr_FR', ttsLocale: 'fr-FR'),
  Language(code: 'vi', name: 'Tiếng Việt', localName: '베트남어', sttLocale: 'vi_VN', ttsLocale: 'vi-VN'),
  Language(code: 'ru', name: 'Русский', localName: '러시아어', sttLocale: 'ru_RU', ttsLocale: 'ru-RU'),
];

Language getLangByCode(String code) =>
    supportedLanguages.firstWhere((l) => l.code == code, orElse: () => supportedLanguages[0]);
