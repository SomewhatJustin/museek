import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:museek_app/models.dart';
import 'package:museek_app/player_controller.dart';
import 'package:museek_app/providers.dart';
import 'package:museek_app/screens/now_playing_page.dart';
import 'package:museek_app/widgets/player_bar.dart';

void main() {
  late _TestPlayerController controller;

  setUp(() {
    controller = _TestPlayerController();
  });

  tearDown(() async {
    await controller.player.dispose();
  });

  testWidgets('player background extends through the bottom safe area', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(controller));

    final playerMaterial = find.byWidgetPredicate(
      (widget) => widget is Material && widget.elevation == 12,
    );

    expect(playerMaterial, findsOneWidget);
    expect(tester.getSize(playerMaterial).height, 106);
  });

  testWidgets('now playing opens upward and dismisses with a downward swipe', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(controller));

    await tester.tap(find.text('Test Track'));
    await tester.pumpAndSettle();

    expect(find.byType(NowPlayingPage), findsOneWidget);
    final route = ModalRoute.of(tester.element(find.byType(NowPlayingPage)));
    expect(route, isA<ModalBottomSheetRoute<dynamic>>());

    await tester.fling(find.byType(NowPlayingPage), const Offset(0, 600), 1800);
    await tester.pumpAndSettle();

    expect(find.byType(NowPlayingPage), findsNothing);
  });
}

Widget _testApp(_TestPlayerController controller) {
  return ProviderScope(
    overrides: [playerControllerProvider.overrideWith((_) => controller)],
    child: MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 600),
          padding: EdgeInsets.only(bottom: 34),
        ),
        child: const Scaffold(bottomNavigationBar: PlayerBar()),
      ),
    ),
  );
}

class _TestPlayerController extends MuseekPlayerController {
  _TestPlayerController() : super(AudioPlayer());

  static const _track = MusicTrack(
    id: 'track-1',
    collectionId: 'collection-1',
    title: 'Test Track',
    artist: 'Test Artist',
    album: 'Test Album',
    discNumber: 1,
    trackNumber: 1,
    duration: Duration(minutes: 3),
  );

  static const _collection = MusicCollection(
    id: 'collection-1',
    name: 'Test Collection',
    trackCount: 1,
    tracks: [_track],
  );

  @override
  MusicCollection get collection => _collection;

  @override
  int get currentIndex => 0;

  @override
  MusicTrack get currentTrack => _track;
}
