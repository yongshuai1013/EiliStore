#!/usr/bin/env python3
import importlib.util
import pathlib
import struct
import unittest

spec = importlib.util.spec_from_file_location('audit', pathlib.Path(__file__).resolve().parents[1] / 'Scripts/audit-ios-archive.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def object_file(major=15, platform=2, legacy=False, metadata=True):
    version = major << 16
    command = (struct.pack('<4I', 0x25, 16, version, 0) if legacy else
               struct.pack('<6I', 0x32, 24, platform, version, 0, 0)) if metadata else b''
    return struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 1, int(metadata), len(command), 0, 0) + command


def member(name, payload, bsd=False):
    if bsd:
        encoded = name.encode()
        payload = encoded + payload
        name = '#1/' + str(len(encoded))
    h = f'{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(payload):<10}`\n'.encode()
    return h + payload + (b'\n' if len(payload) % 2 else b'')


def archive(*members):
    return b'!<arch>\n' + b''.join(members)


class AuditTests(unittest.TestCase):
    def test_ios15_and_older(self):
        self.assertEqual(sum(audit.audit(archive(member('one.o/', object_file()), member('two.o/', object_file(12)))).values()), 2)

    def test_legacy_version_command(self):
        self.assertEqual(sum(audit.audit(archive(member('old.o/', object_file(legacy=True)))).values()), 1)

    def test_bsd_long_name_and_symbol_table(self):
        data = archive(member('__.SYMDEF SORTED', b'symbols', True), member('a-long-rust-object.rcgu.o', object_file(), True))
        self.assertEqual(sum(audit.audit(data).values()), 1)

    def test_reject_any_ios17_member(self):
        with self.assertRaisesRegex(ValueError, 'exceeds'):
            audit.audit(archive(member('good.o/', object_file()), member('bad.o/', object_file(17))))

    def test_reject_simulator(self):
        with self.assertRaisesRegex(ValueError, 'platform'):
            audit.audit(archive(member('sim.o/', object_file(platform=7))))

    def test_reject_missing_metadata(self):
        with self.assertRaisesRegex(ValueError, 'metadata'):
            audit.audit(archive(member('unknown.o/', object_file(metadata=False))))

    def test_reject_non_macho_member(self):
        with self.assertRaises(ValueError):
            audit.audit(archive(member('bitcode.o/', b'BC\xc0\xde')))

    def test_reject_empty_archive(self):
        with self.assertRaises(ValueError):
            audit.audit(archive())

    def test_reject_truncated_archive(self):
        with self.assertRaises(ValueError):
            audit.audit(archive(member('one.o/', object_file()))[:-2])

    def test_reject_bad_load_command(self):
        data = bytearray(object_file())
        struct.pack_into('<I', data, 36, 999)
        with self.assertRaises(ValueError):
            audit.audit(archive(member('broken.o/', bytes(data))))

    def test_reject_missing_odd_member_padding(self):
        data = archive(member('odd.o/', object_file() + b'\0'))
        with self.assertRaises(ValueError):
            audit.audit(data[:-1])

    def test_reject_missing_build_tool_record(self):
        data = bytearray(object_file())
        struct.pack_into('<I', data, 52, 1)
        with self.assertRaisesRegex(ValueError, 'build-tool'):
            audit.audit(archive(member('broken.o/', bytes(data))))


if __name__ == '__main__':
    unittest.main()
