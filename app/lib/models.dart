class AppSession {
  const AppSession({
    required this.serverUrl,
    required this.token,
    required this.recipientId,
    required this.recipientName,
  });

  final String serverUrl;
  final String token;
  final String recipientId;
  final String recipientName;
}

class CollectionSummary {
  const CollectionSummary({
    required this.id,
    required this.name,
    required this.trackCount,
    this.artworkId,
  });

  factory CollectionSummary.fromJson(Map<String, dynamic> json) {
    return CollectionSummary(
      id: json['id'] as String,
      name: json['name'] as String,
      trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
      artworkId: _optionalString(json['artworkId']),
    );
  }

  final String id;
  final String name;
  final int trackCount;
  final String? artworkId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trackCount': trackCount,
    if (artworkId != null) 'artworkId': artworkId,
  };
}

class MusicTrack {
  const MusicTrack({
    required this.id,
    required this.collectionId,
    required this.title,
    required this.artist,
    required this.album,
    required this.discNumber,
    required this.trackNumber,
    required this.duration,
    this.artworkId,
  });

  factory MusicTrack.fromJson(Map<String, dynamic> json) {
    return MusicTrack(
      id: json['id'] as String,
      collectionId: json['collectionId'] as String,
      title: json['title'] as String,
      artist: _optionalString(json['artist']) ?? '',
      album: _optionalString(json['album']) ?? '',
      discNumber: (json['discNumber'] as num?)?.toInt() ?? 0,
      trackNumber: (json['trackNumber'] as num?)?.toInt() ?? 0,
      duration: Duration(
        milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0,
      ),
      artworkId: _optionalString(json['artworkId']),
    );
  }

  final String id;
  final String collectionId;
  final String title;
  final String artist;
  final String album;
  final int discNumber;
  final int trackNumber;
  final Duration duration;
  final String? artworkId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'collectionId': collectionId,
    'title': title,
    'artist': artist,
    'album': album,
    'discNumber': discNumber,
    'trackNumber': trackNumber,
    'durationMs': duration.inMilliseconds,
    if (artworkId != null) 'artworkId': artworkId,
  };
}

class MusicCollection extends CollectionSummary {
  const MusicCollection({
    required super.id,
    required super.name,
    required super.trackCount,
    required this.tracks,
    super.artworkId,
  });

  factory MusicCollection.fromJson(Map<String, dynamic> json) {
    return MusicCollection(
      id: json['id'] as String,
      name: json['name'] as String,
      trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
      artworkId: _optionalString(json['artworkId']),
      tracks: (json['tracks'] as List<dynamic>? ?? const [])
          .map((item) => MusicTrack.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  final List<MusicTrack> tracks;

  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'tracks': tracks.map((track) => track.toJson()).toList(growable: false),
  };
}

class PlaybackLocation {
  const PlaybackLocation({required this.url, required this.expiresAt});

  factory PlaybackLocation.fromJson(Map<String, dynamic> json) {
    return PlaybackLocation(
      url: Uri.parse(json['url'] as String),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  final Uri url;
  final DateTime expiresAt;
}

String? _optionalString(dynamic value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value;
}
