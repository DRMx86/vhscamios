#ifndef NTSC_IOS_H
#define NTSC_IOS_H
#include <stdint.h>

typedef struct NtscHandle NtscHandle;

/// Field order and types must match `NtscParams` in NtscCore/src/lib.rs.
typedef struct {
    int32_t vhs_on;        // 1 = run the ntsc-rs VHS effect
    int32_t tape_speed;    // 0 = SP, 1 = LP, 2 = EP
    int32_t filter_type;   // 0 = Butterworth (sharper), 1 = Constant-K (blurrier)
    int32_t snow_on;       // 1 = snow enabled
    float grain;           // 0...1
    float color;           // 0...2 (0 = black & white, 1 = natural)
    float tracking;        // 0...1 (distortion)
    float softness;        // 0...1
    float composite_noise; // composite signal noise intensity
    float snow;            // snow intensity (used when snow_on)
    float vignette;        // 0...1
    float tint_r, tint_g, tint_b;
    float contrast;        // 1 = unchanged
    float film_grain;      // 0...1 (RGB grain, independent of the VHS effect)
} NtscParams;

NtscHandle *ntsc_create(void);
void ntsc_destroy(NtscHandle *handle);

void ntsc_set_params(NtscHandle *handle, const NtscParams *params);

/// Applies the effect in place to a BGRA8 frame. Returns 0 on success.
int32_t ntsc_process_bgra(NtscHandle *handle, uint8_t *pixels, uint32_t width,
                          uint32_t height, uint32_t row_bytes, uint64_t frame_num);
#endif
