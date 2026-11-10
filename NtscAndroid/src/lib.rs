//! JNI bridge: com.drmx86.vhscam.Ntsc  ->  NtscCore (the same Rust core the iOS / macOS apps use).
use jni::objects::{JByteBuffer, JObject};
use jni::sys::{jfloat, jint, jlong};
use jni::JNIEnv;
use ntsc_ios::NtscHandle;

#[no_mangle]
pub extern "system" fn Java_com_drmx86_vhscam_Ntsc_create(_env: JNIEnv, _this: JObject) -> jlong {
    ntsc_ios::ntsc_create() as jlong
}

#[no_mangle]
pub extern "system" fn Java_com_drmx86_vhscam_Ntsc_destroy(_env: JNIEnv, _this: JObject, handle: jlong) {
    ntsc_ios::ntsc_destroy(handle as *mut NtscHandle);
}

#[no_mangle]
pub extern "system" fn Java_com_drmx86_vhscam_Ntsc_setParams(
    _env: JNIEnv,
    _this: JObject,
    handle: jlong,
    grain: jfloat,
    color: jfloat,
    tracking: jfloat,
    softness: jfloat,
    tape: jint,
) {
    ntsc_ios::ntsc_set_params(handle as *mut NtscHandle, grain, color, tracking, softness, tape);
}

/// Processes a direct ByteBuffer holding RGBA8 pixels in place. Returns 0 on success.
#[no_mangle]
pub extern "system" fn Java_com_drmx86_vhscam_Ntsc_process(
    env: JNIEnv,
    _this: JObject,
    handle: jlong,
    buffer: JByteBuffer,
    width: jint,
    height: jint,
    row_bytes: jint,
    frame: jlong,
) -> jint {
    if width <= 0 || height <= 0 || row_bytes <= 0 {
        return 10;
    }
    let ptr = match env.get_direct_buffer_address(&buffer) {
        Ok(p) => p,
        Err(_) => return 11,
    };
    let cap = env.get_direct_buffer_capacity(&buffer).unwrap_or(0);
    if cap < (row_bytes as usize) * (height as usize) {
        return 12;
    }
    ntsc_ios::ntsc_process_rgba(
        handle as *mut NtscHandle,
        ptr,
        width as u32,
        height as u32,
        row_bytes as u32,
        frame as u64,
    )
}
