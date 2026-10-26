"""玩家二进制的诊断符号验收规则，不需要 Apple 编译器。
Player-binary diagnostic symbol checks, without an Apple compiler.
"""
import unittest
from build_shell import retained_diagnostics
class PlayerBuildPolicyTests(unittest.TestCase):
    def test_functional_sampler_tables_are_allowed(self):
        self.assertEqual(retained_diagnostics('00001 b _g_sreg\n00002 b _g_sreg_ok\n00003 b _g_srid\n00004 T _mtl_sub_commit'),[])
    def test_exact_counters_and_probe_namespaces_are_rejected(self):
        symbols='00001 b _g_sr\n00002 T _nvn_prof_entry\n00003 b _g_compute_probe_mode\n00004 b _g_pg4_enabled\n00005 b _g_draw_sites_n'
        self.assertEqual(retained_diagnostics(symbols),['_g_compute_probe_','_g_pg4_','_nvn_prof_entry','_g_sr','_g_draw_sites_n'])
if __name__=='__main__':unittest.main()
