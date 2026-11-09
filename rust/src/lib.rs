use ntscrs::ntsc::NtscEffect;
use ntscrs::yiq_fielding::Rgbx;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::OnceLock;

static EFFECT: OnceLock<NtscEffect> = OnceLock::new();

/// Applies the ntsc-rs VHS effect in place to a BGRA frame.
/// Returns 0 on success, negative on error.
///
/// # Safety
/// `buf` must point to at least `stride * height` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn vhs_process(
    buf: *mut u8,
    width: usize,
    height: usize,
    stride: usize,
    frame: u64,
) -> i32 {
    if buf.is_null() || width == 0 || height == 0 || stride < width * 4 {
        return -1;
    }
    let data = std::slice::from_raw_parts_mut(buf, stride * height);
    let result = catch_unwind(AssertUnwindSafe(|| {
        let effect = EFFECT.get_or_init(NtscEffect::default);
        let row = width * 4;
        // Tightly packed RGBX scratch buffer (swap B<->R from the camera's BGRA).
        let mut tmp = vec![0u8; row * height];
        for y in 0..height {
            let src = &data[y * stride..y * stride + row];
            let dst = &mut tmp[y * row..(y + 1) * row];
            for (d, s) in dst.chunks_exact_mut(4).zip(src.chunks_exact(4)) {
                d[0] = s[2];
                d[1] = s[1];
                d[2] = s[0];
                d[3] = 255;
            }
        }

        // The only call into ntsc-rs; if the crate API changes, fix it here.
        effect.apply_effect_to_buffer::<Rgbx>((width, height), &mut tmp, frame as usize, [1.0, 1.0]);

        for y in 0..height {
            let dst = &mut data[y * stride..y * stride + row];
            let src = &tmp[y * row..(y + 1) * row];
            for (d, s) in dst.chunks_exact_mut(4).zip(src.chunks_exact(4)) {
                d[0] = s[2];
                d[1] = s[1];
                d[2] = s[0];
                d[3] = 255;
            }
        }
    }));
    if result.is_ok() { 0 } else { -2 }
}
