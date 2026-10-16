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
    assert set(implementations) <= set(names), "Implementation lacks a static thunk"
    batch = re.findall(r"NVN\((nvn\w+),", sources[1].read_text(encoding="utf-8"))
    tests = (root / "dm/gfx/tests/t_startup_batch.inc").read_text(encoding="utf-8")
    assert set(batch) <= set(re.findall(r"P\((nvn\w+)\)", tests)), "Batch interface lacks a direct typed regression call"
    return dict(schema_version=1, registered=len(names), host_implemented=len(implementations),
                named_unimplemented=len(set(names)-set(implementations)), batch_implemented=len(batch),
                game_graphics_verified=False, runtime_ready=False,
                scope="Source registration and direct regression-call coverage only; not ABI/GPU equivalence proof",
                unimplemented=[n for n in names if n not in implementations])

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
