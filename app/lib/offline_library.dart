import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'models.dart';

enum DownloadPhase { idle, downloading, downloaded, failed }

class DownloadStatus {
  const DownloadStatus({
    required this.phase,
    this.completedTracks = 0,
    this.totalTracks = 0,
    this.error,
  });

  const DownloadStatus.idle() : this(phase: DownloadPhase.idle);

  final DownloadPhase phase;
  final int completedTracks;
  final int totalTracks;
  final String? error;
}

typedef SupportDirectoryProvider = Future<Directory> Function();

class OfflineLibrary extends ChangeNotifier {
  OfflineLibrary({
    required this.profileKey,
    SupportDirectoryProvider? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory {
    _ready = _load();
  }

  final String? profileKey;
  final SupportDirectoryProvider _supportDirectory;
  final Map<String, MusicCollection> _collections = {};
  final Map<String, DownloadStatus> _statuses = {};
  late final Future<void> _ready;
  Directory? _profileDirectory;
  bool _initialized = false;

  Future<void> get ready => _ready;
  bool get initialized => _initialized;

  List<CollectionSummary> get downloadedCollections {
    final result = _collections.values.cast<CollectionSummary>().toList();
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  MusicCollection? collection(String id) => _collections[id];

  DownloadStatus statusFor(String collectionId) {
    final active = _statuses[collectionId];
    if (active != null) {
      return active;
    }
    if (_collections.containsKey(collectionId)) {
      return const DownloadStatus(phase: DownloadPhase.downloaded);
    }
    return const DownloadStatus.idle();
  }

  Future<bool> isCollectionDownloaded(String collectionId) async {
    await ready;
    return _collections.containsKey(collectionId);
  }

  Future<Uri?> localTrackUri(MusicTrack track) async {
    await ready;
    if (!_collections.containsKey(track.collectionId)) {
      return null;
    }
    final file = await _trackFile(track.collectionId, track.id);
    if (!await file.exists() || await file.length() == 0) {
      return null;
    }
    return file.uri;
  }

  Future<Uri?> localArtworkUri(String? artworkId) async {
    if (artworkId == null) {
      return null;
    }
    await ready;
    final file = await _artworkFile(artworkId);
    if (!await file.exists() || await file.length() == 0) {
      return null;
    }
    return file.uri;
  }

  Future<Uint8List?> localArtwork(String? artworkId) async {
    final uri = await localArtworkUri(artworkId);
    if (uri == null) {
      return null;
    }
    return File.fromUri(uri).readAsBytes();
  }

  Future<void> downloadCollection(
    MusicCollection collection,
    MuseekApiClient api,
  ) async {
    await ready;
    if (profileKey == null ||
        statusFor(collection.id).phase == DownloadPhase.downloading) {
      return;
    }
    _statuses[collection.id] = DownloadStatus(
      phase: DownloadPhase.downloading,
      totalTracks: collection.tracks.length,
    );
    notifyListeners();

    try {
      for (var index = 0; index < collection.tracks.length; index++) {
        final track = collection.tracks[index];
        final destination = await _trackFile(collection.id, track.id);
        await destination.parent.create(recursive: true);
        await api.downloadOriginal(track.id, destination);
        _statuses[collection.id] = DownloadStatus(
          phase: DownloadPhase.downloading,
          completedTracks: index + 1,
          totalTracks: collection.tracks.length,
        );
        notifyListeners();
      }

      await _downloadArtwork(collection, api);
      _collections[collection.id] = collection;
      await _persist();
      _statuses.remove(collection.id);
      notifyListeners();
    } on Object catch (error) {
      _statuses[collection.id] = DownloadStatus(
        phase: DownloadPhase.failed,
        totalTracks: collection.tracks.length,
        error: error is ApiException
            ? error.message
            : 'This mixtape could not be downloaded.',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> removeCollection(String collectionId) async {
    await ready;
    _collections.remove(collectionId);
    _statuses.remove(collectionId);
    await _persist();
    final directory = await _collectionDirectory(collectionId);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    notifyListeners();
  }

  Future<void> _load() async {
    if (profileKey == null) {
      _initialized = true;
      notifyListeners();
      return;
    }
    try {
      final manifest = await _manifestFile();
      if (await manifest.exists()) {
        final body = jsonDecode(await manifest.readAsString());
        final items = (body as Map<String, dynamic>)['collections'];
        if (items is List<dynamic>) {
          for (final item in items) {
            final collection = MusicCollection.fromJson(
              item as Map<String, dynamic>,
            );
            _collections[collection.id] = collection;
          }
        }
      }
    } on FileSystemException {
      _collections.clear();
    } on FormatException {
      _collections.clear();
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  Future<void> _downloadArtwork(
    MusicCollection collection,
    MuseekApiClient api,
  ) async {
    final artworkIds = <String>{
      if (collection.artworkId != null) collection.artworkId!,
      for (final track in collection.tracks)
        if (track.artworkId != null) track.artworkId!,
    };
    for (final artworkId in artworkIds) {
      try {
        final bytes = await api.artwork(artworkId);
        final file = await _artworkFile(artworkId);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      } on ApiException {
        // Artwork is optional; never make otherwise playable audio unavailable.
      }
    }
  }

  Future<void> _persist() async {
    if (profileKey == null) {
      return;
    }
    final manifest = await _manifestFile();
    await manifest.parent.create(recursive: true);
    final temporary = File('${manifest.path}.part');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'collections': _collections.values
            .map((collection) => collection.toJson())
            .toList(growable: false),
      }),
      flush: true,
    );
    if (await manifest.exists()) {
      await manifest.delete();
    }
    await temporary.rename(manifest.path);
  }

  Future<Directory> _directory() async {
    final existing = _profileDirectory;
    if (existing != null) {
      return existing;
    }
    final support = await _supportDirectory();
    final key = profileKey;
    final profile = key == null ? 'unpaired' : _hash(key);
    final result = Directory('${support.path}/museek-downloads/$profile');
    _profileDirectory = result;
    return result;
  }

  Future<File> _manifestFile() async {
    final directory = await _directory();
    return File('${directory.path}/manifest.json');
  }

  Future<Directory> _collectionDirectory(String collectionId) async {
    final directory = await _directory();
    return Directory('${directory.path}/audio/${_hash(collectionId)}');
  }

  Future<File> _trackFile(String collectionId, String trackId) async {
    final directory = await _collectionDirectory(collectionId);
    return File('${directory.path}/${_hash(trackId)}.mp3');
  }

  Future<File> _artworkFile(String artworkId) async {
    final directory = await _directory();
    return File('${directory.path}/artwork/${_hash(artworkId)}');
  }
}

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
