#!/usr/bin/env python3
# 只读检查 Switch ExeFS：依据 NSO 头中的段、散列与 ELF64 动态符号描述，不执行或修改游戏。
# Read-only Switch ExeFS inspection based on NSO segment/hash headers and ELF64 dynamic symbols; never executes or modifies a game.
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

import lz4.block


def span(data, offset, size, label):
    if offset < 0 or size < 0 or offset + size > len(data):
        raise ValueError(f"{label}: range outside file/segment")
    return data[offset:offset + size]


def inspect_module(path):
    raw = path.read_bytes()
    if len(raw) < 0x100 or raw[:4] != b"NSO0":
        raise ValueError(f"{path.name}: expected an extracted NSO0 module")
    flags = struct.unpack_from("<I", raw, 12)[0]
    if flags & 0x80:
        raise ValueError(f"{path.name}: Zbic compression is unsupported by this inspector")
    segments, decoded = [], []
    for i, name in enumerate(("text", "rodata", "data")):
        file_offset, memory_offset, size = struct.unpack_from("<III", raw, 0x10 + i * 16)
        compressed = bool(flags & (1 << i))
        stored_size = struct.unpack_from("<I", raw, 0x60 + i * 4)[0] if compressed else size
        if size > 512 * 1024 * 1024:
            raise ValueError(f"{path.name}: {name} exceeds the 512 MiB inspection limit")
        if size and file_offset < 0x100:
            raise ValueError(f"{path.name}: {name} overlaps the NSO header")
        blob = span(raw, file_offset, stored_size, name)
        if compressed:
            blob = lz4.block.decompress(blob, uncompressed_size=size)
        if len(blob) != size:
            raise ValueError(f"{path.name}: {name} decoded size mismatch")
        digest = hashlib.sha256(blob).digest()
        checked = bool(flags & (1 << (i + 3)))
        if checked and digest != raw[0xA0 + i * 32:0xC0 + i * 32]:
            raise ValueError(f"{path.name}: {name} SHA-256 mismatch")
        for previous in segments:
            lo, hi = previous["memory_offset"], previous["memory_offset"] + previous["size"]
            if size and previous["size"] and memory_offset < hi and memory_offset + size > lo:
                raise ValueError(f"{path.name}: overlapping memory segments")
            lo, hi = previous["file_offset"], previous["file_offset"] + previous["stored_size"]
            if stored_size and previous["stored_size"] and file_offset < hi and file_offset + stored_size > lo:
                raise ValueError(f"{path.name}: overlapping file segments")
        decoded.append(blob)
        segments.append(dict(name=name, file_offset=file_offset, memory_offset=memory_offset,
                             size=size, stored_size=stored_size, compressed=compressed,
                             hash_checked=checked, sha256=digest.hex()))
    string_offset, string_size, symbol_offset, symbol_size = struct.unpack_from("<IIII", raw, 0x90)
    if not string_size or not symbol_size:
        raise ValueError(f"{path.name}: NSO dynamic symbol/string table descriptors are missing")
    strings = span(decoded[1], string_offset, string_size, "dynamic strings")
    symbols = span(decoded[1], symbol_offset, symbol_size, "dynamic symbols")
    if len(symbols) % 24:
        raise ValueError(f"{path.name}: dynamic symbol table is not ELF64-sized")
    imports, exports = [], []
    for offset in range(24, len(symbols), 24):
        name_offset, info, other, section, value, size = struct.unpack_from("<IBBHQQ", symbols, offset)
        if not name_offset:
            continue
        if name_offset >= len(strings):
            raise ValueError(f"{path.name}: invalid symbol string offset")
        end = strings.find(b"\0", name_offset)
        if end < 0:
            raise ValueError(f"{path.name}: unterminated symbol name")
        name = strings[name_offset:end].decode("utf-8", errors="strict")
        if section == 0:
            imports.append(dict(name=name, weak=info >> 4 == 2))
        elif info >> 4 in (1, 2) and other & 3 in (0, 3):
            exports.append(name)
    return dict(name=path.name, build_id=raw[0x40:0x60].hex(),
                file_sha256=hashlib.sha256(raw).hexdigest(), file_size=len(raw),
                bss_size=struct.unpack_from("<I", raw, 0x3C)[0], segments=segments,
                imports=imports, exports=sorted(set(exports)))


def declared_host_symbols(repo):
    # 这是源码声明扫描，含条件编译及占位实现，不等同于链接成功或接口实现完整。
    # This source declaration scan includes conditional code and stubs; it does not prove successful linking or complete implementations.
    names = set()
    sources = list((repo / "dm" / "host").glob("*.c")) + list((repo / "dm" / "gfx" / "nvn").glob("*.c"))
    for path in sources:
        source = path.read_text(encoding="utf-8")
        source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
        names.update(re.findall(r'\bHLE(?:_FORCE(?:_OPTIONAL)?|_WEAK)?\(\s*"([^"\n]+)"', source))
        if path.name == "hle_table.c":
            names.update(set(re.findall(r"\bL\((\w+)\)", source)) - {"n"})
    return names


def inspect_exefs(directory, repo):
    if not directory.is_dir() or not (directory / "main").is_file():
        raise ValueError("ExeFS must be a directory containing the extracted main module")
    paths = []
    for path in sorted(directory.iterdir()):
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) == b"NSO0":
                    paths.append(path)
    modules = [inspect_module(path) for path in paths]
    if not any(module["name"] == "main" for module in modules):
        raise ValueError("The extracted main file is not an NSO0 module")
    # 原 rtld 被宿主装载器替代，不能拿它的导出冒充待装模块的依赖提供者。
    # The original rtld is replaced by the host loader; its exports cannot stand in for dependencies of loaded guest modules.
    definitions = {name for module in modules if module["name"] != "rtld" for name in module["exports"]}
    declared = declared_host_symbols(repo)
    for module in modules:
        for item in module["imports"]:
            name = item["name"]
            item["provider_candidate"] = ("host_declaration" if name in declared else
                                          "guest_module" if name in definitions else "unresolved")
    unresolved = sorted({item["name"] for module in modules if module["name"] != "rtld"
                         for item in module["imports"] if not item["weak"] and item["provider_candidate"] == "unresolved"})
    return dict(schema_version=1, status="inspection_only", runnable_verified=False,
                caveat="Static declarations and guest exports are candidates, not runtime compatibility evidence.",
                modules=modules, unresolved_strong_imports=unresolved)


def main():
    parser = argparse.ArgumentParser(description="Inspect local extracted Switch modules; this does not build or launch a game.")
    parser.add_argument("exefs", type=Path)
    parser.add_argument("--output", type=Path, help="Write a local JSON report; game bytes are never included")
    args = parser.parse_args()
    try:
        result = inspect_exefs(args.exefs, Path(__file__).resolve().parents[2])
        report = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            destination = args.output.resolve()
            for source in args.exefs.iterdir():
                if source.is_file() and (destination == source.resolve() or
                                         destination.exists() and destination.samefile(source)):
                    raise ValueError("The output must not overwrite an ExeFS input file")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(report, encoding="utf-8")
            for module in result["modules"]:
                print(f'{module["name"]}: {module["build_id"]}, {len(module["imports"])} imports, {len(module["exports"])} exports')
            print(f'Unresolved strong imports: {len(result["unresolved_strong_imports"])}; runnable: NOT VERIFIED')
        else:
            print(report, end="")
        return 0
    except (ValueError, OSError, lz4.block.LZ4BlockError) as error:
        print(f"Inspection failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
