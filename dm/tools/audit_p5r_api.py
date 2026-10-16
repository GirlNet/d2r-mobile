# 审计登记的 NVN 接口是否有宿主实现；只读源码，不把存在实现等同于 GPU 已验证。
# Audit registered NVN APIs for host implementations from source only; implementation presence does not imply GPU verification.
import argparse
import json
import re
from pathlib import Path

def audit(root):
    nvn = root / "dm/gfx/nvn"
    names = (nvn / "names.txt").read_text(encoding="utf-8").split()
    sources = [(nvn / "hle_nvn.c"), (nvn / "nvn_startup_batch.inc")]
    implementations = []
    for path in sources:
        implementations += re.findall(r"NVN(?:_NOPROTO)?\((nvn\w+),", path.read_text(encoding="utf-8"))
    assert len(names) == len(set(names)), "Duplicate registered names"
    assert len(implementations) == len(set(implementations)), "Duplicate implementations"
    capture_source = (nvn / "nvn_probe_commands.inc").read_text(encoding="utf-8")
    captures = re.findall(r"NVN_CAPTURE\((nvn\w+),", capture_source)
    assert len(captures) == len(set(captures)) and not set(captures) & set(implementations), "Duplicate capture registrations"
    registered = set(implementations) | set(captures)
    assert registered <= set(names), "Implementation lacks a static thunk"
    batch = re.findall(r"NVN\((nvn\w+),", sources[1].read_text(encoding="utf-8"))
    tests = (root / "dm/gfx/tests/t_startup_batch.inc").read_text(encoding="utf-8")
    capture_tests = (root / "dm/gfx/tests/t_probe_command_capture.inc").read_text(encoding="utf-8")
    assert set(captures) <= set(re.findall(r"P\((nvn\w+)\)", capture_tests)), "Capture interface lacks a typed regression call"
    assert set(batch) <= set(re.findall(r"P\((nvn\w+)\)", tests)), "Batch interface lacks a direct typed regression call"
    return dict(schema_version=1, registered=len(names), host_implemented=len(implementations),
                named_unimplemented=len(set(names)-registered), batch_implemented=len(batch),
                diagnostic_only_capture=len(captures), capture_requires_active_pre_submit_probe=True,
                game_graphics_verified=False, runtime_ready=False,
                scope="Source registration and direct regression-call coverage only; not ABI/GPU equivalence proof",
                unimplemented=[n for n in names if n not in registered], diagnostic_only_interfaces=captures)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = audit(Path(__file__).resolve().parents[2])
    output = json.dumps(result, indent=2)+"\n"
    if args.output:
        args.output.write_text(output, encoding="utf-8")
    else:
        print(output, end="")
