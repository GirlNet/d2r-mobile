"""Compile the real HLE macros; duplicate forced names must never reach an IPA."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HOST = Path(__file__).resolve().parents[1] / 'host'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'Requires the native Apple compiler')
class HLERegistrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def compile(self, filename, registrations, main=False):
        source = self.root / (filename + '.c')
        source.write_text('#include "hle.h"\n' + registrations +
                          ('\nint main(void) { return 0; }\n' if main else '\n'))
        return subprocess.run(['clang', '-DDM_P5R_ONLY=1', '-I', str(HOST), '-c',
                               str(source), '-o', str(source.with_suffix('.o'))], capture_output=True, text=True)

    @staticmethod
    def entry(kind, function, name='registry_test'):
        return f'{kind}("{name}", "test", int, {function}, void) {{ return 0; }}\n'

    def link(self):
        return subprocess.run(['clang', '-Wl,-dead_strip', str(self.root/'a.o'), str(self.root/'b.o'),
                               '-o', str(self.root/'host')], capture_output=True, text=True)

    def test_unique_required_optional_and_regular_import_can_link(self):
        a = self.entry('HLE_FORCE', 'first', 'required_test')
        a += 'HLE("required_test", int, import_only, void) { return 0; }\n'
        self.assertEqual(self.compile('a', a, main=True).returncode, 0)
        self.assertEqual(self.compile('b', self.entry('HLE_FORCE_OPTIONAL', 'second', 'optional_test')).returncode, 0)
        result = self.link()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_same_file_required_optional_duplicate_fails_compilation(self):
        result = self.compile('a', self.entry('HLE_FORCE', 'first') + self.entry('HLE_FORCE_OPTIONAL', 'second'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dm_force_unique_registry_test', result.stderr)

    def test_cross_file_duplicates_fail_link_even_with_dead_strip(self):
        for left in ('HLE_FORCE', 'HLE_FORCE_OPTIONAL'):
            for right in ('HLE_FORCE', 'HLE_FORCE_OPTIONAL'):
                with self.subTest(left=left, right=right):
                    a = self.compile('a', self.entry(left, 'first'), main=True)
                    b = self.compile('b', self.entry(right, 'second'))
                    self.assertEqual(a.returncode, 0, a.stderr)
                    self.assertEqual(b.returncode, 0, b.stderr)
                    result = self.link()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('dm_force_unique_registry_test', result.stderr)


if __name__ == '__main__':
    unittest.main()
