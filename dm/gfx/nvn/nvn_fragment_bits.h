#pragma once
#include <stddef.h>
#include <stdint.h>
// Match diagnostic float exports to the bound render target, without numerical
// conversion of guest register bits. kinds[color]: 0=float, 1=uint, 2=sint.
// Only flat SPIRV-Cross output structs and identifier returns are supported.
// Caller frees *output. Invalid/ambiguous source fails closed.
int nvn_fragment_bits_source(const char *source,const uint8_t kinds[8],char **output,
                             uint16_t *applied,char *error,size_t error_size);
