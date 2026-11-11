#!/usr/bin/env python3
"""Incrementally convert local music and copy new songs to Museek over SSH."""

import argparse
from contextlib import contextmanager
import fcntl
import inspect
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


FORMATS = {".m4a", ".aac", ".flac", ".mp3", ".wav", ".aiff", ".aif"}


def mp3_audio_hash(path):
    """Hash MPEG audio without ID3 tags or the optional Xing/Info seek frame."""
    import hashlib

    with open(path, "rb") as stream:
        stream.seek(0, 2)
        end = stream.tell()
        stream.seek(0)
        header = stream.read(10)
        start = 0
        if len(header) == 10 and header[:3] == b"ID3":
            if any(byte & 0x80 for byte in header[6:10]):
                raise ValueError("invalid ID3 size")
            size = 0
            for byte in header[6:10]:
                size = (size << 7) | byte
            start = 10 + size
            if header[3] == 4 and header[5] & 0x10:
                start += 10  # ID3v2.4 footer
        if end >= 128:
            stream.seek(end - 128)
            if stream.read(3) == b"TAG":
                end -= 128
        # FFmpeg can choose different sizes for this non-audio frame (for
        # example when cover art is present). Its contents aren't a song change.
        stream.seek(start)
        frame = stream.read(42)
        if len(frame) >= 4 and frame[0] == 0xFF and frame[1] & 0xE0 == 0xE0:
            version = (frame[1] >> 3) & 3
            layer = (frame[1] >> 1) & 3
            bitrate_index = frame[2] >> 4
            sample_index = (frame[2] >> 2) & 3
            if version != 1 and layer == 1 and 0 < bitrate_index < 15 and sample_index < 3:
                rates = ([0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                         if version == 3 else
                         [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
                sample_rate = [44100, 48000, 32000][sample_index] // {3: 1, 2: 2, 0: 4}[version]
                mono = frame[3] >> 6 == 3
                side_size = (17 if mono else 32) if version == 3 else (9 if mono else 17)
                marker = 4 + (0 if frame[1] & 1 else 2) + side_size
                if frame[marker:marker + 4] in (b"Xing", b"Info"):
                    start += ((144000 if version == 3 else 72000) * rates[bitrate_index]
                              // sample_rate + ((frame[2] >> 1) & 1))
        if start >= end:
            raise ValueError("empty MP3 audio")
        stream.seek(start)
        digest = hashlib.sha256()
        remaining = end - start
        while remaining:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError("MP3 changed while being read")
            digest.update(chunk)
            remaining -= len(chunk)
        return digest.hexdigest()


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def ssh(host, command):
    return run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                host, command], capture_output=True, text=True).stdout


def remote_inventory(host, root):
    # Python's standard library is the only server-side dependency besides rsync.
    program = inspect.getsource(mp3_audio_hash) + '''
import json
import os
import sys
root = sys.argv[1]
result = {}
def fail(error):
    raise error
if os.path.exists(root) and not os.path.isdir(root):
    raise ValueError('music root is not a directory')
for folder, dirs, files in os.walk(root, followlinks=False,
                                  onerror=fail if os.path.exists(root) else None):
    dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(folder, d))]
    for name in files:
        path = os.path.join(folder, name)
        if name.lower().endswith('.mp3') and not os.path.islink(path):
            result[os.path.relpath(path, root)] = mp3_audio_hash(path)
print(json.dumps(result))
'''
    command = "python3 -c " + shlex.quote(program) + " " + shlex.quote(root)
    return json.loads(ssh(host, command))


def signature(path):
    info = path.stat()
    return [info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def cached_output_valid(path, digest):
    try:
        return path.is_file() and (not digest or mp3_audio_hash(path) == digest)
    except (OSError, ValueError):
        return False


def audio_identity(path):
    # Hash compressed audio packets, excluding filenames, tags and cover art.
    output = run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-xerror",
                  "-i", str(path), "-map", "0:a:0", "-c:a", "copy", "-f", "hash",
                  "-hash", "sha256", "-"], capture_output=True, text=True).stdout
    algorithm, digest = output.strip().split("=", 1)
    if algorithm != "SHA256" or len(digest) != 64:
        raise ValueError("unexpected ffmpeg audio hash")
    return digest


def convert(path, output):
    if path.suffix.lower() == ".mp3":
        shutil.copyfile(path, output)
    else:
        run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-xerror",
             "-i", str(path), "-map", "0:a:0", "-map", "0:v:0?", "-map_metadata", "0",
             "-c:a", "libmp3lame", "-q:a", "0", "-c:v", "copy",
             "-disposition:v", "attached_pic", "-id3v2_version", "3",
             "-write_id3v1", "1", "-y", str(output)], capture_output=True, text=True)


def save_manifest(path, manifest):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(path)


@contextmanager
def cache_lock(cache):
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "sync.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("another music sync is already using this cache")
        yield


def sync(args):
    cache = args.cache.expanduser().resolve()
    source = args.source.expanduser().resolve()
    if not source.is_dir():
        raise ValueError(f"music directory does not exist: {source}")
    if cache == source or source in cache.parents or cache in source.parents:
        raise ValueError("source and cache must be separate directories")
    if not args.host or args.host.startswith("-") or any(c.isspace() for c in args.host):
        raise ValueError("host must be an SSH hostname or user@hostname")
    if not args.remote_dir.startswith("/") or "\n" in args.remote_dir:
        raise ValueError("remote directory must be an absolute Linux path")
    if args.settle_seconds < 0:
        raise ValueError("settle seconds cannot be negative")
    if args.collection in {"", ".", ".."} or any(c in args.collection for c in "/\n"):
        raise ValueError("collection must be a single folder name")
    for name in ("ffmpeg", "ssh", "rsync"):
        if not shutil.which(name):
            raise ValueError(f"{name} is required")

    with cache_lock(cache):
        print("Checking existing server music…", flush=True)
        inventory = remote_inventory(args.host, args.remote_dir)
        known_audio = set(inventory.values())
        manifest_path = cache / "manifest.json"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        outputs = cache / "mp3"
        outputs.mkdir(exist_ok=True)
        pending = {}
        duplicates = deferred = failures = converted = 0
        files = sorted(p for p in source.rglob("*")
                       if p.is_file() and not p.is_symlink() and p.suffix.lower() in FORMATS)
        for path in files:
            try:
                before = signature(path)
                if time.time() - path.stat().st_mtime < args.settle_seconds:
                    deferred += 1
                    continue
                key = str(path.relative_to(source))
                # Include the source root so a cache can safely be reused with another folder.
                record_key = str(path)
                record = manifest.get(record_key, {})
                identity = record.get("identity") if record.get("signature") == before else None
                if not identity:
                    identity = audio_identity(path)
                output = outputs / (identity + ".mp3")
                remote_name = args.collection + "/" + output.name
                # Source-based names also avoid reimports after cache loss/encoder upgrades.
                if remote_name in inventory:
                    if signature(path) != before:
                        raise ValueError("source changed during import; try again later")
                    manifest[record_key] = {"signature": before, "identity": identity,
                                            "output_hash": record.get("output_hash")}
                    save_manifest(manifest_path, manifest)
                    duplicates += 1
                    continue
                if not cached_output_valid(output, record.get("output_hash")):
                    with tempfile.TemporaryDirectory(dir=cache) as temporary:
                        staged = Path(temporary) / "song.mp3"
                        convert(path, staged)
                        if signature(path) != before:
                            raise ValueError("source changed during conversion; try again later")
                        staged.replace(output)
                    converted += 1
                digest = mp3_audio_hash(output)
                if signature(path) != before:
                    raise ValueError("source changed during import; try again later")
                manifest[record_key] = {"signature": before, "identity": identity,
                                        "output_hash": digest}
                save_manifest(manifest_path, manifest)
                if digest in known_audio:
                    duplicates += 1
                    continue
                known_audio.add(digest)
                pending[output.name] = output
                print(f"{'Would add' if args.dry_run else 'Adding'}: {key}", flush=True)
            except (OSError, ValueError, subprocess.CalledProcessError) as error:
                failures += 1
                detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
                print(f"Skipped {path.name}: {detail}", file=sys.stderr)

        if pending and not args.dry_run:
            destination = args.remote_dir.rstrip("/") + "/" + args.collection
            ssh(args.host, "mkdir -p -- " + shlex.quote(destination))
            # Only this run's new songs are sent. No --delete and no --inplace:
            # rsync publishes each completed file with a rename; retries reuse its name.
            with tempfile.TemporaryDirectory(dir=cache) as temporary:
                staging = Path(temporary)
                for name, output in pending.items():
                    os.link(output, staging / name)
                run(["rsync", "-rt", "--ignore-existing", "--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r",
                     "-e", "ssh -o BatchMode=yes -o ConnectTimeout=15", str(staging) + "/",
                     args.host + ":" + shlex.quote(destination + "/")])
        action = "would transfer" if args.dry_run else "transferred"
        print(f"{len(files)} files; {converted} converted; {duplicates} already present/duplicates; "
              f"{deferred} recent downloads deferred; {failures} failed; {len(pending)} {action}.")
        return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="downloaded music folder (searched recursively)")
    parser.add_argument("--host", default="elitedesk-1", help="SSH host (default: elitedesk-1)")
    parser.add_argument("--remote-dir", default="/home/justin/museek/music",
                        help="server's existing Museek music root")
    parser.add_argument("--collection", default="Purchased Music", help="destination playlist folder")
    parser.add_argument("--cache", type=Path,
                        default=Path.home() / "Library/Application Support/Museek/music-sync",
                        help="persistent local conversion cache")
    parser.add_argument("--settle-seconds", type=int, default=60,
                        help="wait for downloads to settle (default: 60 seconds)")
    parser.add_argument("--dry-run", action="store_true",
                        help="convert/cache and check duplicates, but do not write to the server")
    args = parser.parse_args()
    try:
        return sync(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"Music sync failed: {detail}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
