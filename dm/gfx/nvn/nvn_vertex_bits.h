#pragma once
#include <stddef.h>
#include <stdint.h>
// Specialize diagnostic float inputs to the actual NVN integer fetch classes.
// kinds[location]: 0=float/normalized, 1=unsigned integer, 2=signed integer.
// Keep the translated body unchanged and bitcast raw integer values into its
// float register representation. Only the inspected flat SPIRV-Cross grammar
// is accepted. Caller frees *output; no input is modified on failure.
int nvn_vertex_bits_source(const char *source,const uint8_t kinds[16],char **output,
                           uint32_t *applied,char *error,size_t error_size);
// Metal requires a void-returning vertex entry when rasterization is disabled.
// Retain the body (including memory side effects), discard identifier exports.
int nvn_vertex_discard_source(const char *source,char **output,char *error,size_t error_size);
