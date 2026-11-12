//! C FFI around the ntsc-rs VHS effect, used by the VHS Cam iOS app.
//! Frames are processed in place as BGRA8 (kCVPixelFormatType_32BGRA).
//!
//! Pipeline per frame:
//!   1. (optional) ntsc-rs VHS effect, when `vhs_on != 0`
//!   2. RGB "film" pass: tint, saturation (COLOR), contrast, film grain, vignette

use ntsc_rs::ctx::{self, Context};
use ntsc_rs::settings::standard::{
    FilterType, HeadSwitchingMidLineSettings, UseField, VHSEdgeWaveSettings, VHSTapeSpeed,
};
use ntsc_rs::yiq_fielding::{
    pixel_bytes_for, Bgrx, BlitInfo, DeinterlaceMode, YiqField, YiqView,
};
use ntsc_rs::NtscEffect;
use std::sync::Mutex;

/// Must match `NtscParams` in ntsc_ios.h (field order and types).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct NtscParams {
    pub vhs_on: i32,
    pub tape_speed: i32,  // 0 = SP, 1 = LP, 2 = EP
    pub filter_type: i32, // 0 = Butterworth (sharper), 1 = Constant-K (blurrier)
    pub snow_on: i32,
    pub grain: f32,
    pub color: f32, // 0 = B&W, 1 = natural, up to 2
    pub tracking: f32,
    pub softness: f32,
    pub composite_noise: f32,
    pub snow: f32,
    pub vignette: f32,
    pub tint_r: f32,
    pub tint_g: f32,
    pub tint_b: f32,
    pub contrast: f32,
    pub film_grain: f32,
}

impl Default for NtscParams {
    fn default() -> Self {
        NtscParams {
            vhs_on: 1,
            tape_speed: 1,
            filter_type: 0,
            snow_on: 1,
            grain: 0.45,
            color: 1.0,
            tracking: 0.45,
            softness: 0.45,
            composite_noise: 0.05,
            snow: 0.002,
            vignette: 0.0,
            tint_r: 1.0,
            tint_g: 1.0,
            tint_b: 1.0,
            contrast: 1.0,
            film_grain: 0.0,
        }
    }
}

struct State {
    effect: NtscEffect,
    params: NtscParams,
    yiq: Vec<f32>,
}

pub struct NtscHandle {
    state: Mutex<State>,
}

fn build_effect(p: &NtscParams) -> NtscEffect {
    let g = p.grain.clamp(0.0, 1.0);
    let d = p.tracking.clamp(0.0, 1.0);
    let s = p.softness.clamp(0.0, 1.0);

    let mut e = NtscEffect::default();
    e.use_field = UseField::InterleavedUpper;
    e.filter_type = if p.filter_type == 1 {
        FilterType::ConstantK
    } else {
        FilterType::Butterworth
    };
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

    // Composite signal noise (its own slider)
    let comp = p.composite_noise.clamp(0.0, 1.0);
    e.composite_noise.enabled = comp > 0.001;
    e.composite_noise.settings.intensity = comp;

    // Grain (luma / chroma noise)
    let grainy = g > 0.01;
    e.luma_noise.enabled = grainy;
    e.luma_noise.settings.intensity = 0.15 * g;
    e.chroma_noise.enabled = grainy;
    e.chroma_noise.settings.intensity = 0.35 * g;
    e.chroma_phase_noise_intensity = 0.006 * g;

    // Snow on/off
    let snow_on = p.snow_on != 0;
    e.snow_intensity = if snow_on { p.snow.max(0.0) } else { 0.0 };

    // Distortion (head-switching band and tracking noise render at the bottom of the frame)
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
    e.tracking_noise.settings.snow_intensity = if snow_on { 0.05 * d } else { 0.0 };
    e.tracking_noise.settings.noise_intensity = 0.5 * d;
    e.vhs_settings.settings.edge_wave.enabled = distorted;
    e.vhs_settings.settings.edge_wave.settings = VHSEdgeWaveSettings {
        intensity: 1.5 * d,
        ..Default::default()
    };
    e
}

fn new_state(p: &NtscParams) -> State {
    State { effect: build_effect(p), params: *p, yiq: Vec::new() }
}

/// Create a processor with default settings. Free with `ntsc_destroy`.
#[no_mangle]
pub extern "C" fn ntsc_create() -> *mut NtscHandle {
    // Warm up the global context (thread pool) now rather than on the first frame.
    let _ = ctx::global();
    let h = NtscHandle { state: Mutex::new(new_state(&NtscParams::default())) };
    Box::into_raw(Box::new(h))
}

#[no_mangle]
pub extern "C" fn ntsc_destroy(handle: *mut NtscHandle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Update all live controls (thread-safe, takes effect on the next frame).
#[no_mangle]
pub extern "C" fn ntsc_set_params(handle: *mut NtscHandle, params: *const NtscParams) {
    if handle.is_null() || params.is_null() {
        return;
    }
    let h = unsafe { &*handle };
    let p = unsafe { *params };
    if let Ok(mut s) = h.state.lock() {
        let yiq = std::mem::take(&mut s.yiq);
        *s = new_state(&p);
        s.yiq = yiq;
    }
}

fn run_ntsc(state: &mut State, pixels: *mut u8, w: usize, h_px: usize, rb: usize, frame_num: u64) {
    let ctx: &Context = ctx::global();
    let frame = frame_num as usize;
    let field: YiqField = state.effect.use_field.to_yiq_field(frame);
    let needed = YiqView::buf_length_for((w, h_px), field);
    if state.yiq.len() != needed {
        state.yiq = vec![0.0; needed];
    }

    let buf = unsafe { std::slice::from_raw_parts_mut(pixels, rb * h_px) };
    let blit = BlitInfo::from_full_frame(w, h_px, rb);

    let mut view = YiqView::from_parts(&mut state.yiq, (w, h_px), field);
    view.set_from_strided_buffer::<Bgrx, u8, _>(ctx, buf, blit, ());
    state
        .effect
        .apply_effect_to_yiq(ctx, &mut view, frame, [1.0, 1.0]);
    view.write_to_strided_buffer::<Bgrx, u8, _>(ctx, buf, blit, DeinterlaceMode::Bob, ());
}

/// Film look on the BGRA buffer: tint, saturation, contrast, grain, vignette.
fn grade(pixels: *mut u8, w: usize, h: usize, rb: usize, frame: u64, p: &NtscParams) {
    let sat = p.color.clamp(0.0, 2.0);
    let vig = p.vignette.clamp(0.0, 1.0);
    let grain_amt = p.film_grain.clamp(0.0, 1.0) * 40.0;
    let neutral = p.tint_r == 1.0
        && p.tint_g == 1.0
        && p.tint_b == 1.0
        && (sat - 1.0).abs() < 1e-3
        && p.contrast == 1.0
        && grain_amt == 0.0
        && vig == 0.0;
    if neutral {
        return;
    }

    let buf = unsafe { std::slice::from_raw_parts_mut(pixels, rb * h) };
    let cx = (w as f32 - 1.0) / 2.0;
    let cy = (h as f32 - 1.0) / 2.0;
    let inv = 1.0 / (cx * cx + cy * cy).max(1.0);
    let mut rng: u32 = (frame as u32).wrapping_mul(2654435761).wrapping_add(0x9E37_79B9) | 1;

    for y in 0..h {
        let dy = y as f32 - cy;
        let dy2 = dy * dy;
        let row = &mut buf[y * rb..y * rb + w * 4];
        for (x, px) in row.chunks_exact_mut(4).enumerate() {
            let dx = x as f32 - cx;
            let v = (1.0 - vig * ((dx * dx + dy2) * inv)).max(0.0);

            let mut b = px[0] as f32 * p.tint_b;
            let mut g = px[1] as f32 * p.tint_g;
            let mut r = px[2] as f32 * p.tint_r;

            let lum = 0.299 * r + 0.587 * g + 0.114 * b;
            r = lum + (r - lum) * sat;
            g = lum + (g - lum) * sat;
            b = lum + (b - lum) * sat;

            r = (r - 128.0) * p.contrast + 128.0;
            g = (g - 128.0) * p.contrast + 128.0;
            b = (b - 128.0) * p.contrast + 128.0;

            if grain_amt > 0.0 {
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
                let n = ((rng & 0xFF) as f32 - 127.5) / 127.5 * grain_amt;
                r += n;
                g += n;
                b += n;
            }

            px[0] = (b * v).clamp(0.0, 255.0) as u8;
            px[1] = (g * v).clamp(0.0, 255.0) as u8;
            px[2] = (r * v).clamp(0.0, 255.0) as u8;
        }
    }
}

/// Process a BGRA8 frame in place. `row_bytes` may include padding.
/// Returns 0 on success, non-zero on bad args.
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
    let params = state.params;

    if params.vhs_on != 0 {
        run_ntsc(state, pixels, w, h_px, rb, frame_num);
    }
    grade(pixels, w, h_px, rb, frame_num, &params);
    0
}
