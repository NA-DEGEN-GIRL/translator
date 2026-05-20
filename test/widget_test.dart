// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:koja_translator/main.dart';

void main() {
  testWidgets('shows API key screen when no key is available', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KoJaApp());

    expect(find.text('KO ⇄ JA'), findsOneWidget);
    expect(find.text('OpenAI API Key'), findsOneWidget);
    expect(find.text('시작'), findsOneWidget);
  });

  testWidgets('opens translator when an API key is provided', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KoJaApp(apiKey: 'test-key'));

    expect(find.text('KO ⇄ JA'), findsNothing);
    expect(find.textContaining('입력창'), findsWidgets);
  });
}
