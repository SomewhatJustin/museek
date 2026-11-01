import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pairing_link.dart';
import 'providers.dart';
import 'screens/library_page.dart';
import 'screens/pair_page.dart';

class MuseekApp extends ConsumerStatefulWidget {
  const MuseekApp({super.key});

  @override
  ConsumerState<MuseekApp> createState() => _MuseekAppState();
}

class _MuseekAppState extends ConsumerState<MuseekApp> {
  StreamSubscription<Uri>? _linkSubscription;
  ProviderSubscription<SessionState>? _sessionSubscription;
  PairingLink? _pendingLink;
  bool _handlingLink = false;

  @override
  void initState() {
    super.initState();
    _sessionSubscription = ref.listenManual<SessionState>(
      sessionControllerProvider,
      (_, _) => unawaited(_consumePendingLink()),
      fireImmediately: true,
    );
    _linkSubscription = AppLinks().uriLinkStream.listen(_receiveLink);
  }

  void _receiveLink(Uri uri) {
    final invitation = PairingLink.tryParse(uri);
    if (invitation == null) {
      return;
    }
    _pendingLink = invitation;
    unawaited(_consumePendingLink());
  }

  Future<void> _consumePendingLink() async {
    if (_handlingLink || _pendingLink == null) {
      return;
    }
    final sessionState = ref.read(sessionControllerProvider);
    if (sessionState.initializing) {
      return;
    }
    final invitation = _pendingLink!;
    _pendingLink = null;
    final currentSession = sessionState.session;
    if (currentSession != null &&
        !isSameMuseekHost(currentSession.serverUrl, invitation.serverUrl)) {
      return;
    }
    _handlingLink = true;
    try {
      await ref
          .read(sessionControllerProvider.notifier)
          .pair(
            serverUrl: invitation.serverUrl,
            code: invitation.code,
            deviceName: 'iPhone',
          );
    } finally {
      _handlingLink = false;
      if (mounted) {
        unawaited(_consumePendingLink());
      }
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _sessionSubscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6746D7),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'Museek',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF9F7FC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerLowest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
      home: const _SessionGate(),
    );
  }
}

class _SessionGate extends ConsumerWidget {
  const _SessionGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionControllerProvider);
    if (state.initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (state.session == null) {
      return const PairPage();
    }
    return const LibraryPage();
  }
}
