# 用人工构造的 NSO 验证检查器的边界、散列和模块依赖；不包含任何游戏内容。
# Verify inspector bounds, hashes and module dependencies with synthetic NSOs; contains no game content.
import hashlib
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

import lz4.block

from inspect_exefs import inspect_exefs, inspect_module


def fixture(name="__inspection_test_symbol__", defined=False, weak=False, compressed=False):
    strings = b"\0" + name.encode() + b"\0"
    rodata = bytearray(256)
    rodata[:len(strings)] = strings
    struct.pack_into("<IBBHQQ", rodata, 64 + 24, 1, (2 if weak else 1) << 4, 0, int(defined), 0, 0)
    sections = [bytes(16), bytes(rodata), bytes(16)]
    header = bytearray(256)
    header[:4] = b"NSO0"
    struct.pack_into("<I", header, 12, 0x3F if compressed else 0x38)
    struct.pack_into("<IIII", header, 0x90, 0, len(strings), 64, 48)
    output = bytearray()
    for i, section in enumerate(sections):
        stored = lz4.block.compress(section, store_size=False) if compressed else section
        struct.pack_into("<III", header, 0x10 + i * 16, len(header) + len(output), i * 0x1000, len(section))
        struct.pack_into("<I", header, 0x60 + i * 4, len(stored))
        header[0xA0 + i * 32:0xC0 + i * 32] = hashlib.sha256(section).digest()
        output.extend(stored)
    return bytes(header + output)


class InspectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "main"
        self.path.write_bytes(fixture())
        self.repo = Path(__file__).resolve().parents[2]

    def test_hashes_and_imports(self):
        result = inspect_module(self.path)
        self.assertTrue(all(segment["hash_checked"] for segment in result["segments"]))
        self.assertEqual(result["imports"], [{"name": "__inspection_test_symbol__", "weak": False}])

    def test_lz4_segments(self):
        self.path.write_bytes(fixture(compressed=True))
        result = inspect_module(self.path)
        self.assertTrue(all(segment["compressed"] for segment in result["segments"]))
        self.assertEqual(result["imports"][0]["name"], "__inspection_test_symbol__")

    def test_corrupt_hash(self):
        blob = bytearray(fixture())
        blob[-1] ^= 1
        self.path.write_bytes(blob)
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            inspect_module(self.path)

    def test_truncated_file(self):
        self.path.write_bytes(fixture()[:-1])
        with self.assertRaisesRegex(ValueError, "range outside"):
            inspect_module(self.path)

    def test_symbol_table_out_of_range(self):
        blob = bytearray(fixture())
        struct.pack_into("<I", blob, 0x98, 250)
        self.path.write_bytes(blob)
        with self.assertRaisesRegex(ValueError, "dynamic symbols"):
            inspect_module(self.path)

    def test_overlapping_memory(self):
        blob = bytearray(fixture())
        struct.pack_into("<I", blob, 0x24, 0)
        self.path.write_bytes(blob)
        with self.assertRaisesRegex(ValueError, "overlapping memory"):
            inspect_module(self.path)

    def test_invalid_symbol_name(self):
        blob = bytearray(fixture())
        ro_offset = struct.unpack_from("<I", blob, 0x20)[0]
        struct.pack_into("<I", blob, ro_offset + 88, 0xFFFF)
        blob[0xC0:0xE0] = hashlib.sha256(blob[ro_offset:ro_offset + 256]).digest()
        self.path.write_bytes(blob)
        with self.assertRaisesRegex(ValueError, "symbol string offset"):
            inspect_module(self.path)

    def test_missing_dependency_and_cross_module_export(self):
        result = inspect_exefs(self.root, self.repo)
        self.assertEqual(result["unresolved_strong_imports"], ["__inspection_test_symbol__"])
        (self.root / "sdk").write_bytes(fixture(defined=True))
        result = inspect_exefs(self.root, self.repo)
        self.assertEqual(result["unresolved_strong_imports"], [])
        self.assertFalse(result["runnable_verified"])

    def test_rtld_does_not_resolve_dependency(self):
        (self.root / "rtld").write_bytes(fixture(defined=True))
        result = inspect_exefs(self.root, self.repo)
        self.assertEqual(result["unresolved_strong_imports"], ["__inspection_test_symbol__"])

    def test_weak_import_is_not_required(self):
        self.path.write_bytes(fixture(weak=True))
        self.assertEqual(inspect_exefs(self.root, self.repo)["unresolved_strong_imports"], [])

    def test_refuse_input_overwrite(self):
        before = self.path.read_bytes()
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("inspect_exefs.py")),
                                 str(self.root), "--output", str(self.path)], capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"must not overwrite", result.stderr)
        self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_main_is_not_skipped(self):
        self.path.write_bytes(b"not a Switch program")
        with self.assertRaisesRegex(ValueError, "main file is not an NSO0"):
            inspect_exefs(self.root, self.repo)

    def test_prepare_refuses_source_directory_as_workspace(self):
        before = self.path.read_bytes()
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("prepare_port.py")),
                                 str(self.root), str(self.root)], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse((self.root / "port-preparation.json").exists())


if __name__ == "__main__":
    unittest.main()
