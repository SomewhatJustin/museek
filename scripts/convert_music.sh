#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 SOURCE_DIRECTORY DESTINATION_DIRECTORY" >&2
  exit 64
fi

source_directory=$1
destination_directory=$2

if [[ ! -d "$source_directory" ]]; then
  echo "Source directory does not exist: $source_directory" >&2
  exit 66
fi

if [[ -e "$destination_directory" ]]; then
  echo "Refusing to replace existing destination: $destination_directory" >&2
  exit 73
fi

temporary_directory=$(mktemp -d "${destination_directory}.tmp.XXXXXX")
source_hashes_before=$(
  find "$source_directory" -type f \( -iname '*.m4a' -o -iname '*.flac' \) \
    -exec shasum -a 256 {} + | sort
)

converted=0
while IFS= read -r -d '' input; do
  filename=$(basename "$input")
  stem=${filename%.*}
  output="$temporary_directory/$stem.mp3"

  ffmpeg -nostdin -hide_banner -loglevel error -i "$input" \
    -map 0:a:0 -map '0:v:0?' -map_metadata 0 \
    -c:a libmp3lame -q:a 0 \
    -c:v copy -disposition:v attached_pic \
    -id3v2_version 3 -write_id3v1 1 \
    "$output"

  converted=$((converted + 1))
  printf 'Converted %d: %s\n' "$converted" "$filename"
done < <(
  find "$source_directory" -type f \( -iname '*.m4a' -o -iname '*.flac' \) \
    -print0 | sort -z
)

source_hashes_after=$(
  find "$source_directory" -type f \( -iname '*.m4a' -o -iname '*.flac' \) \
    -exec shasum -a 256 {} + | sort
)

if [[ "$source_hashes_before" != "$source_hashes_after" ]]; then
  echo "A source file changed during conversion; output was not published." >&2
  exit 74
fi

output_count=$(find "$temporary_directory" -type f -iname '*.mp3' | wc -l | tr -d ' ')
if [[ $converted -eq 0 || $output_count -ne $converted ]]; then
  echo "Conversion count mismatch: converted $converted, found $output_count outputs." >&2
  exit 74
fi

mv -- "$temporary_directory" "$destination_directory"
echo "Published $converted MP3 files to $destination_directory"
