#include <stdint.h>
#include <stddef.h>

// Applies the ntsc-rs VHS effect in place to a BGRA frame. Returns 0 on success.
int32_t vhs_process(uint8_t *buf, size_t width, size_t height, size_t stride, uint64_t frame);
