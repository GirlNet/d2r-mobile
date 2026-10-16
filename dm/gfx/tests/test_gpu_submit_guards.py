# 检查生产 NVN 后端的所有命令提交都有诊断门，驻留集元数据提交单独排除。
# Check that every production NVN command commit has a diagnostic gate, excluding residency metadata commits.
from pathlib import Path
import re
import unittest

class SubmissionGuards(unittest.TestCase):
    def test_no_unguarded_backend_commits(self):
        source = (Path(__file__).resolve().parents[1] / "nvn/nvn_mtl.m").read_text(encoding="utf-8")
        count = 0
        for match in re.finditer(r"\[[^\[\]\n]*\bcommit(?::[^\]\n]*)?\]", source):
            if match.group() == "[g_res commit]":
                continue
            count += 1
            self.assertTrue(source[:match.start()].endswith("DM_GPU_SUBMIT("), match.group())
        self.assertEqual(count, 19)

if __name__ == "__main__":
    unittest.main()
