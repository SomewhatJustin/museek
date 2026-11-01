import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:museek_app/providers.dart';
import 'package:museek_app/screens/pair_page.dart';

void main() {
  testWidgets('pairing form explains missing values', (tester) async {
    final controller = SessionController(
      _MemoryStorage(),
      MockClient((_) async => http.Response('', 500)),
      initialState: const SessionState(),
      restore: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionControllerProvider.overrideWith((_) => controller)],
        child: const MaterialApp(home: PairPage()),
      ),
    );

    expect(find.text('Your music is waiting'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.text('Enter the server address.'), findsOneWidget);
    expect(find.text('Enter your invitation code.'), findsOneWidget);
  });
}

class _MemoryStorage implements SessionStorage {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
