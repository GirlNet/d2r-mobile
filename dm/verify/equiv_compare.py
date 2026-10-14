# 等价试验的内存写入比较：只去掉补丁暂存区及已登记线程槽的额外写入，不隐藏客体写入。
# Memory-write comparison for equivalence trials: remove only extra patch scratch and registered thread-slot writes, never hide guest writes.


def visible_patch_writes(patched, original, stack_pointer, slots):
    original_addresses = {write[0] for write in original}
    return [write for write in patched if not
            ((stack_pointer - 128 <= write[0] < stack_pointer or write[0] in slots)
             and write[0] not in original_addresses)]
