import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'api_client.dart';
import 'models.dart';
import 'offline_library.dart';

class MuseekPlayerController extends ChangeNotifier {
  MuseekPlayerController(this.player) {
    _subscriptions.add(
      player.currentIndexStream.listen((index) {
        _currentIndex = index;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.playerStateStream.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      player.errorStream.listen((error) {
        _error = error.message;
        notifyListeners();
      }),
    );
  }

  final AudioPlayer player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  MusicCollection? _collection;
  int? _currentIndex;
  bool _loading = false;
  String? _error;
  bool _usingDownloadedCollection = false;

  MusicCollection? get collection => _collection;
  int? get currentIndex => _currentIndex;
  bool get loading => _loading;
  String? get error => _error;
  bool get hasTrack => currentTrack != null;
  bool get playing => player.playing;

  MusicTrack? get currentTrack {
    final index = _currentIndex;
    final tracks = _collection?.tracks;
    if (index == null ||
        tracks == null ||
        index < 0 ||
        index >= tracks.length) {
      return null;
    }
    return tracks[index];
  }

  Future<void> playCollection({
    required MusicCollection collection,
    required int initialIndex,
    required MuseekApiClient api,
    required OfflineLibrary downloads,
  }) async {
    final fullyDownloaded = await downloads.isCollectionDownloaded(
      collection.id,
    );
    if (_collection?.id == collection.id &&
        player.audioSource != null &&
        (!fullyDownloaded || _usingDownloadedCollection)) {
      await player.seek(Duration.zero, index: initialIndex);
      unawaited(player.play());
      return;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final locations = <Uri>[];
      for (final track in collection.tracks) {
        final local = await downloads.localTrackUri(track);
        locations.add(local ?? (await api.playUrl(track.id)).url);
      }
      final artUris = <String?, Uri?>{};
      for (final track in collection.tracks) {
        final artworkId = track.artworkId ?? collection.artworkId;
        if (!artUris.containsKey(artworkId)) {
          var artwork = await downloads.localArtworkUri(artworkId);
          if (artwork == null) {
            try {
              artwork = await api.cachedArtworkUri(artworkId);
            } on ApiException {
              // Missing artwork should never prevent downloaded audio playback.
            }
          }
          artUris[artworkId] = artwork;
        }
      }
      final sources = <AudioSource>[];
      for (var index = 0; index < collection.tracks.length; index++) {
        final track = collection.tracks[index];
        final artworkId = track.artworkId ?? collection.artworkId;
        sources.add(
          AudioSource.uri(
            locations[index],
            tag: MediaItem(
              id: track.id,
              album: track.album.isEmpty ? collection.name : track.album,
              title: track.title,
              artist: track.artist.isEmpty ? null : track.artist,
              duration: track.duration == Duration.zero ? null : track.duration,
              artUri: artUris[artworkId],
            ),
          ),
        );
      }
      _collection = collection;
      _currentIndex = initialIndex;
      _usingDownloadedCollection = locations.every(
        (location) => location.scheme == 'file',
      );
      await player.setAudioSources(sources, initialIndex: initialIndex);
      unawaited(player.play());
    } on ApiException catch (error) {
      _error = error.message;
    } on PlayerException catch (error) {
      _error = error.message;
    } catch (_) {
      _error = 'This track could not be played.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    if (player.playing) {
      await player.pause();
    } else {
      unawaited(player.play());
    }
  }

  Future<void> next() async {
    if (player.hasNext) {
      await player.seekToNext();
    }
  }

  Future<void> previous() async {
    if (player.position > const Duration(seconds: 4)) {
      await player.seek(Duration.zero);
    } else if (player.hasPrevious) {
      await player.seekToPrevious();
    } else {
      await player.seek(Duration.zero);
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }
}
