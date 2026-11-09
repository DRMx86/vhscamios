#ifndef NTSC_IOS_H
#define NTSC_IOS_H
#include <stdint.h>

typedef struct NtscHandle NtscHandle;

/// preset: 0 = Light, 1 = Classic VHS, 2 = Worn Tape. intensity: 0.0 ... 1.0
NtscHandle *ntsc_create(int32_t preset, float intensity);
void ntsc_destroy(NtscHandle *handle);
void ntsc_set_preset(NtscHandle *handle, int32_t preset, float intensity);

/// Applies the VHS effect in place to a BGRA8 frame. Returns 0 on success.
int32_t ntsc_process_bgra(NtscHandle *handle, uint8_t *pixels, uint32_t width,
                          uint32_t height, uint32_t row_bytes, uint64_t frame_num);
#endif
