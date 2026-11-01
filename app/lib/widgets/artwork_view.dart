import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_client.dart';
import '../offline_library.dart';
import '../providers.dart';

class ArtworkView extends ConsumerWidget {
  const ArtworkView({
    required this.artworkId,
    this.size,
    this.borderRadius = 16,
    super.key,
  });

  final String? artworkId;
  final double? size;
  final double borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiClientProvider);
    final downloads = ref.watch(offlineLibraryProvider);
    final id = artworkId;
    final dimensions = size == null
        ? const BoxConstraints.expand()
        : BoxConstraints.tightFor(width: size, height: size);
    if (id == null) {
      return _fallback(dimensions);
    }
    return FutureBuilder<Uint8List?>(
      future: _loadArtwork(downloads, api, id),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Container(
            constraints: dimensions,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
            ),
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallback(dimensions),
            ),
          );
        }
        return _fallback(
          dimensions,
          loading: snapshot.connectionState == ConnectionState.waiting,
        );
      },
    );
  }

  Future<Uint8List?> _loadArtwork(
    OfflineLibrary downloads,
    MuseekApiClient? api,
    String artworkId,
  ) async {
    final local = await downloads.localArtwork(artworkId);
    if (local != null) {
      return local;
    }
    return api?.artwork(artworkId);
  }

  Widget _fallback(BoxConstraints constraints, {bool loading = false}) {
    return Container(
      constraints: constraints,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7356E8), Color(0xFFBD68E8)],
        ),
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(
                Icons.music_note_rounded,
                color: Colors.white,
                size: 36,
              ),
      ),
    );
  }
}
