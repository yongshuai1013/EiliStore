#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest


spec = importlib.util.spec_from_file_location(
    'verify_anisette_link_map',
    pathlib.Path(__file__).resolve().parents[1] / 'Scripts/verify-anisette-link-map.py',
)
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


SYMBOL = b'0x0000000000001234  (__TEXT,__text) external _get_anisette_headers_uc\n'


def link_map(*records):
    return b'# Object files:\n' + b''.join(records)


class ProductionLinkMapTests(unittest.TestCase):
    def test_active_symbol_is_detected(self):
        data = link_map(b'# Symbols:\n', SYMBOL, b'# Dead Stripped Symbols:\n')
        self.assertTrue(verify.linked_native_engine(data))

    def test_invalid_utf8_in_another_active_symbol_does_not_break_detection(self):
        data = link_map(
            b'# Symbols:\n',
            b'0x0000000000001000  (__TEXT,__text) external _some_symbol_\xff\xfe\n',
            SYMBOL,
            b'# Dead Stripped Symbols:\n',
        )
        self.assertTrue(verify.linked_native_engine(data))

    def test_symbol_only_in_dead_stripped_section_is_not_active(self):
        data = link_map(b'# Symbols:\n', b'# Dead Stripped Symbols:\n', SYMBOL)
        self.assertFalse(verify.linked_native_engine(data))

    def test_api_in_object_filename_before_symbols_is_not_active(self):
        data = link_map(
            b'  /path/to/object_get_anisette_headers_uc.o\n',
            b'# Symbols:\n',
            b'0x0000000000001234  (__TEXT,__text) external _unrelated_symbol\n',
            b'# Dead Stripped Symbols:\n',
        )
        self.assertFalse(verify.linked_native_engine(data))

    def test_missing_symbols_header_is_not_active(self):
        data = link_map(SYMBOL, b'# Dead Stripped Symbols:\n')
        self.assertFalse(verify.linked_native_engine(data))

    def test_missing_dead_stripped_header_keeps_active_section_open(self):
        data = link_map(b'# Symbols:\n', SYMBOL)
        self.assertTrue(verify.linked_native_engine(data))

    def test_function_name_suffix_is_not_an_exact_symbol_match(self):
        data = link_map(
            b'# Symbols:\n',
            b'0x0000000000001234  (__TEXT,__text) external _get_anisette_headers_uc_extra\n',
            b'# Dead Stripped Symbols:\n',
        )
        self.assertFalse(verify.linked_native_engine(data))


if __name__ == '__main__':
    unittest.main()
