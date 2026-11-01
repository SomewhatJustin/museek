import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:museek_app/models.dart';
import 'package:museek_app/providers.dart';

void main() {
  test('restores a complete saved session after app relaunch', () async {
    final storage = MemoryStorage({
      'server_url': 'https://music.example.com',
      'session_token': 'saved-token',
      'recipient_id': 'recipient-1',
      'recipient_name': 'Listener',
    });
    final controller = SessionController(
      storage,
      MockClient((_) async => http.Response('', 500)),
    );
    addTearDown(controller.dispose);

    await Future<void>.delayed(Duration.zero);

    expect(controller.state.initializing, isFalse);
    expect(controller.state.session?.token, 'saved-token');
    expect(controller.state.session?.recipientName, 'Listener');
  });

  test('pair persists the session and sign out forgets it', () async {
    final storage = MemoryStorage();
    final controller = SessionController(
      storage,
      MockClient((request) async {
        expect(request.url.toString(), 'https://music.example.com/v1/pair');
        return http.Response(
          jsonEncode({
            'token': 'new-token',
            'recipient': {'id': 'recipient-1', 'name': 'Listener'},
          }),
          201,
        );
      }),
      initialState: const SessionState(),
      restore: false,
    );
    addTearDown(controller.dispose);

    final paired = await controller.pair(
      serverUrl: 'music.example.com',
      code: 'ABCD-2345',
      deviceName: 'iPhone',
    );

    expect(paired, isTrue);
    expect(storage.values['session_token'], 'new-token');
    expect(controller.state.session?.recipientName, 'Listener');

    await controller.signOut();
    expect(storage.values, isEmpty);
    expect(controller.state.session, isNull);
  });

  test('a failed replacement link keeps the current session', () async {
    final existing = AppSession(
      serverUrl: 'https://music.example.com:8443',
      token: 'saved-token',
      recipientId: 'recipient-1',
      recipientName: 'Listener',
    );
    final controller = SessionController(
      MemoryStorage(),
      MockClient((_) async => http.Response('{"error":"expired"}', 401)),
      initialState: SessionState(session: existing),
      restore: false,
    );
    addTearDown(controller.dispose);

    final paired = await controller.pair(
      serverUrl: 'https://music.example.com/museek',
      code: 'EXPIRED1',
      deviceName: 'iPhone',
    );

    expect(paired, isFalse);
    expect(controller.state.session?.token, 'saved-token');
    expect(controller.state.error, 'That pairing code is invalid or expired.');
  });
}

class MemoryStorage implements SessionStorage {
  MemoryStorage([Map<String, String>? initial])
    : values = Map<String, String>.from(initial ?? const {});

  final Map<String, String> values;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
