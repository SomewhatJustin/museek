import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:museek_app/api_client.dart';

void main() {
  test('pairs and preserves recipient identity', () async {
    late http.Request captured;
    final client = MuseekApiClient(
      serverUrl: 'music.example.com/',
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'token': 'session-token',
            'recipient': {'id': 'recipient-1', 'name': 'Listener'},
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final session = await client.pair(code: 'ABCD-2345', deviceName: 'iPhone');

    expect(captured.url.toString(), 'https://music.example.com/v1/pair');
    expect(captured.method, 'POST');
    expect(jsonDecode(captured.body), {
      'code': 'ABCD-2345',
      'deviceName': 'iPhone',
    });
    expect(session.token, 'session-token');
    expect(session.recipientName, 'Listener');
    expect(session.serverUrl, 'https://music.example.com');
  });

  test('sends requests through a reverse-proxy base path', () async {
    late http.Request captured;
    final client = MuseekApiClient(
      serverUrl: 'https://music.example.com/museek/',
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          '{"token":"session-token","recipient":{"id":"recipient-1","name":"Listener"}}',
          201,
        );
      }),
    );

    await client.pair(code: 'ABCD-2345', deviceName: 'iPhone');

    expect(captured.url.toString(), 'https://music.example.com/museek/v1/pair');
  });

  test('parses a shared collection list with bearer authorization', () async {
    final client = MuseekApiClient(
      serverUrl: 'https://music.example.com',
      token: 'secret',
      httpClient: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer secret');
        return http.Response(
          jsonEncode({
            'collections': [
              {
                'id': 'collection-1',
                'name': 'Bedtime Favorites',
                'trackCount': 3,
                'artworkId': 'art-1',
              },
            ],
          }),
          200,
        );
      }),
    );

    final collections = await client.collections();

    expect(collections, hasLength(1));
    expect(collections.single.name, 'Bedtime Favorites');
    expect(collections.single.trackCount, 3);
  });

  test('turns a revoked session into a useful message', () async {
    final client = MuseekApiClient(
      serverUrl: 'https://music.example.com',
      token: 'revoked',
      httpClient: MockClient((_) async => http.Response('{"error":"no"}', 401)),
    );

    expect(
      client.collections,
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'status', 401)
            .having(
              (error) => error.message,
              'message',
              'This device no longer has access.',
            ),
      ),
    );
  });

  test('rejects plaintext non-local servers', () {
    expect(
      () => MuseekApiClient(
        serverUrl: 'http://music.example.com',
        httpClient: MockClient((_) async => http.Response('', 200)),
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
