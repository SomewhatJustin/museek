import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:museek_app/api_client.dart';
import 'package:museek_app/models.dart';
import 'package:museek_app/offline_library.dart';

void main() {
  test('downloads original bytes and restores them after relaunch', () async {
    final root = await Directory.systemTemp.createTemp('museek-offline-test-');
    addTearDown(() => root.delete(recursive: true));
    final original = List<int>.generate(8192, (index) => index % 251);
    final artwork = List<int>.generate(128, (index) => 255 - index);
    final api = MuseekApiClient(
      serverUrl: 'https://music.example.com',
      token: 'session-token',
      httpClient: MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path.endsWith('/play-url')) {
          return http.Response(
            jsonEncode({
              'url':
                  'https://music.example.com/v1/streams/track-1?token=signed',
              'expiresAt': '2030-01-01T00:00:00Z',
            }),
            200,
          );
        }
        if (request.url.path == '/v1/streams/track-1') {
          return http.Response.bytes(original, 200);
        }
        if (request.url.path == '/v1/artwork/art-1') {
          return http.Response.bytes(artwork, 200);
        }
        return http.Response('not found', 404);
      }),
    );
    const collection = MusicCollection(
      id: 'collection-1',
      name: 'Offline Mixtape',
      artworkId: 'art-1',
      trackCount: 1,
      tracks: [
        MusicTrack(
          id: 'track-1',
          collectionId: 'collection-1',
          title: 'Original Track',
          artist: 'Artist',
          album: 'Offline Mixtape',
          discNumber: 1,
          trackNumber: 1,
          duration: Duration(minutes: 4),
        ),
      ],
    );
    final downloads = OfflineLibrary(
      profileKey: 'server|listener',
      supportDirectory: () async => root,
    );
    addTearDown(downloads.dispose);

    await downloads.downloadCollection(collection, api);

    expect(downloads.statusFor(collection.id).phase, DownloadPhase.downloaded);
    final localTrack = await downloads.localTrackUri(collection.tracks.single);
    expect(localTrack, isNotNull);
    expect(await File.fromUri(localTrack!).readAsBytes(), original);
    expect(await downloads.localArtwork('art-1'), artwork);

    final restored = OfflineLibrary(
      profileKey: 'server|listener',
      supportDirectory: () async => root,
    );
    addTearDown(restored.dispose);
    await restored.ready;

    expect(restored.collection(collection.id)?.name, 'Offline Mixtape');
    final restoredTrack = await restored.localTrackUri(
      restored.collection(collection.id)!.tracks.single,
    );
    expect(await File.fromUri(restoredTrack!).readAsBytes(), original);
  });

  test('removing a download clears its playable local files', () async {
    final root = await Directory.systemTemp.createTemp('museek-offline-test-');
    addTearDown(() => root.delete(recursive: true));
    final api = MuseekApiClient(
      serverUrl: 'https://music.example.com',
      token: 'session-token',
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'url':
                  'https://music.example.com/v1/streams/track-1?token=signed',
              'expiresAt': '2030-01-01T00:00:00Z',
            }),
            200,
          );
        }
        return http.Response.bytes([1, 2, 3, 4], 200);
      }),
    );
    const track = MusicTrack(
      id: 'track-1',
      collectionId: 'collection-1',
      title: 'Track',
      artist: '',
      album: '',
      discNumber: 1,
      trackNumber: 1,
      duration: Duration(minutes: 1),
    );
    const collection = MusicCollection(
      id: 'collection-1',
      name: 'Mixtape',
      trackCount: 1,
      tracks: [track],
    );
    final downloads = OfflineLibrary(
      profileKey: 'server|listener',
      supportDirectory: () async => root,
    );
    addTearDown(downloads.dispose);
    await downloads.downloadCollection(collection, api);

    await downloads.removeCollection(collection.id);

    expect(downloads.statusFor(collection.id).phase, DownloadPhase.idle);
    expect(await downloads.localTrackUri(track), isNull);
  });
}
