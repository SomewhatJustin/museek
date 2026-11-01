import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_client.dart';
import '../models.dart';
import '../offline_library.dart';
import '../providers.dart';
import '../widgets/artwork_view.dart';
import '../widgets/player_bar.dart';

class CollectionPage extends ConsumerWidget {
  const CollectionPage({required this.summary, super.key});

  final CollectionSummary summary;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(collectionProvider(summary.id));
    await ref.read(collectionProvider(summary.id).future);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(collectionProvider(summary.id));
    return Scaffold(
      appBar: AppBar(
        title: Text(summary.name),
        actions: [
          collection.when(
            loading: SizedBox.shrink,
            error: (_, _) => const SizedBox.shrink(),
            data: (item) => _DownloadButton(collection: item),
          ),
          const SizedBox(width: 4),
        ],
      ),
      bottomNavigationBar: const PlayerBar(),
      body: collection.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 52),
                const SizedBox(height: 16),
                Text(
                  error is ApiException
                      ? error.message
                      : 'This collection could not be loaded.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () =>
                      ref.invalidate(collectionProvider(summary.id)),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
        data: (item) => RefreshIndicator(
          onRefresh: () => _refresh(ref),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _CollectionHeader(collection: item)),
              if (item.tracks.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('This collection is empty.')),
                )
              else
                SliverList.builder(
                  itemCount: item.tracks.length,
                  itemBuilder: (context, index) => _TrackTile(
                    collection: item,
                    track: item.tracks[index],
                    index: index,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({required this.collection});

  final MusicCollection collection;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
      child: Column(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: AspectRatio(
                aspectRatio: 1,
                child: ArtworkView(
                  artworkId: collection.artworkId,
                  borderRadius: 24,
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            collection.name,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            '${collection.tracks.length} ${collection.tracks.length == 1 ? 'track' : 'tracks'}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _DownloadButton extends ConsumerWidget {
  const _DownloadButton({required this.collection});

  final MusicCollection collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(offlineLibraryProvider);
    final status = downloads.statusFor(collection.id);

    return switch (status.phase) {
      DownloadPhase.downloading => IconButton(
        onPressed: null,
        tooltip:
            'Downloading ${status.completedTracks} of ${status.totalTracks}',
        icon: const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      DownloadPhase.downloaded => IconButton(
        onPressed: () => _confirmRemoval(context, ref, downloads),
        tooltip: 'Downloaded. Tap to remove.',
        icon: const Icon(Icons.download_done_rounded),
      ),
      DownloadPhase.failed => IconButton(
        onPressed: () => _download(context, ref, downloads),
        tooltip: 'Retry download',
        icon: const Icon(Icons.refresh_rounded),
      ),
      DownloadPhase.idle => IconButton(
        onPressed: collection.tracks.isEmpty
            ? null
            : () => _download(context, ref, downloads),
        tooltip: 'Download originals',
        icon: const Icon(Icons.download_rounded),
      ),
    };
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    OfflineLibrary downloads,
  ) async {
    final api = ref.read(apiClientProvider);
    if (api == null) {
      return;
    }
    try {
      await downloads.downloadCollection(collection, api);
      ref.invalidate(collectionsProvider);
      ref.invalidate(collectionProvider(collection.id));
    } on Object {
      if (!context.mounted) {
        return;
      }
      final message = downloads.statusFor(collection.id).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message ?? 'Download failed. Please try again.'),
        ),
      );
    }
  }

  Future<void> _confirmRemoval(
    BuildContext context,
    WidgetRef ref,
    OfflineLibrary downloads,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove download?'),
        content: Text(
          '${collection.name} will need an internet connection to play again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await downloads.removeCollection(collection.id);
    ref.invalidate(collectionsProvider);
    ref.invalidate(collectionProvider(collection.id));
  }
}

class _TrackTile extends ConsumerWidget {
  const _TrackTile({
    required this.collection,
    required this.track,
    required this.index,
  });

  final MusicCollection collection;
  final MusicTrack track;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerControllerProvider);
    final isCurrent =
        player.collection?.id == collection.id && player.currentIndex == index;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      leading: SizedBox(
        width: 34,
        child: Center(
          child: isCurrent && player.playing
              ? Icon(
                  Icons.graphic_eq_rounded,
                  color: Theme.of(context).colorScheme.primary,
                )
              : Text('${index + 1}', textAlign: TextAlign.center),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrent
            ? TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              )
            : null,
      ),
      subtitle: track.artist.isEmpty
          ? null
          : Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: track.duration == Duration.zero
          ? null
          : Text(_formatDuration(track.duration)),
      enabled: !player.loading,
      onTap: () async {
        final api = ref.read(apiClientProvider);
        if (api == null) {
          return;
        }
        await ref
            .read(playerControllerProvider)
            .playCollection(
              collection: collection,
              initialIndex: index,
              api: api,
              downloads: ref.read(offlineLibraryProvider),
            );
        final error = ref.read(playerControllerProvider).error;
        if (error != null && context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error)));
        }
      },
    );
  }
}

String _formatDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
