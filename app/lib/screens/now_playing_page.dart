import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player_controller.dart';
import '../providers.dart';
import '../widgets/artwork_view.dart';

class NowPlayingPage extends ConsumerWidget {
  const NowPlayingPage({this.scrollController, super.key});

  final ScrollController? scrollController;

  AppBar _appBar(BuildContext context) {
    return AppBar(
      leading: IconButton(
        tooltip: 'Collapse player',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.keyboard_arrow_down_rounded),
      ),
      title: const Text('Now Playing'),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playerControllerProvider);
    final track = controller.currentTrack;
    if (track == null) {
      return Scaffold(
        appBar: _appBar(context),
        body: const Center(child: Text('Nothing is playing.')),
      );
    }
    final artworkId = track.artworkId ?? controller.collection?.artworkId;
    return Scaffold(
      appBar: _appBar(context),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final artworkSize = (constraints.maxWidth - 48).clamp(180.0, 380.0);
            return SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              child: Column(
                children: [
                  SizedBox(
                    width: artworkSize,
                    height: artworkSize,
                    child: ArtworkView(artworkId: artworkId, borderRadius: 28),
                  ),
                  const SizedBox(height: 30),
                  Text(
                    track.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    track.artist.isEmpty
                        ? controller.collection?.name ?? ''
                        : track.artist,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 24),
                  _ProgressControl(controller: controller),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Previous',
                        iconSize: 42,
                        onPressed: controller.previous,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      const SizedBox(width: 18),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          padding: const EdgeInsets.all(20),
                        ),
                        onPressed: controller.loading
                            ? null
                            : controller.toggle,
                        child: controller.loading
                            ? const SizedBox.square(
                                dimension: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                controller.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 38,
                              ),
                      ),
                      const SizedBox(width: 18),
                      IconButton(
                        tooltip: 'Next',
                        iconSize: 42,
                        onPressed: controller.player.hasNext
                            ? controller.next
                            : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  ),
                  if (controller.error != null) ...[
                    const SizedBox(height: 20),
                    MaterialBanner(
                      content: Text(controller.error!),
                      actions: [
                        TextButton(
                          onPressed: controller.clearError,
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProgressControl extends StatelessWidget {
  const _ProgressControl({required this.controller});

  final MuseekPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: controller.player.positionStream,
      initialData: controller.player.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final duration =
            controller.player.duration ??
            controller.currentTrack?.duration ??
            Duration.zero;
        final maximum = duration.inMilliseconds > 0
            ? duration.inMilliseconds.toDouble()
            : 1.0;
        final value = position.inMilliseconds
            .clamp(0, maximum.toInt())
            .toDouble();
        return Column(
          children: [
            Slider(
              value: value,
              max: maximum,
              onChanged: duration == Duration.zero
                  ? null
                  : (next) => controller.player.seek(
                      Duration(milliseconds: next.round()),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text(_clock(position)), Text(_clock(duration))],
              ),
            ),
          ],
        );
      },
    );
  }
}

String _clock(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
