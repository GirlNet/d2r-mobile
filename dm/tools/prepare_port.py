#!/usr/bin/env python3
# 对本机 ExeFS 运行只读检查、通用 NSO 改写与可选等价验证，供新游戏移植前期使用；不生成可玩的安装包。
# Run local ExeFS inspection, generic NSO rewriting and optional equivalence checks for early game-port work; does not produce a playable app.
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from lz4.block import LZ4BlockError
from inspect_exefs import inspect_exefs


def main():
    parser = argparse.ArgumentParser(description="Prepare experimental Switch module rewrites, without building an iOS app.")
    parser.add_argument("exefs", type=Path)
    parser.add_argument("workspace", type=Path, help="Output directory outside the repository and source ExeFS")
    parser.add_argument("--verify", action="store_true", help="Run Unicorn per-site equivalence checks; excludes native host gates")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    source, workspace = args.exefs.resolve(), args.workspace.resolve()
    if workspace.is_relative_to(repo) or workspace.is_relative_to(source):
        parser.error("Workspace must be outside the repository and source ExeFS")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    manifest = dict(status="incomplete", runnable_verified=False, host_gates_verified=False, stages=[])
    try:
        inventory = inspect_exefs(source, repo)
        workspace.mkdir(parents=True, exist_ok=True)
        (workspace / "exefs-inspection.json").write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        manifest["inputs"] = {module["name"]: module["file_sha256"] for module in inventory["modules"]}
        rewriter = repo / "dm" / "tools" / "patch_nso.py"
        manifest["rewriter_sha256"] = hashlib.sha256(rewriter.read_bytes()).hexdigest()
        rewritten = workspace / "rewritten"
        rewritten.mkdir(exist_ok=True)
        env = os.environ.copy()
        env.update(DM_RULESET="native", DM_PRIVATE_GATES="0", PYTHONUTF8="1")
        names = [module["name"] for module in inventory["modules"] if module["name"] != "rtld"]
        for name in names:
            if not (name == "main" or name == "sdk" or name.startswith("subsdk") and name[6:].isdigit()):
                raise ValueError(f"Unexpected NSO module name: {name}")
        for name in names:
            log = workspace / f"rewrite-{name}.log"
            with log.open("w", encoding="utf-8") as stream:
                result = subprocess.run([sys.executable, "-X", "utf8", str(rewriter), str(source / name),
                                         str(rewritten), name], env=env, stdout=stream, stderr=subprocess.STDOUT)
            manifest["stages"].append(dict(stage="rewrite", module=name, exit_code=result.returncode, log=log.name))
            print(f"rewrite {name}: {'OK' if result.returncode == 0 else 'FAIL'} ({log})", flush=True)
            if result.returncode:
                raise ValueError(f"Rewriting failed for {name}; see {log}")
        manifest["outputs"] = {name: hashlib.sha256((rewritten / f"{name}.patched.bin").read_bytes()).hexdigest() for name in names}
        if args.verify:
            checker = repo / "dm" / "verify" / "equiv.py"
            manifest["equivalence_checker_sha256"] = hashlib.sha256(checker.read_bytes()).hexdigest()
            for name in names:
                log = workspace / f"equiv-{name}.log"
                with log.open("w", encoding="utf-8") as stream:
                    result = subprocess.run([sys.executable, "-X", "utf8", str(checker), str(rewritten), name,
                                             str(source / name), "--jobs", str(args.jobs), "--tsv",
                                             str(workspace / f"equiv-{name}.tsv")], env=env,
                                            stdout=stream, stderr=subprocess.STDOUT)
                manifest["stages"].append(dict(stage="equivalence", module=name, exit_code=result.returncode, log=log.name))
                print(f"equivalence {name}: {'OK' if result.returncode == 0 else 'FAIL'} ({log})", flush=True)
                if result.returncode:
                    raise ValueError(f"Equivalence check failed for {name}; see {log}")
        manifest["status"] = "equivalence_passed" if args.verify else "rewritten_unverified"
        print("Preparation finished. iOS runtime, graphics, audio and native host gates remain UNVERIFIED.")
        return 0
    except (ValueError, OSError, LZ4BlockError) as error:
        manifest["error"] = str(error)
        print(f"Preparation failed: {error}", file=sys.stderr)
        return 1
    finally:
        if workspace.is_dir():
            (workspace / "port-preparation.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
