// P5R's compressed VP9 packets are decoded on the host, never skipped.
#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct dm_vp9 dm_vp9;
typedef struct {
    uint8_t *data; // owned, tightly packed 8-bit I420: Y, U, V
    size_t size;
    int width, height;
    int64_t pts_us;
} dm_vp9_frame;
typedef int (*dm_vp9_output)(void *user, dm_vp9_frame *frame);
dm_vp9 *dm_vp9_create(dm_vp9_output output, void *user);
int dm_vp9_decode(dm_vp9 *decoder, const void *packet, size_t size, int64_t pts_us);
void dm_vp9_destroy(dm_vp9 *decoder);
// Validate the first keyframe before creating a format description.
int dm_vp9_keyframe(const void *packet, size_t size, int *width, int *height, int *full_range);
