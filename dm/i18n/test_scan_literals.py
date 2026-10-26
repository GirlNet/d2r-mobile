# 对旧版与新版 f-string token 测试一致的扫描范围、嵌套、Unicode 位置和文档串排除。
# Test consistent scan coverage for old/new f-string tokens, nesting, Unicode positions and docstring exclusion.
import tokenize
import unittest
from unittest.mock import patch

from scan_literals import strip_py


class PythonLiteralTests(unittest.TestCase):
    def test_fstring_scanned_on_current_python(self):
        source = "label = f'消息 {count}'\n"
        self.assertEqual(strip_py(source)[1], [(8, "f'消息 {count}'")])

    def test_unicode_position_and_docstring(self):
        source = '"""文档"""\n中文变量 = f"消息 {count}"\n'
        expected = source.index('f"')
        self.assertEqual(strip_py(source)[1], [(expected, 'f"消息 {count}"')])

    def test_new_token_stream_with_nested_fstring(self):
        source = 'value = f"外 {f\'内 {x}\'} 文"\n'
        outer = source.index('f"'); inner = source.index("f'")
        end = source.rindex('"') + 1; inner_end = source.index("'", inner + 2) + 1
        def token(kind, start, stop):
            return tokenize.TokenInfo(kind, source[start:stop], (1, start), (1, stop), source)
        tokens = [token(tokenize.NAME, 0, 5), token(tokenize.OP, 6, 7),
                  token(1001, outer, outer + 2), token(1003, outer + 2, inner),
                  token(1001, inner, inner + 2), token(1003, inner + 2, inner_end - 1),
                  token(1002, inner_end - 1, inner_end), token(1003, inner_end, end - 1),
                  token(1002, end - 1, end)]
        with patch.object(tokenize, 'FSTRING_START', 1001, create=True), \
             patch.object(tokenize, 'FSTRING_END', 1002, create=True), \
             patch.object(tokenize, 'generate_tokens', return_value=iter(tokens)):
            self.assertEqual(strip_py(source)[1], [(outer, source[outer:end])])

    def test_multiline_fstring_not_a_docstring(self):
        source = 'label = f"""消息\n{count}\n结束"""\n'
        self.assertEqual(strip_py(source)[1], [(8, source[8:-1])])


if __name__ == '__main__':
    unittest.main()
