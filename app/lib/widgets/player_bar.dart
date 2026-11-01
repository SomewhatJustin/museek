import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../screens/now_playing_page.dart';
import 'artwork_view.dart';

class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playerControllerProvider);
    final track = controller.currentTrack;
    if (track == null) {
      return const SizedBox.shrink();
    }
    void openNowPlaying() {
      final mediaQuery = MediaQueryData.fromView(View.of(context));
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        enableDrag: false,
        useSafeArea: false,
        showDragHandle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        constraints: BoxConstraints.tight(mediaQuery.size),
        builder: (_) =>
            MediaQuery(data: mediaQuery, child: const _SwipeDismissPlayer()),
      );
    }

    final artistLabel = track.artist.isEmpty ? '' : ' by ${track.artist}';
    return Material(
      elevation: 12,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          button: true,
          label: 'Now playing ${track.title}$artistLabel',
          onTap: openNowPlaying,
          child: InkWell(
            onTap: openNowPlaying,
            child: SizedBox(
              height: 72,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  ArtworkView(
                    artworkId:
                        track.artworkId ?? controller.collection?.artworkId,
                    size: 52,
                    borderRadius: 10,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        if (track.artist.isNotEmpty)
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  if (controller.loading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: controller.playing ? 'Pause' : 'Play',
                      onPressed: controller.toggle,
                      icon: Icon(
                        controller.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: controller.player.hasNext
                        ? controller.next
                        : null,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeDismissPlayer extends StatefulWidget {
  const _SwipeDismissPlayer();

  @override
  State<_SwipeDismissPlayer> createState() => _SwipeDismissPlayerState();
}

class _SwipeDismissPlayerState extends State<_SwipeDismissPlayer> {
  final ScrollController _scrollController = ScrollController();
  Offset? _startPosition;
  DateTime? _startTime;
  double _dragOffset = 0;
  bool _dragging = false;
  bool _canDismiss = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _pointerDown(PointerDownEvent event) {
    _startPosition = event.position;
    _startTime = DateTime.now();
    _canDismiss =
        !_scrollController.hasClients || _scrollController.position.pixels <= 0;
  }

  void _pointerMove(PointerMoveEvent event) {
    final start = _startPosition;
    if (!_canDismiss || start == null) {
      return;
    }
    final delta = event.position - start;
    if (delta.dy <= 0 || delta.dy <= delta.dx.abs()) {
      return;
    }
    setState(() {
      _dragging = true;
      _dragOffset = delta.dy;
    });
  }

  void _pointerUp(PointerUpEvent event) {
    final startedAt = _startTime;
    final elapsed = startedAt == null
        ? const Duration(seconds: 1)
        : DateTime.now().difference(startedAt);
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final velocity = seconds <= 0 ? 0 : _dragOffset / seconds;
    final shouldDismiss =
        _dragOffset >= 100 || (_dragOffset >= 40 && velocity >= 700);
    _startPosition = null;
    _startTime = null;
    if (shouldDismiss) {
      Navigator.of(context).pop();
      return;
    }
    _resetDrag();
  }

  void _resetDrag() {
    if (!_dragging && _dragOffset == 0) {
      return;
    }
    setState(() {
      _dragging = false;
      _dragOffset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: (_) => _resetDrag(),
      child: AnimatedContainer(
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _dragOffset, 0),
        child: NowPlayingPage(scrollController: _scrollController),
      ),
    );
  }
}
