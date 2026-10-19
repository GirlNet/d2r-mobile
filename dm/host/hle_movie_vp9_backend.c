// Public VideoToolbox VP9 decoding, with owned I420 output for movie::Decoder.
#if defined(DM_P5R_ONLY) || defined(DM_P5R_MOVIE_TEST)
#include "movie_vp9.h"
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <vpx/vp8dx.h>
#include <vpx/vpx_decoder.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct dm_vp9 {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
    dm_vp9_output output;
    void *user;
    int width, height, error;
    int software, software_initialized;
    unsigned output_frames;
    vpx_codec_ctx_t cpu;
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
    else d->output_frames++;
}
dm_vp9 *dm_vp9_create(dm_vp9_output output, void *user) {
    if (!output) return NULL;
    pthread_once(&register_once, register_vp9);
    dm_vp9 *d = calloc(1, sizeof *d);
    if (d) { d->output = output; d->user = user; }
    return d;
}
dm_vp9 *dm_vp9_create_software(dm_vp9_output output, void *user) {
    dm_vp9 *d = dm_vp9_create(output, user);
    if (d) d->software = 1;
    return d;
}
const char *dm_vp9_backend(dm_vp9 *d) { return d && d->software ? "libvpx software" : "VideoToolbox"; }
static int software_frame(dm_vp9 *d, const uint8_t *packet, size_t size, int64_t pts_us) {
    if (!d->software_initialized) {
        vpx_codec_dec_cfg_t config = {4, 0, 0};
        vpx_codec_err_t error = vpx_codec_dec_init(&d->cpu, vpx_codec_vp9_dx(), &config, 0);
        if (error) return -(20000 + (int)error);
        d->software_initialized = 1;
        fprintf(stderr,"P5R VP9: libvpx software decoder initialized\n");
    }
    vpx_codec_err_t error = vpx_codec_decode(&d->cpu, packet, (unsigned)size, NULL, 0);
    if (error) { fprintf(stderr,"P5R VP9 software decode failed: %s\n",vpx_codec_error(&d->cpu)); return -(20000 + (int)error); }
    vpx_codec_iter_t iterator = NULL; vpx_image_t *image;
    while ((image = vpx_codec_get_frame(&d->cpu, &iterator))) {
        if (image->fmt != VPX_IMG_FMT_I420 || image->bit_depth != 8 ||
            !image->d_w || !image->d_h || image->d_w > 8192 || image->d_h > 8192) return -20020;
        size_t width = image->d_w, height = image->d_h, cw = (width + 1) / 2, ch = (height + 1) / 2;
        size_t frame_size = width * height + 2 * cw * ch;
        uint8_t *data = malloc(frame_size); if (!data) return -4;
        size_t offset = 0;
        for (int plane = 0; plane < 3; plane++) {
            size_t w = plane ? cw : width, h = plane ? ch : height;
            if (!image->planes[plane] || image->stride[plane] < (int)w) { free(data); return -20021; }
            for (size_t row = 0; row < h; row++) memcpy(data + offset + row * w, image->planes[plane] + row * image->stride[plane], w);
            offset += w * h;
        }
        dm_vp9_frame frame = {data, frame_size, (int)width, (int)height, pts_us};
        if (!d->output(d->user, &frame)) { free(data); return -6; }
        d->output_frames++;
    }
    return 0;
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
    unsigned area = (unsigned)w * (unsigned)h;
    uint8_t level = area <= 2228224 ? 41 : area <= 8912896 ? 51 : 62;
    const uint8_t vpcc[12] = {1,0,0,0,0,level,(uint8_t)(0x80 | range),2,2,2,0,0};
    CFDataRef config = CFDataCreate(NULL, vpcc, sizeof vpcc);
    const void *atom_keys[] = {CFSTR("vpcC")}, *atom_values[] = {config};
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, atom_keys, atom_values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *ext_keys[] = {kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms}, *ext_values[] = {atoms};
    CFDictionaryRef extensions = CFDictionaryCreate(NULL, ext_keys, ext_values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_VP9, w, h, extensions, &d->format);
    CFRelease(extensions); CFRelease(atoms); CFRelease(config);
    if (status) { fprintf(stderr,"P5R VP9 format description failed: %d (%dx%d)\n",(int)status,w,h); return (int)status; }
    int pixel = range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pixel_number = CFNumberCreate(NULL, kCFNumberIntType, &pixel);
    const void *keys[] = {kCVPixelBufferPixelFormatTypeKey}, *values[] = {pixel_number};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord callback = {decoded, d};
    status = VTDecompressionSessionCreate(NULL, d->format, NULL, attributes, &callback, &d->session);
    CFRelease(attributes); CFRelease(pixel_number);
    if (!status) { d->width = w; d->height = h; }
    else fprintf(stderr,"P5R VP9 session creation failed: %d (%dx%d)\n",(int)status,w,h);
    return (int)status;
}
static int decode_frame(dm_vp9 *d, const void *packet, size_t size, int64_t pts_us) {
    int error = prepare(d, packet, size);
    if (error) return error;
    CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, size, NULL, NULL, 0, size, 0, &block);
    if (!status) status = CMBlockBufferReplaceDataBytes(packet, block, 0, size);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts_us, 1000000), kCMTimeInvalid};
    if (!status) status = CMSampleBufferCreateReady(NULL, block, d->format, 1, 1, &timing, 1, &size, &sample);
    d->error = 0;
    if (!status) {
        status = VTDecompressionSessionDecodeFrame(d->session, sample, 0, NULL, NULL);
        if (status) fprintf(stderr,"P5R VP9 frame submission failed: %d (%zu bytes)\n",(int)status,size);
    }
    if (!status) status = VTDecompressionSessionWaitForAsynchronousFrames(d->session);
    if (sample) CFRelease(sample);
    if (block) CFRelease(block);
    return status ? (int)status : d->error;
}
static int decode_with_fallback(dm_vp9 *d, const uint8_t *packet, size_t size, int64_t pts_us) {
    if (d->software) return software_frame(d, packet, size, pts_us);
    int error = decode_frame(d, packet, size, pts_us);
    if (error && !d->output_frames) {
        // Before the first image, both decoders can start from the same keyframe.
        // Never retry an interframe with an empty software reference history.
        int w, h, range;
        if (dm_vp9_keyframe(packet, size, &w, &h, &range)) return error;
        fprintf(stderr,"P5R VP9: native decoder unavailable (%d); decoding actual packets in software\n",error);
        if (d->session) { VTDecompressionSessionInvalidate(d->session); CFRelease(d->session); d->session = NULL; }
        if (d->format) { CFRelease(d->format); d->format = NULL; }
        d->software = 1; d->error = 0;
        return software_frame(d, packet, size, pts_us);
    }
    return error;
}
int dm_vp9_decode(dm_vp9 *d, const void *packet, size_t size, int64_t pts_us) {
    if (!d || !packet || !size || size > 16 * 1024 * 1024) return -8;
    const uint8_t *data = packet;
    unsigned marker = data[size - 1];
    if ((marker & 0xe0) != 0xc0) return decode_with_fallback(d, packet, size, pts_us);
    // VP9 packets may contain up to eight reference/display frames. The
    // appended index describes individual compressed frames, not image rows.
    unsigned frames = (marker & 7) + 1, magnitude = ((marker >> 3) & 3) + 1;
    size_t index_size = 2 + frames * magnitude;
    if (size < index_size || data[size - index_size] != marker) return -9;
    size_t lengths[8], cursor = size - index_size + 1, total = 0;
    for (unsigned i = 0; i < frames; i++) {
        size_t length = 0;
        for (unsigned b = 0; b < magnitude; b++) length |= (size_t)data[cursor++] << (8 * b);
        if (!length || length > size - index_size - total) return -9;
        lengths[i] = length; total += length;
    }
    if (total != size - index_size) return -9;
    size_t offset = 0;
    for (unsigned i = 0; i < frames; i++) {
        int error = decode_with_fallback(d, data + offset, lengths[i], pts_us);
        if (error) return error;
        offset += lengths[i];
    }
    return 0;
}
void dm_vp9_destroy(dm_vp9 *d) {
    if (!d) return;
    if (d->session) { VTDecompressionSessionWaitForAsynchronousFrames(d->session); VTDecompressionSessionInvalidate(d->session); CFRelease(d->session); }
    if (d->format) CFRelease(d->format);
    if (d->software_initialized) vpx_codec_destroy(&d->cpu);
    free(d);
}
#endif
