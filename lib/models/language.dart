class Language {
  final String code; // 'ko', 'ja', 'en', etc.
  final String name; // '한국어', '日本語', etc.
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
  bool operator ==(Object other) => other is Language && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

const supportedLanguages = [
  Language(
    code: 'ko',
    name: '한국어',
    localName: '한국어',
    sttLocale: 'ko_KR',
    ttsLocale: 'ko-KR',
  ),
  Language(
    code: 'ja',
    name: '日本語',
    localName: '일본어',
    sttLocale: 'ja_JP',
    ttsLocale: 'ja-JP',
  ),
  Language(
    code: 'zh',
    name: '中文',
    localName: '중국어',
    sttLocale: 'zh_CN',
    ttsLocale: 'zh-CN',
  ),
  Language(
    code: 'en',
    name: 'English',
    localName: '영어',
    sttLocale: 'en_US',
    ttsLocale: 'en-US',
  ),
  Language(
    code: 'de',
    name: 'Deutsch',
    localName: '독일어',
    sttLocale: 'de_DE',
    ttsLocale: 'de-DE',
  ),
  Language(
    code: 'fr',
    name: 'Français',
    localName: '프랑스어',
    sttLocale: 'fr_FR',
    ttsLocale: 'fr-FR',
  ),
  Language(
    code: 'vi',
    name: 'Tiếng Việt',
    localName: '베트남어',
    sttLocale: 'vi_VN',
    ttsLocale: 'vi-VN',
  ),
  Language(
    code: 'ru',
    name: 'Русский',
    localName: '러시아어',
    sttLocale: 'ru_RU',
    ttsLocale: 'ru-RU',
  ),
];

final _languageByCode = {
  for (final language in supportedLanguages) language.code: language,
};

const _languageNamesByReader = <String, Map<String, String>>{
  'ko': {
    'ko': '한국어',
    'ja': '일본어',
    'zh': '중국어',
    'en': '영어',
    'de': '독일어',
    'fr': '프랑스어',
    'vi': '베트남어',
    'ru': '러시아어',
  },
  'ja': {
    'ko': '韓国語',
    'ja': '日本語',
    'zh': '中国語',
    'en': '英語',
    'de': 'ドイツ語',
    'fr': 'フランス語',
    'vi': 'ベトナム語',
    'ru': 'ロシア語',
  },
  'zh': {
    'ko': '韩语',
    'ja': '日语',
    'zh': '中文',
    'en': '英语',
    'de': '德语',
    'fr': '法语',
    'vi': '越南语',
    'ru': '俄语',
  },
  'en': {
    'ko': 'Korean',
    'ja': 'Japanese',
    'zh': 'Chinese',
    'en': 'English',
    'de': 'German',
    'fr': 'French',
    'vi': 'Vietnamese',
    'ru': 'Russian',
  },
  'de': {
    'ko': 'Koreanisch',
    'ja': 'Japanisch',
    'zh': 'Chinesisch',
    'en': 'Englisch',
    'de': 'Deutsch',
    'fr': 'Französisch',
    'vi': 'Vietnamesisch',
    'ru': 'Russisch',
  },
  'fr': {
    'ko': 'coréen',
    'ja': 'japonais',
    'zh': 'chinois',
    'en': 'anglais',
    'de': 'allemand',
    'fr': 'français',
    'vi': 'vietnamien',
    'ru': 'russe',
  },
  'vi': {
    'ko': 'tiếng Hàn',
    'ja': 'tiếng Nhật',
    'zh': 'tiếng Trung',
    'en': 'tiếng Anh',
    'de': 'tiếng Đức',
    'fr': 'tiếng Pháp',
    'vi': 'tiếng Việt',
    'ru': 'tiếng Nga',
  },
  'ru': {
    'ko': 'корейский',
    'ja': 'японский',
    'zh': 'китайский',
    'en': 'английский',
    'de': 'немецкий',
    'fr': 'французский',
    'vi': 'вьетнамский',
    'ru': 'русский',
  },
};

const _personLabelsByReader = <String, ({String self, String other})>{
  'ko': (self: '나', other: '상대'),
  'ja': (self: '自分', other: '相手'),
  'zh': (self: '我', other: '对方'),
  'en': (self: 'Me', other: 'Other'),
  'de': (self: 'Ich', other: 'Gegenüber'),
  'fr': (self: 'Moi', other: 'Interlocuteur'),
  'vi': (self: 'Tôi', other: 'Đối phương'),
  'ru': (self: 'Я', other: 'Собеседник'),
};

const _retryLabelsByReader = <String, String>{
  'ko': '다시',
  'ja': 'もう一度',
  'zh': '重试',
  'en': 'Retry',
  'de': 'Erneut',
  'fr': 'Refaire',
  'vi': 'Làm lại',
  'ru': 'Ещё раз',
};

Language getLangByCode(String code) =>
    _languageByCode[code] ?? supportedLanguages[0];

String languageNameForReader(String languageCode, String readerLangCode) {
  final localized = _languageNamesByReader[readerLangCode]?[languageCode];
  if (localized != null) return localized;

  final language = getLangByCode(languageCode);
  if (readerLangCode == 'ko') return language.localName;
  return language.name;
}

String personLabelForReader({
  required bool isSelf,
  required String readerLangCode,
}) {
  final labels = _personLabelsByReader[readerLangCode];
  if (labels == null) return isSelf ? 'Me' : 'Other';
  return isSelf ? labels.self : labels.other;
}

String retryLabelForReader(String readerLangCode) =>
    _retryLabelsByReader[readerLangCode] ?? 'Retry';
