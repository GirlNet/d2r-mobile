#pragma once
#include <stddef.h>
#include <stdint.h>
// Specialize float-register texture loads for integer sampling views. The
// argument IDs select uint (1) or sint (2); zero keeps the original declaration.
// Loads return the original register bits, without a numeric conversion.
// Only direct loads and dimension queries in flat SPIRV-Cross MSL are accepted.
// The caller frees *output. Ambiguous declarations and other uses fail closed.
int nvn_texture_bits_source(const char *source,const uint8_t kinds[64],char **output,
                            uint64_t *applied,char *error,size_t error_size);
