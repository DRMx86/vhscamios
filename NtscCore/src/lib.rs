//! C FFI around the ntsc-rs VHS effect, used by the VHS Cam iOS app.
//! Frames are processed in place as BGRA8 (kCVPixelFormatType_32BGRA).
//!
//! Live "tape controls" (all 0..1 unless noted):
//!   grain      - composite / luma / chroma noise and snow
//!   color      - saturation multiplier (0 = black & white, 1 = natural, up to 2)
//!   tracking   - distortion: head-switching band at the bottom, tracking noise, edge wobble
//!   softness   - horizontal luma smear (blur)
//!   tape_speed - 0 = SP (sharpest), 1 = LP, 2 = EP (softest / noisiest)

use ntsc_rs::ctx::{self, Context};
use ntsc_rs::settings::standard::{
    HeadSwitchingMidLineSettings, UseField, VHSEdgeWaveSettings, VHSTapeSpeed,
};
use ntsc_rs::yiq_fielding::{
    pixel_bytes_for, Bgrx, BlitInfo, DeinterlaceMode, YiqField, YiqView,
};
use ntsc_rs::NtscEffect;
use std::sync::Mutex;

#[derive(Clone, Copy)]
struct Params {
    grain: f32,
    color: f32,
    tracking: f32,
    softness: f32,
    tape_speed: i32,
}

impl Default for Params {
    fn default() -> Self {
        Params { grain: 0.45, color: 1.0, tracking: 0.45, softness: 0.45, tape_speed: 1 }
    }
}

struct State {
    effect: NtscEffect,
    saturation: f32,
    yiq: Vec<f32>,
}

pub struct NtscHandle {
    state: Mutex<State>,
}

fn build_effect(p: &Params) -> NtscEffect {
    let g = p.grain.clamp(0.0, 1.0);
    let d = p.tracking.clamp(0.0, 1.0);
    let s = p.softness.clamp(0.0, 1.0);

    let mut e = NtscEffect::default();
    e.use_field = UseField::InterleavedUpper;
    e.chroma_vert_blend = true;
    e.luma_smear = 1.0 * s;
    e.ringing.enabled = true;

    // Tape
    e.vhs_settings.enabled = true;
    e.vhs_settings.settings.tape_speed = match p.tape_speed {
        0 => VHSTapeSpeed::SP,
        2 => VHSTapeSpeed::EP,
        _ => VHSTapeSpeed::LP,
    };
    e.vhs_settings.settings.sharpen.enabled = true;

    // Grain
    let grainy = g > 0.01;
    e.composite_noise.enabled = grainy;
    e.composite_noise.settings.intensity = 0.12 * g;
    e.luma_noise.enabled = grainy;
    e.luma_noise.settings.intensity = 0.15 * g;
    e.chroma_noise.enabled = grainy;
    e.chroma_noise.settings.intensity = 0.35 * g;
    e.snow_intensity = 0.004 * g;
    e.chroma_phase_noise_intensity = 0.006 * g;

    // Distortion (the head-switching band and tracking noise render at the bottom of the frame)
    let distorted = d > 0.02;
    e.head_switching.enabled = distorted;
    e.head_switching.settings.height = (3.0 + 14.0 * d) as i32;
    e.head_switching.settings.horiz_shift = 10.0 + 110.0 * d;
    e.head_switching.settings.mid_line.enabled = d > 0.6;
    e.head_switching.settings.mid_line.settings = HeadSwitchingMidLineSettings {
        position: 0.92,
        jitter: 0.1 * d,
    };
    e.tracking_noise.enabled = distorted;
    e.tracking_noise.settings.height = (4.0 + 18.0 * d) as i32;
    e.tracking_noise.settings.wave_intensity = 35.0 * d;
    e.tracking_noise.settings.snow_intensity = 0.05 * d;
    e.tracking_noise.settings.noise_intensity = 0.5 * d;
    e.vhs_settings.settings.edge_wave.enabled = distorted;
    e.vhs_settings.settings.edge_wave.settings = VHSEdgeWaveSettings {
        intensity: 1.5 * d,
        ..Default::default()
    };
    e
}

fn new_state(p: &Params) -> State {
    State {
        effect: build_effect(p),
        saturation: p.color.clamp(0.0, 2.0),
        yiq: Vec::new(),
    }
}

/// Create a processor with default settings. Free with `ntsc_destroy`.
#[no_mangle]
pub extern "C" fn ntsc_create() -> *mut NtscHandle {
    // Warm up the global context (thread pool) now rather than on the first frame.
    let _ = ctx::global();
    let h = NtscHandle { state: Mutex::new(new_state(&Params::default())) };
    Box::into_raw(Box::new(h))
}

#[no_mangle]
pub extern "C" fn ntsc_destroy(handle: *mut NtscHandle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Update the live tape controls (thread-safe, takes effect on the next frame).
#[no_mangle]
pub extern "C" fn ntsc_set_params(
    handle: *mut NtscHandle,
    grain: f32,
    color: f32,
    tracking: f32,
    softness: f32,
    tape_speed: i32,
) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &*handle };
    let p = Params { grain, color, tracking, softness, tape_speed };
    if let Ok(mut s) = h.state.lock() {
        let yiq = std::mem::take(&mut s.yiq);
        *s = new_state(&p);
        s.yiq = yiq;
    }
}

/// Apply the VHS effect in place to a BGRA8 frame.
/// `row_bytes` may include padding. Returns 0 on success, non-zero on bad args.
#[no_mangle]
pub extern "C" fn ntsc_process_bgra(
    handle: *mut NtscHandle,
    pixels: *mut u8,
    width: u32,
    height: u32,
    row_bytes: u32,
    frame_num: u64,
) -> i32 {
    if handle.is_null() || pixels.is_null() || width == 0 || height < 2 {
        return 1;
    }
    let (w, h_px, rb) = (width as usize, height as usize, row_bytes as usize);
    if rb < w * pixel_bytes_for::<Bgrx, u8>() {
        return 2;
    }
    let handle = unsafe { &*handle };
    let mut guard = match handle.state.lock() {
        Ok(g) => g,
        Err(_) => return 3,
    };
    let state = &mut *guard;
    let ctx: &Context = ctx::global();

    let frame = frame_num as usize;
    let field: YiqField = state.effect.use_field.to_yiq_field(frame);
    let needed = YiqView::buf_length_for((w, h_px), field);
    if state.yiq.len() != needed {
        state.yiq = vec![0.0; needed];
    }
    let saturation = state.saturation;

    let buf = unsafe { std::slice::from_raw_parts_mut(pixels, rb * h_px) };
    let blit = BlitInfo::from_full_frame(w, h_px, rb);

    let mut view = YiqView::from_parts(&mut state.yiq, (w, h_px), field);
    view.set_from_strided_buffer::<Bgrx, u8, _>(ctx, buf, blit, ());
    state
        .effect
        .apply_effect_to_yiq(ctx, &mut view, frame, [1.0, 1.0]);

    // Color knob: scale the chroma planes (0 = black & white).
    if (saturation - 1.0).abs() > 1e-3 {
        for v in view.i.iter_mut() {
            *v *= saturation;
        }
        for v in view.q.iter_mut() {
            *v *= saturation;
        }
    }

    view.write_to_strided_buffer::<Bgrx, u8, _>(ctx, buf, blit, DeinterlaceMode::Bob, ());
    0
}
