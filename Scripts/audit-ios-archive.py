#!/usr/bin/env python3
"""Fail closed unless every code member is arm64 iOS with min OS <= limit.

This checks build metadata, not runtime API availability or device compatibility.
Supports BSD/Darwin ar archives emitted by Apple's static-library tools.
"""
import argparse
import collections
import pathlib
import struct
import sys


def audit(data, maximum=(15, 0, 0)):
    if not data.startswith(b'!<arch>\n'):
        raise ValueError('not an ar static archive')
    offset = 8
    versions = collections.Counter()
    while offset < len(data):
        if offset + 60 > len(data):
            raise ValueError('truncated archive header')
        header = data[offset:offset + 60]
        if header[58:60] != b'`\n':
            raise ValueError('invalid archive header')
        size = int(header[48:58].strip())
        name = header[:16].decode('ascii').strip()
        start = offset + 60
        end = start + size
        if size < 0 or end + (size % 2) > len(data):
            raise ValueError('truncated archive member')
        payload = data[start:end]
        offset = end + (size % 2)
        if name.startswith('#1/'):
            name_size = int(name[3:])
            if name_size > len(payload):
                raise ValueError('truncated BSD member name')
            name = payload[:name_size].rstrip(b'\0').decode('utf-8')
            payload = payload[name_size:]
        name = name.rstrip('/')
        if name in ('__.SYMDEF', '__.SYMDEF SORTED', '__.SYMDEF_64', '__.SYMDEF_64 SORTED', '', '/SYM64'):
            continue
        if len(payload) < 32 or payload[:4] != b'\xcf\xfa\xed\xfe':
            raise ValueError(f'{name}: not a supported little-endian 64-bit Mach-O object')
        _, cpu, _, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from('<8I', payload)
        if cpu != 0x0100000C or filetype != 1:
            raise ValueError(f'{name}: expected arm64 MH_OBJECT')
        pos = 32
        commands_end = pos + sizeofcmds
        if commands_end > len(payload):
            raise ValueError(f'{name}: truncated load commands')
        found = []
        for _ in range(ncmds):
            if pos + 8 > commands_end:
                raise ValueError(f'{name}: missing load command')
            cmd, length = struct.unpack_from('<2I', payload, pos)
            if length < 8 or pos + length > commands_end:
                raise ValueError(f'{name}: invalid load command length')
            if cmd == 0x32:  # LC_BUILD_VERSION
                if length < 24:
                    raise ValueError(f'{name}: short LC_BUILD_VERSION')
                tools = struct.unpack_from('<I', payload, pos + 20)[0]
                if length != 24 + tools * 8:
                    raise ValueError(f'{name}: invalid build-tool records')
                platform, version = struct.unpack_from('<2I', payload, pos + 8)
                if platform != 2:
                    raise ValueError(f'{name}: expected iOS device platform, got {platform}')
                found.append(version)
            elif cmd == 0x25:  # LC_VERSION_MIN_IPHONEOS
                if length != 16:
                    raise ValueError(f'{name}: short LC_VERSION_MIN_IPHONEOS')
                found.append(struct.unpack_from('<I', payload, pos + 8)[0])
            elif cmd in (0x24, 0x2F, 0x30):
                raise ValueError(f'{name}: non-iOS minimum-version command')
            pos += length
        if pos != commands_end or len(found) != 1:
            raise ValueError(f'{name}: missing or ambiguous deployment metadata')
        version = found[0]
        minimum = (version >> 16, (version >> 8) & 255, version & 255)
        if minimum > maximum:
            raise ValueError(f'{name}: minimum iOS {minimum} exceeds {maximum}')
        versions[minimum] += 1
    if not versions:
        raise ValueError('no auditable Mach-O code members')
    return versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=pathlib.Path)
    args = parser.parse_args()
    try:
        versions = audit(args.archive.read_bytes())
    except (OSError, ValueError, struct.error, UnicodeError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    print(f'PASS: {sum(versions.values())} arm64 iOS objects; minimum-version counts: {dict(versions)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
