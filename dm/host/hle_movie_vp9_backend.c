// Public VideoToolbox VP9 decoding, with owned I420 output for movie::Decoder.
#if defined(DM_P5R_ONLY) || defined(DM_P5R_MOVIE_TEST)
#include "movie_vp9.h"
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct dm_vp9 {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
    dm_vp9_output output;
    void *user;
    int width, height, error;
};
typedef struct { const uint8_t *p; size_t bits, pos; int bad; } bits_t;
static unsigned bits(bits_t *b, unsigned n) {
    if (n > 32 || b->pos + n > b->bits) { b->bad = 1; return 0; }
    unsigned value = 0;
    while (n--) { value = value * 2 + ((b->p[b->pos / 8] >> (7 - b->pos % 8)) & 1); b->pos++; }
    return value;
}
int dm_vp9_keyframe(const void *packet, size_t size, int *width, int *height, int *full_range) {
    if (!packet || size < 10 || size > SIZE_MAX / 8 || !width || !height || !full_range) return -1;
    bits_t b = {packet, size * 8, 0, 0};
    if (bits(&b, 2) != 2) return -1;
    unsigned profile = bits(&b, 1); profile |= bits(&b, 1) << 1;
    if (profile || bits(&b, 1) || bits(&b, 1)) return -1; // profile 0, new keyframe
    bits(&b, 1); bits(&b, 1); // show_frame, error_resilient
    if (bits(&b, 24) != 0x498342 || bits(&b, 3) == 7) return -1;
    int range = (int)bits(&b, 1);
    unsigned w = bits(&b, 16) + 1, h = bits(&b, 16) + 1;
    if (b.bad || !w || !h || w > 8192 || h > 8192) return -1;
    *width = (int)w; *height = (int)h; *full_range = range;
    return 0;
}
static pthread_once_t register_once = PTHREAD_ONCE_INIT;
static void register_vp9(void) { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9); }
static void decoded(void *user, void *source, OSStatus status, VTDecodeInfoFlags flags,
                    CVImageBufferRef image, CMTime pts, CMTime duration) {
    (void)source; (void)duration;
    dm_vp9 *d = user;
    if (status) { d->error = (int)status; return; }
    // VP9 invisible reference frames legitimately produce no displayed image.
    if (!image || (flags & kVTDecodeInfo_FrameDropped)) return;
    OSType type = CVPixelBufferGetPixelFormatType(image);
    if (type != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        type != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { d->error = -2; return; }
    size_t w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image);
    if (!w || !h || w > 8192 || h > 8192 || CVPixelBufferGetPlaneCount(image) != 2) { d->error = -3; return; }
    size_t cw = (w + 1) / 2, ch = (h + 1) / 2, size = w * h + 2 * cw * ch;
    uint8_t *data = malloc(size);
    if (!data) { d->error = -4; return; }
    CVReturn lock = CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    if (lock) { free(data); d->error = (int)lock; return; }
    const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(image, 0);
    const uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(image, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(image, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(image, 1);
    if (!y || !uv || ys < w || uvs < 2 * cw) { d->error = -5; }
    else {
        for (size_t r = 0; r < h; r++) memcpy(data + r * w, y + r * ys, w);
        for (size_t r = 0; r < ch; r++) for (size_t c = 0; c < cw; c++) {
            data[w * h + r * cw + c] = uv[r * uvs + 2 * c];
            data[w * h + cw * ch + r * cw + c] = uv[r * uvs + 2 * c + 1];
        }
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    if (d->error) { free(data); return; }
    dm_vp9_frame frame = {data, size, (int)w, (int)h, CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_Default).value};
    if (!d->output(d->user, &frame)) { free(data); d->error = -6; }
}
dm_vp9 *dm_vp9_create(dm_vp9_output output, void *user) {
    if (!output) return NULL;
    pthread_once(&register_once, register_vp9);
    dm_vp9 *d = calloc(1, sizeof *d);
    if (d) { d->output = output; d->user = user; }
    return d;
}
static int prepare(dm_vp9 *d, const void *packet, size_t size) {
    int w = 0, h = 0, range = 0;
    int key = dm_vp9_keyframe(packet, size, &w, &h, &range) == 0;
    if (d->session && (!key || (w == d->width && h == d->height))) return 0;
    if (!key) return -7;
    if (d->session) { VTDecompressionSessionInvalidate(d->session); CFRelease(d->session); d->session = NULL; }
    if (d->format) { CFRelease(d->format); d->format = NULL; }
    // ISO VPCodecConfigurationBox: version/flags, profile, level, 8-bit 4:2:0,
    // unspecified colour primaries/transfer/matrix, no codec initialization data.
    const uint8_t vpcc[12] = {1,0,0,0,0,0,(uint8_t)(0x80 | range),2,2,2,0,0};
    CFDataRef config = CFDataCreate(NULL, vpcc, sizeof vpcc);
    const void *atom_keys[] = {CFSTR("vpcC")}, *atom_values[] = {config};
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, atom_keys, atom_values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *ext_keys[] = {kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms}, *ext_values[] = {atoms};
    CFDictionaryRef extensions = CFDictionaryCreate(NULL, ext_keys, ext_values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_VP9, w, h, extensions, &d->format);
    CFRelease(extensions); CFRelease(atoms); CFRelease(config);
    if (status) return (int)status;
    int pixel = range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pixel_number = CFNumberCreate(NULL, kCFNumberIntType, &pixel);
    const void *keys[] = {kCVPixelBufferPixelFormatTypeKey}, *values[] = {pixel_number};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord callback = {decoded, d};
    status = VTDecompressionSessionCreate(NULL, d->format, NULL, attributes, &callback, &d->session);
    CFRelease(attributes); CFRelease(pixel_number);
    if (!status) { d->width = w; d->height = h; }
    return (int)status;
}
int dm_vp9_decode(dm_vp9 *d, const void *packet, size_t size, int64_t pts_us) {
    if (!d || !packet || !size || size > 16 * 1024 * 1024) return -8;
    int error = prepare(d, packet, size);
    if (error) return error;
    CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, size, NULL, NULL, 0, size, 0, &block);
    if (!status) status = CMBlockBufferReplaceDataBytes(packet, block, 0, size);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts_us, 1000000), kCMTimeInvalid};
    if (!status) status = CMSampleBufferCreateReady(NULL, block, d->format, 1, 1, &timing, 1, &size, &sample);
    d->error = 0;
    if (!status) status = VTDecompressionSessionDecodeFrame(d->session, sample, 0, NULL, NULL);
    if (!status) status = VTDecompressionSessionWaitForAsynchronousFrames(d->session);
    if (sample) CFRelease(sample);
    if (block) CFRelease(block);
    return status ? (int)status : d->error;
}
void dm_vp9_destroy(dm_vp9 *d) {
    if (!d) return;
    if (d->session) { VTDecompressionSessionWaitForAsynchronousFrames(d->session); VTDecompressionSessionInvalidate(d->session); CFRelease(d->session); }
    if (d->format) CFRelease(d->format);
    free(d);
}
#endif
