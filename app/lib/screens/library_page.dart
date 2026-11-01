import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_client.dart';
import '../models.dart';
import '../providers.dart';
import '../widgets/artwork_view.dart';
import '../widgets/player_bar.dart';
import 'collection_page.dart';
import 'settings_page.dart';

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(collectionsProvider);
    await ref.read(collectionsProvider.future);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(collectionsProvider);
    final session = ref.watch(sessionControllerProvider).session!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Museek'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _refresh(ref),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      bottomNavigationBar: const PlayerBar(),
      body: collections.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _LibraryError(
          message: _messageFor(error),
          revoked: error is ApiException && error.statusCode == 401,
          onRetry: () => ref.invalidate(collectionsProvider),
          onSignOut: () =>
              ref.read(sessionControllerProvider.notifier).signOut(),
        ),
        data: (items) => RefreshIndicator(
          onRefresh: () => _refresh(ref),
          child: items.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(32),
                  children: [
                    const SizedBox(height: 96),
                    const Icon(Icons.library_music_outlined, size: 64),
                    const SizedBox(height: 20),
                    Text(
                      'Nothing shared yet',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'When a collection is shared with ${session.recipientName}, it will appear here.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) =>
                      _CollectionCard(collection: items[index]),
                ),
        ),
      ),
    );
  }

  String _messageFor(Object error) {
    if (error is ApiException) {
      return error.message;
    }
    return 'Your library could not be loaded.';
  }
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({required this.collection});

  final CollectionSummary collection;

  @override
  Widget build(BuildContext context) {
    void openCollection() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CollectionPage(summary: collection),
        ),
      );
    }

    final trackLabel =
        '${collection.trackCount} ${collection.trackCount == 1 ? 'track' : 'tracks'}';
    return Semantics(
      button: true,
      label: '${collection.name}, $trackLabel',
      onTap: openCollection,
      child: ExcludeSemantics(
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: openCollection,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  ArtworkView(
                    artworkId: collection.artworkId,
                    size: 84,
                    borderRadius: 14,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          collection.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          trackLabel,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryError extends StatelessWidget {
  const _LibraryError({
    required this.message,
    required this.revoked,
    required this.onRetry,
    required this.onSignOut,
  });

  final String message;
  final bool revoked;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              revoked ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
              size: 56,
            ),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            if (revoked)
              FilledButton(
                onPressed: onSignOut,
                child: const Text('Pair again'),
              )
            else
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
          ],
        ),
      ),
    );
  }
}
