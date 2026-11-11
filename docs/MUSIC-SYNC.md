# Sync purchases from Mac to Linux

`scripts/sync_music.py` converts downloaded music to MP3 and copies new songs to
the server over SSH. It leaves originals and existing server songs in place.
The defaults target `elitedesk-1:/home/justin/museek/music/Purchased Music/`.

Requirements: Python 3, FFmpeg (with libmp3lame), rsync and SSH on the Mac;
Python 3 and rsync on Linux. The current machines already have these tools.
SSH must work without prompting (`ssh -o BatchMode=yes elitedesk-1 true`), and
the Mac must be connected to Tailscale to reach the pilot host. Connect normally
once to verify a new host's SSH key before scheduling the script.

From the repository root, preview the current Mac's downloaded library:

```sh
python3 scripts/sync_music.py "$HOME/Music/Music/Media.localized/Music" --dry-run
```

Then transfer:

```sh
python3 scripts/sync_music.py "$HOME/Music/Music/Media.localized/Music"
```

`--dry-run` checks the real server and creates local converted files, but does
not write to the server. Override `--host`, `--remote-dir`, `--collection` or
`--cache` for another installation. The remote directory must be the existing
Museek **music root**, not its data/uploads directory. Only downloaded files are
available to sync; cloud-only purchases must first be downloaded in Music.

The script searches subfolders for M4A/AAC, FLAC, MP3, WAV and AIFF. MP3s are copied
without another audio encode; other formats use the existing converter's
high-quality MP3 settings and retain embedded tags and artwork. Protected files
that FFmpeg cannot decode are reported as failures; other songs can still transfer.
Files modified within the last minute are deferred until the next run. Conversion
failures and sources that change during conversion are never published. A failed
run exits nonzero, so check both the summary and error log.

## Duplicate handling

- Source identity is a SHA-256 hash of audio packets, independent of filenames,
  tags and artwork. Renaming, copying or retagging an input reuses its converted
  file. Existing MP3s are compared across **all folders** under the server music
  root, including playlists imported before this script existed.
- MP3 comparison ignores ID3 tags and Xing/Info seek headers. Different artwork
  or seek-header sizes do not create another song. Stable source-based filenames
  also prevent reimports after deleting the Mac's conversion cache.
- A repeated run does not send songs already present. Transfers publish completed
  files using rsync's temporary-file/rename behavior; an interrupted transfer can
  be retried. A local lock prevents overlapping runs using the same cache.
- Matching is exact audio matching, not an artist/title guess or acoustic
  fingerprint. Independently encoded copies of the same recording can still be
  different. Distinct recordings with identical titles/tags are retained. Existing
  duplicates are never deleted or merged, preserving playlist entries and notes.

Conversions are cached under
`~/Library/Application Support/Museek/music-sync/`. Keep this directory to avoid
reconverting tracks. Imports retain the metadata from the first converted copy;
this is an append-only import, not a metadata editor or two-way mirror. Removing
downloads from the Mac does not remove server songs. Changing the collection name
is unnecessary and does not move previously imported tracks.

New songs enter the shared **All songs** library and the folder's **Purchased
Music** playlist. Existing songs recognized in other playlists stay there and
remain selectable from All songs; they are not copied into Purchased Music.
The checked-in pilot scans every 45 seconds. Refresh the browser manager after
that scan to see imports. The new playlist is not automatically shared with
listeners; use the manager to add songs to their existing playlists.

## Run automatically on this Mac

The example LaunchAgent uses this checkout's current absolute paths and runs
every five minutes while the user is logged in and the Mac is awake. Review its
paths before installing on another Mac (launchd does not expand `~` or `$HOME`).
Music must download purchases first; enable Music's automatic downloads if you
also buy on other devices. A sleeping/offline Mac catches up on a later run.

```sh
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp scripts/music-sync.launchagent.plist.example "$HOME/Library/LaunchAgents/com.museek.music-sync.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.museek.music-sync.plist"
```

If already installed, unload it before replacing the plist:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.museek.music-sync.plist"
```

Normal output is in `~/Library/Logs/Museek-music-sync.log`; errors are in
`~/Library/Logs/Museek-music-sync-errors.log`. An SSH failure preserves the local
conversion cache and retries at the next scheduled interval. The job does not
store Apple credentials or control the Music app.

## Verification

```sh
python3 -m unittest discover -s scripts/tests -p 'test_sync_music.py' -v
```

These checks use real FFmpeg conversions and real local rsync transfers into a
temporary server directory. They cover repeat runs, renamed/retagged copies,
preexisting playlist files, different seek headers, distinct audio with matching
tags, cache loss, dry runs, source changes, recent/invalid downloads, interrupted
transfer retries, and preserving existing MP3 bytes.

## Pilot verification, November 11, 2026

The actual Mac library contained 19 M4As. The script recognized 16 songs already
in the server's existing playlist and transferred only three new songs. A server
scan reported two collections and 20 songs, and the private web manager displayed
the three additions. The original 17-song playlist was preserved.

The LaunchAgent is installed at
`~/Library/LaunchAgents/com.museek.music-sync.plist`, with a 300-second interval.
Its first background run exited successfully: 19 recognized, zero converted,
zero transferred. Nine music-sync integration tests passed, along with the five
existing release-script checks; the LaunchAgent also passed `plutil -lint`.
