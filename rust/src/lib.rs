use ntscrs::NtscEffect;

#[no_mangle]
pub extern "C" fn ntsc_effect_new() -> *mut NtscEffect {
    Box::into_raw(Box::new(NtscEffect::default()))
}

#[no_mangle]
pub extern "C" fn ntsc_effect_free(effect: *mut NtscEffect) {
    if !effect.is_null() {
        unsafe {
            drop(Box::from_raw(effect));
        }
    }
}

#[no_mangle]
pub extern "C" fn ntsc_effect_process(
    effect: *mut NtscEffect,
    input: *const u8,
    output: *mut u8,
    width: usize,
    height: usize,
) {
    if effect.is_null() || input.is_null() || output.is_null() {
        return;
    }

    let effect = unsafe { &mut *effect };
    let input_slice = unsafe { std::slice::from_raw_parts(input, width * height * 4) };
    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, width * height * 4) };

    // The function processes the buffer in-place.
    // Copy the input into the output buffer first.
    output_slice.copy_from_slice(input_slice);

    // Correct signature: (dimensions, mutable_buffer, stride, scale)
    // Stride for RGBA data is width * 4 bytes.
    effect.apply_effect_to_buffer((width, height), output_slice, width * 4, [1.0, 1.0]);
}
