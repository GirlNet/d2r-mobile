# 解码 Ryujinx 资源记录中的 NVN 组合/分离句柄位置；依据 TextureHandle.cs 与 SDK 绑定命令，不推断资源类型。
# Decode NVN combined/separate handle locations in Ryujinx resource records; based on TextureHandle.cs and SDK binding commands, without inferring resource types.


def slot(offset, base, count):
    delta = offset - base
    return delta // 8 if 0 <= delta < count * 8 and delta % 8 == 0 else None


def decode_handle(handle, banks=-1):
    if type(handle) is not int or not 0 <= handle <= 0x7fffffff or type(banks) is not int or banks < -1:
        raise ValueError('Invalid packed NVN handle or constant-buffer banks')
    texture_bank = 2 if banks == -1 else banks & 0xffff
    sampler_bank = texture_bank if banks == -1 or banks >> 16 == 0 else (banks >> 16) - 1
    offset = (handle & 0x3fff) * 4
    sampler_offset = ((handle >> 14) & 0x3fff) * 4
    kind = handle >> 28
    if texture_bank != 2 or kind not in (0, 1):
        return None
    combined, separate = slot(offset, 0x20, 32), slot(offset, 0x168, 128)
    if combined is not None:
        texture = dict(kind='tex_combined', reg=combined)
        sampler = dict(kind='samp_combined', reg=combined)
    elif separate is not None:
        texture = dict(kind='tex', reg=separate)
        sampler = dict(kind='samp_tex', reg=separate)
    else:
        return None
    if kind == 1:
        sampler_slot = slot(sampler_offset, 0x568, 128)
        if sampler_bank != 2 or sampler_slot is None:
            return None
        sampler = dict(kind='samp', reg=sampler_slot)
    return dict(texture=texture, sampler=sampler)
