"""Uji unit untuk sanitasi nama dan utilitas waktu."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from macdrive_rescue import names
from macdrive_rescue.util import detect_unix_ns


class SanitizeTests(unittest.TestCase):
    def test_colon_replaced(self):
        self.assertEqual(names.sanitize_component("file:name.txt"), "file-name.txt")

    def test_illegal_chars(self):
        self.assertEqual(names.sanitize_component('a<b>c"d|e?f*g.txt'), "a_b_c_d_e_f_g.txt")

    def test_trailing_dots_spaces(self):
        self.assertEqual(names.sanitize_component("file. . "), "file")

    def test_reserved_names(self):
        self.assertEqual(names.sanitize_component("CON"), "_CON")
        self.assertEqual(names.sanitize_component("nul.txt"), "_nul.txt")
        self.assertEqual(names.sanitize_component("COM7.tar.gz"), "_COM7.tar.gz")

    def test_empty(self):
        self.assertEqual(names.sanitize_component("   "), "_")
        self.assertEqual(names.sanitize_component(""), "_")

    def test_long_name_truncated_with_extension(self):
        long_name = "a" * 300 + ".txt"
        result = names.sanitize_component(long_name)
        self.assertLessEqual(len(result), 255)
        self.assertTrue(result.endswith(".txt"))

    def test_unicode_normalization(self):
        import unicodedata
        nfd = unicodedata.normalize("NFD", "café")
        self.assertEqual(names.sanitize_component(nfd), "café")

    def test_unique_name(self):
        taken = set()
        self.assertEqual(names.unique_name("test.txt", taken), "test.txt")
        self.assertEqual(names.unique_name("test.txt", taken), "test (2).txt")
        self.assertEqual(names.unique_name("TEST.TXT", taken), "TEST (3).TXT")


class TimeTests(unittest.TestCase):
    def test_apfs_nanoseconds(self):
        # 2025-04-17 sekitar
        ns = 1745114176000000000
        self.assertEqual(detect_unix_ns(ns), ns)

    def test_seconds(self):
        secs = 1745114176
        self.assertEqual(detect_unix_ns(secs), secs * 1_000_000_000)

    def test_none(self):
        self.assertIsNone(detect_unix_ns(None))

    def test_zero(self):
        self.assertEqual(detect_unix_ns(0), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)