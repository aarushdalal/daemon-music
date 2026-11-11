#!/usr/bin/env python3
"""Prepare private local pairing; never runs Spicetify apply or restarts Spotify."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import importlib.util
import json
import os
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('music_bridge', ROOT/'backend/music_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def atomic(path, value, mode):
    if path.is_symlink():
        raise ValueError('Symlink destination refused')
    fd, name = tempfile.mkstemp(prefix='.daemon-music-', dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(value); f.flush(); os.fsync(f.fileno())
        os.chmod(name,mode); os.replace(name,path)
    finally:
        Path(name).unlink(missing_ok=True)


def prepare(state, spicetify):
    key = bridge.private_key(state, initialize=True)
    if spicetify.is_symlink() or (spicetify/'Extensions').is_symlink():
        raise ValueError('Symlink extension directory refused')
    extensions = spicetify/'Extensions'
    extensions.mkdir(parents=True,exist_ok=True)
    backup = state/('pairing-backup-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    backup.mkdir(mode=0o700)
    content = {
        'daemon-music.js':(ROOT/'spicetify/daemon-music.js').read_bytes(),
        'daemon-music-session.js':('globalThis.__DaemonMusicSession='+json.dumps({'base':'http://127.0.0.1:8975','key':key})+';\n').encode()
    }
    for name,data in content.items():
        target = extensions/name
        if target.is_symlink():raise ValueError('Symlink extension refused')
        if target.exists():
            shutil.copyfile(target,backup/name); (backup/name).chmod(0o600)
        atomic(target,data,0o600 if name.endswith('session.js') else 0o644)
    return backup


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir',type=Path,default=Path.home()/'.local/state/daemon-music')
    parser.add_argument('--spicetify-dir',type=Path,default=Path.home()/'.config/spicetify')
    args=parser.parse_args()
    saved=prepare(args.state_dir,args.spicetify_dir)
    print('Prepared public extension + private local bootstrap. Existing files backed up at '+str(saved))
    print('Exclude pairing.key, daemon-music-session.js and pairing backups from sync/publication.')
    print('Then run: spicetify config extensions daemon-music-session.js daemon-music.js')
    print('Apply with the official Spicetify CLI when ready; preserve private bootstrap permissions in generated assets.')
