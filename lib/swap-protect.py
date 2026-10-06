#!/usr/bin/env python3
"""Inspect and retire disk swap without parsing paths as shell commands."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


def unescape(value):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), value)


def read_swaps():
    rows = []
    for line in Path('/proc/swaps').read_text(errors='surrogateescape').splitlines()[1:]:
        fields = line.split()
        if len(fields) != 5:
            raise ValueError('Malformed /proc/swaps entry')
        path, kind, size, used, _ = fields
        rows.append(dict(path=unescape(path), type=kind,
                         size_kib=int(size), used_kib=int(used)))
    return rows


def zram_name(path):
    canonical = os.path.realpath(path)
    if re.fullmatch(r'/dev/zram[0-9]+', canonical):
        try:
            if stat.S_ISBLK(os.stat(canonical).st_mode):
                return os.path.basename(canonical)
        except OSError:
            pass
    return None


def healthy_zram(rows=None):
    found = False
    for row in read_swaps() if rows is None else rows:
        name = zram_name(row['path'])
        if not name or row['size_kib'] <= 0:
            continue
        found = True
        backing = Path('/sys/block') / name / 'backing_dev'
        try:
            value = backing.read_text().strip()
        except FileNotFoundError:
            # Older kernels do not support zram writeback.
            continue
        if value != 'none':
            return False
    return found


def disk_swaps(rows=None):
    return [row for row in (read_swaps() if rows is None else rows)
            if not zram_name(row['path'])]


def identity(path):
    try:
        value = os.lstat(path)
    except FileNotFoundError:
        return dict(dev=None, ino=None, regular=False, nlink=None)
    return dict(dev=value.st_dev, ino=value.st_ino,
                regular=stat.S_ISREG(value.st_mode), nlink=value.st_nlink)


def inspect():
    rows = read_swaps()
    return dict(disk_swaps=[dict(row, **identity(row['path']))
                            for row in disk_swaps(rows)],
                healthy_zram=healthy_zram(rows))


def disable_fstab(source, target):
    lines = []
    for line in Path(source).read_text(errors='surrogateescape').splitlines(keepends=True):
        fields = line.split()
        if fields and not fields[0].startswith('#'):
            if len(fields) < 3:
                raise ValueError('Malformed fstab entry; refusing modification')
            if fields[2] == 'swap' and not zram_name(unescape(fields[0])):
                # Preserve a currently absent direct zram device as well.
                if not re.fullmatch(r'/dev/zram[0-9]+', unescape(fields[0])):
                    line = '# emmc-protect: ' + line
        lines.append(line)
    Path(target).write_text(''.join(lines), errors='surrogateescape')


def sufficient_memory(rows):
    mem = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        fields = line.split()
        if fields[0] in ('MemTotal:', 'MemAvailable:'):
            mem[fields[0][:-1]] = int(fields[1])
    if 'MemTotal' not in mem or 'MemAvailable' not in mem:
        raise ValueError('Cannot determine available memory')
    reserve = max(64 * 1024, mem['MemTotal'] // 10)
    return mem['MemAvailable'] >= sum(row['used_kib'] for row in rows) + reserve


def deletable(row):
    path = row['path']
    if not os.path.isabs(path) or row['type'] != 'file':
        return False
    canonical = os.path.realpath(path)
    for prefix in ('/dev', '/proc', '/sys', '/run'):
        if any(value == prefix or value.startswith(prefix + '/')
               for value in (path, canonical)):
            return False
    current = identity(path)
    return (row.get('regular') is True and current['regular']
            and row.get('nlink') == current['nlink'] == 1
            and row.get('dev') is not None
            and row.get('ino') is not None
            and (row['dev'], row['ino']) == (current['dev'], current['ino']))


def retire(snapshot, delete=False):
    initial = snapshot['disk_swaps']
    paths = [row['path'] for row in initial]
    if len(paths) != len(set(paths)) or any(not os.path.isabs(path) for path in paths):
        raise ValueError('Invalid swap snapshot paths')
    expected = set(paths)
    for row in initial:
        active = read_swaps()
        disks = disk_swaps(active)
        if not healthy_zram(active):
            raise RuntimeError('No active zram without disk writeback; keeping disk swap')
        if any(item['path'] not in expected for item in disks):
            raise RuntimeError('New disk swap appeared after inspection; stopping')
        current = next((item for item in disks if item['path'] == row['path']), None)
        if current is None:
            # Never delete an inactive file merely because it appears in a snapshot.
            continue
        if current['type'] != row['type'] or identity(row['path']) != {
                key: row[key] for key in ('dev', 'ino', 'regular', 'nlink')}:
            raise RuntimeError('Swap identity changed after inspection; stopping')
        if not sufficient_memory(disks):
            raise RuntimeError('Insufficient available memory to retire disk swap safely')
        subprocess.run(['swapoff', '--', row['path']], check=True)
        remaining = disk_swaps()
        if any(item['path'] == row['path'] for item in remaining):
            raise RuntimeError('swapoff returned success but target remains active')
        if any(item['path'] not in expected for item in remaining):
            raise RuntimeError('New disk swap appeared while retiring swap; stopping')
        print('Retired disk swap: ' + repr(row['path']))
    if disk_swaps():
        raise RuntimeError('Disk swap still active after retirement; stopping')
    if delete:
        delete_files(snapshot)


def delete_files(snapshot):
    if not healthy_zram():
        raise RuntimeError('No healthy active zram; refusing deletion')
    if disk_swaps():
        raise RuntimeError('Disk swap is still active; refusing deletion')
    for row in snapshot['disk_swaps']:
        if row['type'] != 'file':
            continue
        # Recheck before each unlink in case an external manager activated swap.
        if not healthy_zram():
            raise RuntimeError('Healthy zram disappeared before deletion; stopping')
        if disk_swaps():
            raise RuntimeError('Disk swap appeared before deletion; stopping')
        if not deletable(row):
            raise RuntimeError('Swap file is not safe to delete; kept: ' + repr(row['path']))
        os.unlink(row['path'])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('inspect')
    sub.add_parser('healthy-zram')
    fstab = sub.add_parser('disable-fstab')
    fstab.add_argument('source')
    fstab.add_argument('target')
    removal = sub.add_parser('retire')
    removal.add_argument('snapshot')
    removal.add_argument('--delete', action='store_true')
    for name in ('off', 'delete'):
        action = sub.add_parser(name)
        action.add_argument('snapshot')
    args = parser.parse_args(argv)
    try:
        if args.command == 'inspect':
            print(json.dumps(inspect(), ensure_ascii=True))
        elif args.command == 'healthy-zram':
            return 0 if healthy_zram() else 1
        elif args.command == 'disable-fstab':
            disable_fstab(args.source, args.target)
        elif args.command == 'retire':
            retire(json.loads(Path(args.snapshot).read_text()), args.delete)
        elif args.command == 'off':
            retire(json.loads(Path(args.snapshot).read_text()))
        else:
            delete_files(json.loads(Path(args.snapshot).read_text()))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print('swap-protect: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
