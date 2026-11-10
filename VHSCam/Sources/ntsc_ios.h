#ifndef NTSC_IOS_H
#define NTSC_IOS_H
#include <stdint.h>

typedef struct NtscHandle NtscHandle;

NtscHandle *ntsc_create(void);
void ntsc_destroy(NtscHandle *handle);

/// grain, tracking (distortion), softness: 0...1. color: 0...2 (0 = black & white, 1 = natural).
/// tape_speed: 0 = SP, 1 = LP, 2 = EP.
void ntsc_set_params(NtscHandle *handle, float grain, float color, float tracking,
                     float softness, int32_t tape_speed);

/// Applies the VHS effect in place to a BGRA8 frame. Returns 0 on success.
int32_t ntsc_process_bgra(NtscHandle *handle, uint8_t *pixels, uint32_t width,
                          uint32_t height, uint32_t row_bytes, uint64_t frame_num);
#endif
