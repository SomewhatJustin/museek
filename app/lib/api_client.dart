import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class MuseekApiClient {
  MuseekApiClient({
    required String serverUrl,
    required this.httpClient,
    this.token,
  }) : serverUrl = normalizeServerUrl(serverUrl),
       assert(token == null || token != '');

  final String serverUrl;
  final http.Client httpClient;
  final String? token;
  final Map<String, Future<Uint8List>> _artworkMemoryCache = {};
  static const _timeout = Duration(seconds: 15);

  static String normalizeServerUrl(String input) {
    var value = input.trim();
    if (!value.contains('://')) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const ApiException('Enter a valid server address.');
    }
    if (uri.scheme == 'http' &&
        uri.host != 'localhost' &&
        uri.host != '127.0.0.1' &&
        uri.host != '::1') {
      throw const ApiException(
        'Museek requires HTTPS outside local development.',
      );
    }
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  Uri _uri(String path) => Uri.parse('$serverUrl$path');

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<AppSession> pair({
    required String code,
    required String deviceName,
  }) async {
    final response = await _perform(
      () => httpClient.post(
        _uri('/v1/pair'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'code': code, 'deviceName': deviceName}),
      ),
    );
    _expect(response, httpStatus: 201);
    final body = _jsonObject(response);
    final recipient = body['recipient'] as Map<String, dynamic>;
    return AppSession(
      serverUrl: serverUrl,
      token: body['token'] as String,
      recipientId: recipient['id'] as String,
      recipientName: recipient['name'] as String,
    );
  }

  Future<List<CollectionSummary>> collections() async {
    final response = await _perform(
      () => httpClient.get(_uri('/v1/collections'), headers: _headers),
    );
    _expect(response);
    final items =
        _jsonObject(response)['collections'] as List<dynamic>? ?? const [];
    return items
        .map((item) => CollectionSummary.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<MusicCollection> collection(String id) async {
    final response = await _perform(
      () => httpClient.get(
        _uri('/v1/collections/${Uri.encodeComponent(id)}'),
        headers: _headers,
      ),
    );
    _expect(response);
    return MusicCollection.fromJson(_jsonObject(response));
  }

  Future<PlaybackLocation> playUrl(String trackId) async {
    final response = await _perform(
      () => httpClient.post(
        _uri('/v1/tracks/${Uri.encodeComponent(trackId)}/play-url'),
        headers: _headers,
      ),
    );
    _expect(response);
    return PlaybackLocation.fromJson(_jsonObject(response));
  }

  Future<void> downloadOriginal(String trackId, File destination) async {
    final location = await playUrl(trackId);
    late http.StreamedResponse response;
    try {
      response = await httpClient
          .send(http.Request('GET', location.url))
          .timeout(_timeout);
    } on TimeoutException {
      throw const ApiException('The server took too long to respond.');
    } on SocketException {
      throw const ApiException('Museek could not reach this server.');
    } on http.ClientException {
      throw const ApiException('Museek could not reach this server.');
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw ApiException(
        _messageFor(response.statusCode, body),
        statusCode: response.statusCode,
      );
    }

    final temporary = File('${destination.path}.part');
    if (await temporary.exists()) {
      await temporary.delete();
    }
    IOSink? sink;
    var received = 0;
    try {
      sink = temporary.openWrite();
      await for (final chunk in response.stream.timeout(_timeout)) {
        sink.add(chunk);
        received += chunk.length;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final expected = response.contentLength;
      if (expected != null && received != expected) {
        throw const ApiException('The downloaded audio file was incomplete.');
      }
      if (await destination.exists()) {
        await destination.delete();
      }
      await temporary.rename(destination.path);
    } on TimeoutException {
      throw const ApiException('The server took too long to respond.');
    } on SocketException {
      throw const ApiException('Museek could not reach this server.');
    } on http.ClientException {
      throw const ApiException('Museek could not reach this server.');
    } finally {
      if (sink != null) {
        await sink.close();
      }
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<Uint8List> artwork(String artworkId) {
    return _artworkMemoryCache.putIfAbsent(artworkId, () async {
      final response = await _perform(
        () => httpClient.get(
          _uri('/v1/artwork/${Uri.encodeComponent(artworkId)}'),
          headers: _headers,
        ),
      );
      _expect(response);
      return response.bodyBytes;
    });
  }

  Future<Uri?> cachedArtworkUri(String? artworkId) async {
    if (artworkId == null) {
      return null;
    }
    final bytes = await artwork(artworkId);
    final cache = await getTemporaryDirectory();
    final name = sha256
        .convert(utf8.encode('$serverUrl:$artworkId'))
        .toString();
    final file = File('${cache.path}/museek-art-$name');
    if (!await file.exists() || await file.length() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.uri;
  }

  Future<http.Response> _perform(
    Future<http.Response> Function() request,
  ) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw const ApiException('The server took too long to respond.');
    } on SocketException {
      throw const ApiException('Museek could not reach this server.');
    } on http.ClientException {
      throw const ApiException('Museek could not reach this server.');
    }
  }

  void _expect(http.Response response, {int httpStatus = 200}) {
    if (response.statusCode == httpStatus) {
      return;
    }
    throw ApiException(
      _messageFor(response.statusCode, response.body),
      statusCode: response.statusCode,
    );
  }

  String _messageFor(int statusCode, String body) {
    var message = 'The server returned an error.';
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      message = json['error'] as String? ?? message;
    } on FormatException {
      // Keep the safe generic message for non-JSON server/proxy responses.
    }
    if (statusCode == 401) {
      message = token == null
          ? 'That pairing code is invalid or expired.'
          : 'This device no longer has access.';
    }
    return message;
  }

  Map<String, dynamic> _jsonObject(http.Response response) {
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw const ApiException('The server returned an unreadable response.');
    }
  }
}
