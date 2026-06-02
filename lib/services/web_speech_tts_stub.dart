class WebSpeechTtsService {
  Future<void> prepareVoice(
    String lang, {
    required double rate,
    required String gender,
  }) async {}

  Future<void> speak(
    String text,
    String lang, {
    required double rate,
    required String gender,
    void Function()? onStart,
    void Function()? onReadyToSpeak,
    void Function()? onSpeakReturned,
    void Function()? onDone,
  }) async {}

  Future<void> stop() async {}
}
