#ifndef NVN_COPY_LAYOUT_H
#define NVN_COPY_LAYOUT_H
#include <stddef.h>
#include <stdint.h>

// Buffer/texture copies carry independent row and image pitches. Validate
// before resolving a pool address or encoding any GPU access.
static inline int nvn_copy_layout(int width, int height, int depth, int bw, int bh, int bpb,
                                  int64_t row_stride, int64_t image_stride,
                                  size_t *row, size_t *image, size_t *size) {
    if (width <= 0 || height <= 0 || depth < 0 || bw <= 0 || bh <= 0 || bpb <= 0
            || row_stride < 0 || image_stride < 0) return 0;
    size_t blocks = ((size_t)width + bw - 1) / bw, rows = ((size_t)height + bh - 1) / bh;
    if (blocks > SIZE_MAX / (size_t)bpb) return 0;
    size_t tight = blocks * bpb, pitch = row_stride ? (size_t)row_stride : tight;
    if (pitch < tight || pitch > SIZE_MAX / rows) return 0;
    size_t minimum = pitch * rows, slice = image_stride ? (size_t)image_stride : minimum;
    size_t layers = depth ? (size_t)depth : 1;
    if (slice < minimum || slice > SIZE_MAX / layers) return 0;
    *row = pitch; *image = slice; *size = slice * layers;
    return 1;
}
#endif
