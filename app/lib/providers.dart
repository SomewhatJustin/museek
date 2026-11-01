import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'api_client.dart';
import 'models.dart';
import 'offline_library.dart';
import 'player_controller.dart';

abstract class SessionStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSessionStorage implements SessionStorage {
  const SecureSessionStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final secureStorageProvider = Provider<SessionStorage>((ref) {
  return const SecureSessionStorage(
    FlutterSecureStorage(
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    ),
  );
});

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

class SessionState {
  const SessionState({
    this.session,
    this.initializing = false,
    this.pairing = false,
    this.error,
  });

  final AppSession? session;
  final bool initializing;
  final bool pairing;
  final String? error;

  SessionState copyWith({
    AppSession? session,
    bool clearSession = false,
    bool? initializing,
    bool? pairing,
    String? error,
    bool clearError = false,
  }) {
    return SessionState(
      session: clearSession ? null : session ?? this.session,
      initializing: initializing ?? this.initializing,
      pairing: pairing ?? this.pairing,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class SessionController extends StateNotifier<SessionState> {
  SessionController(
    this._storage,
    this._httpClient, {
    SessionState? initialState,
    bool restore = true,
  }) : super(initialState ?? const SessionState(initializing: true)) {
    if (restore) {
      _restore();
    }
  }

  static const _serverKey = 'server_url';
  static const _tokenKey = 'session_token';
  static const _recipientIdKey = 'recipient_id';
  static const _recipientNameKey = 'recipient_name';

  final SessionStorage _storage;
  final http.Client _httpClient;

  Future<void> _restore() async {
    try {
      final values = await Future.wait([
        _storage.read(_serverKey),
        _storage.read(_tokenKey),
        _storage.read(_recipientIdKey),
        _storage.read(_recipientNameKey),
      ]);
      if (values.every((value) => value != null && value.isNotEmpty)) {
        state = SessionState(
          session: AppSession(
            serverUrl: values[0]!,
            token: values[1]!,
            recipientId: values[2]!,
            recipientName: values[3]!,
          ),
        );
      } else {
        state = const SessionState();
      }
    } catch (_) {
      state = const SessionState(
        error: 'Museek could not read its saved session.',
      );
    }
  }

  Future<bool> pair({
    required String serverUrl,
    required String code,
    required String deviceName,
  }) async {
    final previousSession = state.session;
    state = state.copyWith(pairing: true, clearError: true);
    try {
      final client = MuseekApiClient(
        serverUrl: serverUrl,
        httpClient: _httpClient,
      );
      final session = await client.pair(code: code, deviceName: deviceName);
      await Future.wait([
        _storage.write(_serverKey, session.serverUrl),
        _storage.write(_tokenKey, session.token),
        _storage.write(_recipientIdKey, session.recipientId),
        _storage.write(_recipientNameKey, session.recipientName),
      ]);
      state = SessionState(session: session);
      return true;
    } on ApiException catch (error) {
      state = SessionState(session: previousSession, error: error.message);
    } catch (_) {
      state = SessionState(
        session: previousSession,
        error: 'Pairing failed. Please try again.',
      );
    }
    return false;
  }

  Future<void> signOut() async {
    await Future.wait([
      _storage.delete(_serverKey),
      _storage.delete(_tokenKey),
      _storage.delete(_recipientIdKey),
      _storage.delete(_recipientNameKey),
    ]);
    state = const SessionState();
  }
}

final sessionControllerProvider =
    StateNotifierProvider<SessionController, SessionState>((ref) {
      return SessionController(
        ref.watch(secureStorageProvider),
        ref.watch(httpClientProvider),
      );
    });

final apiClientProvider = Provider<MuseekApiClient?>((ref) {
  final session = ref.watch(sessionControllerProvider).session;
  if (session == null) {
    return null;
  }
  return MuseekApiClient(
    serverUrl: session.serverUrl,
    token: session.token,
    httpClient: ref.watch(httpClientProvider),
  );
});

final offlineLibraryProvider = ChangeNotifierProvider<OfflineLibrary>((ref) {
  final session = ref.watch(
    sessionControllerProvider.select((state) => state.session),
  );
  return OfflineLibrary(
    profileKey: session == null
        ? null
        : '${session.serverUrl}|${session.recipientId}',
  );
});

final collectionsProvider = StreamProvider.autoDispose<List<CollectionSummary>>(
  (ref) async* {
    final downloads = ref.read(offlineLibraryProvider);
    await downloads.ready;
    final local = downloads.downloadedCollections;
    if (local.isNotEmpty) {
      yield local;
    }
    final api = ref.watch(apiClientProvider);
    if (api == null) {
      if (local.isEmpty) {
        yield const [];
      }
      return;
    }
    try {
      final remote = await api.collections();
      final merged = <String, CollectionSummary>{
        for (final collection in local) collection.id: collection,
        for (final collection in remote) collection.id: collection,
      };
      yield merged.values.toList(growable: false);
    } on ApiException catch (error) {
      if (local.isEmpty || error.statusCode == 401) {
        rethrow;
      }
    }
  },
);

final collectionProvider = StreamProvider.autoDispose
    .family<MusicCollection, String>((ref, collectionId) async* {
      final downloads = ref.read(offlineLibraryProvider);
      await downloads.ready;
      final local = downloads.collection(collectionId);
      if (local != null) {
        yield local;
      }
      final api = ref.watch(apiClientProvider);
      if (api == null) {
        if (local != null) {
          return;
        }
        throw const ApiException('This device is not paired.');
      }
      try {
        yield await api.collection(collectionId);
      } on ApiException catch (error) {
        if (local == null || error.statusCode == 401) {
          rethrow;
        }
      }
    });

final audioPlayerProvider = Provider<AudioPlayer>((ref) {
  final player = AudioPlayer();
  ref.onDispose(player.dispose);
  return player;
});

final playerControllerProvider = ChangeNotifierProvider<MuseekPlayerController>(
  (ref) {
    final controller = MuseekPlayerController(ref.watch(audioPlayerProvider));
    ref.onDispose(controller.dispose);
    return controller;
  },
);
