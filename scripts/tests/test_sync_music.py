"""Real FFmpeg/rsync integration checks against a temporary local 'server'."""
import argparse
import importlib.util
import io
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "sync_music.py"
SPEC = importlib.util.spec_from_file_location("sync_music", SCRIPT)
sync_music = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync_music)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("rsync"), "requires ffmpeg and rsync")
class MusicSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "Music with spaces"
        self.source.mkdir()
        self.remote = self.root / "server's music"
        self.remote.mkdir()
        self.args = argparse.Namespace(source=self.source, host="test-host",
                                       remote_dir=str(self.remote), collection="Purchased Music",
                                       cache=self.root / "cache", settle_seconds=0, dry_run=False)
        self.transfers = 0

        def local_ssh(host, command):
            # Execute the exact remote inventory/mkdir program, with its quoted arguments.
            self.assertEqual(host, "test-host")
            return subprocess.run(["sh", "-c", command], check=True,
                                  capture_output=True, text=True).stdout

        def local_run(command, **kwargs):
            if command[0] == "rsync":
                self.transfers += 1
                command = list(command)
                command[-1] = shlex.split(command[-1].split(":", 1)[1])[0]
            return subprocess.run(command, check=True, **kwargs)

        self.addCleanup(patch.stopall)
        patch.object(sync_music, "ssh", side_effect=local_ssh).start()
        patch.object(sync_music, "run", side_effect=local_run).start()
        patch("sys.stdout", new=io.StringIO()).start()
        patch("sys.stderr", new=io.StringIO()).start()

    def song(self, name="song.m4a", frequency=440):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi",
                        "-i", f"sine=frequency={frequency}:duration=0.2", "-metadata", "title=Song",
                        "-metadata", "artist=Artist", "-metadata", "album=Album", str(path)],
                       check=True, capture_output=True)
        return path

    def remote_songs(self):
        return sorted(self.remote.rglob("*.mp3"))

    def test_repeat_rename_copy_and_cache_loss_never_add_duplicates(self):
        original = self.song()
        self.assertEqual(sync_music.sync(self.args), 0)
        first = self.remote_songs()
        self.assertEqual(len(first), 1)
        self.assertEqual(sync_music.sync(self.args), 0)
        original.rename(self.source / "renamed.m4a")
        shutil.copyfile(self.source / "renamed.m4a", self.source / "copy.m4a")
        self.assertEqual(sync_music.sync(self.args), 0)
        shutil.rmtree(self.args.cache)
        self.assertEqual(sync_music.sync(self.args), 0)
        self.assertEqual(self.remote_songs(), first)
        self.assertEqual(self.transfers, 1)

    def test_retagged_source_and_preexisting_mp3_are_recognized(self):
        original = self.song()
        old = self.remote / "Existing playlist" / "Old filename.mp3"
        old.parent.mkdir()
        sync_music.convert(original, old)
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(original),
                        "-c", "copy", "-metadata", "title=Retagged", str(self.source / "retagged.m4a")],
                       check=True, capture_output=True)
        original.unlink()
        self.assertEqual(sync_music.sync(self.args), 0)
        self.assertEqual(self.remote_songs(), [old])
        self.assertEqual(self.transfers, 0)

    def test_different_mp3_seek_headers_are_not_different_songs(self):
        original = self.song()
        mp3 = self.root / "with-xing.mp3"
        sync_music.convert(original, mp3)
        existing = self.remote / "without-xing.mp3"
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(mp3),
                        "-c", "copy", "-write_xing", "0", str(existing)],
                       check=True, capture_output=True)
        self.assertNotEqual(existing.read_bytes(), mp3.read_bytes())
        self.assertEqual(sync_music.mp3_audio_hash(existing), sync_music.mp3_audio_hash(mp3))
        self.assertEqual(sync_music.sync(self.args), 0)
        self.assertEqual(self.remote_songs(), [existing])

    def test_distinct_audio_with_same_title_is_kept_and_deletions_do_not_propagate(self):
        self.song("one/song.m4a")
        self.song("two/song.m4a", frequency=880)
        self.assertEqual(sync_music.sync(self.args), 0)
        self.assertEqual(len(self.remote_songs()), 2)
        shutil.rmtree(self.source)
        self.source.mkdir()
        self.assertEqual(sync_music.sync(self.args), 0)
        self.assertEqual(len(self.remote_songs()), 2)

    def test_dry_run_does_not_create_remote_directory_or_transfer(self):
        self.song()
        self.remote.rmdir()
        self.args.dry_run = True
        self.assertEqual(sync_music.sync(self.args), 0)
        self.assertFalse(self.remote.exists())
        self.assertEqual(self.transfers, 0)
        self.assertEqual(len(list((self.args.cache / "mp3").glob("*.mp3"))), 1)

    def test_recent_and_invalid_downloads_are_not_published(self):
        path = self.song()
        self.args.settle_seconds = 60
        self.assertEqual(sync_music.sync(self.args), 0)
        self.assertEqual(self.remote_songs(), [])
        self.args.settle_seconds = 0
        path.write_bytes(b"not an audio file")
        self.assertEqual(sync_music.sync(self.args), 1)
        self.assertEqual(self.remote_songs(), [])

    def test_source_changed_during_conversion_is_not_published(self):
        path = self.song()
        convert = sync_music.convert

        def changing_convert(source, output):
            convert(source, output)
            path.touch()

        with patch.object(sync_music, "convert", side_effect=changing_convert):
            self.assertEqual(sync_music.sync(self.args), 1)
        self.assertEqual(self.remote_songs(), [])
        self.assertEqual(sync_music.sync(self.args), 0)
        self.assertEqual(len(self.remote_songs()), 1)

    def test_interrupted_transfer_retries_without_converting_again(self):
        self.song()
        saved_run = sync_music.run

        def failed_transfer(command, **kwargs):
            if command[0] == "rsync":
                raise subprocess.CalledProcessError(12, command)
            return saved_run(command, **kwargs)

        with patch.object(sync_music, "run", side_effect=failed_transfer):
            with self.assertRaises(subprocess.CalledProcessError):
                sync_music.sync(self.args)
        with patch.object(sync_music, "convert", side_effect=AssertionError("unexpected conversion")):
            self.assertEqual(sync_music.sync(self.args), 0)
            self.assertEqual(sync_music.sync(self.args), 0)
        self.assertEqual(len(self.remote_songs()), 1)

    def test_existing_mp3_metadata_and_playable_audio_are_preserved(self):
        original = self.song()
        mp3 = self.source / "already.mp3"
        sync_music.convert(original, mp3)
        original.unlink()
        self.assertEqual(sync_music.sync(self.args), 0)
        result = self.remote_songs()[0]
        self.assertEqual(result.read_bytes(), mp3.read_bytes())
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-xerror", "-i", str(result),
                        "-f", "null", "-"], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
