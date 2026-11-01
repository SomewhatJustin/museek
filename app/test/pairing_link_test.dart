import 'package:flutter_test/flutter_test.dart';
import 'package:museek_app/pairing_link.dart';

void main() {
  test('parses a secure Museek pairing link', () {
    final invitation = PairingLink.tryParse(
      Uri.parse(
        'museek://pair?server=https%3A%2F%2Fmusic.example.com%3A10002&code=ABCD-2345',
      ),
    );

    expect(invitation?.serverUrl, 'https://music.example.com:10002');
    expect(invitation?.code, 'ABCD-2345');
  });

  test('allows loopback HTTP for development', () {
    final invitation = PairingLink.tryParse(
      Uri.parse(
        'museek://pair?server=http%3A%2F%2F127.0.0.1%3A8080&code=ABCD-2345',
      ),
    );

    expect(invitation?.serverUrl, 'http://127.0.0.1:8080');
  });

  test('preserves a reverse-proxy base path', () {
    final invitation = PairingLink.tryParse(
      Uri.parse(
        'museek://pair?server=https%3A%2F%2Fmusic.example.com%2Fmuseek&code=ABCD-2345',
      ),
    );

    expect(invitation?.serverUrl, 'https://music.example.com/museek');
  });

  test('recognizes the same host across a port-to-path migration', () {
    expect(
      isSameMuseekHost(
        'https://music.example.com:8443',
        'https://music.example.com/museek',
      ),
      isTrue,
    );
    expect(
      isSameMuseekHost(
        'https://old.example.com',
        'https://music.example.com/museek',
      ),
      isFalse,
    );
  });

  test('rejects incomplete, insecure, and unrelated links', () {
    expect(PairingLink.tryParse(Uri.parse('museek://pair')), isNull);
    expect(
      PairingLink.tryParse(
        Uri.parse(
          'museek://pair?server=http%3A%2F%2Fmusic.example.com&code=ABCD-2345',
        ),
      ),
      isNull,
    );
    expect(
      PairingLink.tryParse(
        Uri.parse(
          'other://pair?server=https%3A%2F%2Fmusic.example.com&code=ABCD-2345',
        ),
      ),
      isNull,
    );
  });
}
