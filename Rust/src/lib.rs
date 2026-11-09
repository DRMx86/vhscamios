//! Minimal C FFI around the ntsc-rs VHS effect, used by the VHSCam iOS app.
//! Frames are processed in place as BGRA8 (kCVPixelFormatType_32BGRA).

use ntsc_rs::ctx::{self, Context};
use ntsc_rs::settings::standard::{
    HeadSwitchingMidLineSettings, UseField, VHSEdgeWaveSettings, VHSSharpenSettings,
    VHSTapeSpeed,
};
use ntsc_rs::yiq_fielding::{
    pixel_bytes_for, Bgrx, BlitInfo, DeinterlaceMode, YiqField, YiqView,
};
use ntsc_rs::NtscEffect;
use std::sync::Mutex;

struct State {
    effect: NtscEffect,
    yiq: Vec<f32>,
}

pub struct NtscHandle {
    state: Mutex<State>,
}

/// Build an effect from a preset (0 = Light, 1 = Classic VHS, 2 = Worn Tape)
/// and an intensity in 0.0..=1.0 that scales noise / tracking artifacts.
fn build_effect(preset: i32, intensity: f32) -> NtscEffect {
    let k = intensity.clamp(0.0, 1.0);
    let mut e = NtscEffect::default();
    e.use_field = UseField::InterleavedUpper;
    e.vhs_settings.enabled = true;
    e.head_switching.enabled = true;
    e.tracking_noise.enabled = true;
    e.ringing.enabled = true;
    e.vhs_settings.settings.edge_wave.enabled = true;
    e.vhs_settings.settings.sharpen.enabled = true;

    match preset {
        0 => {
            e.vhs_settings.settings.tape_speed = VHSTapeSpeed::SP;
            e.head_switching.settings.height = 4;
            e.tracking_noise.settings.height = 6;
            e.tracking_noise.settings.wave_intensity = 5.0 * k;
            e.tracking_noise.settings.snow_intensity = 0.01 * k;
            e.tracking_noise.settings.noise_intensity = 0.1 * k;
            e.vhs_settings.settings.edge_wave.settings = VHSEdgeWaveSettings {
                intensity: 0.25 * k,
                ..Default::default()
            };
            e.composite_noise.settings.intensity = 0.03 * k;
            e.chroma_noise.settings.intensity = 0.05 * k;
        }
        2 => {
            e.vhs_settings.settings.tape_speed = VHSTapeSpeed::EP;
            e.vhs_settings.settings.chroma_loss = 0.0003 * k;
            e.head_switching.settings.height = 14;
            e.head_switching.settings.horiz_shift = 120.0 * k;
            e.head_switching.settings.mid_line.enabled = true;
            e.head_switching.settings.mid_line.settings = HeadSwitchingMidLineSettings {
                position: 0.92,
                jitter: 0.08 * k,
            };
            e.tracking_noise.settings.height = 20;
            e.tracking_noise.settings.wave_intensity = 30.0 * k;
            e.tracking_noise.settings.snow_intensity = 0.06 * k;
            e.tracking_noise.settings.noise_intensity = 0.5 * k;
            e.vhs_settings.settings.edge_wave.settings = VHSEdgeWaveSettings {
                intensity: 1.2 * k,
                ..Default::default()
            };
            e.vhs_settings.settings.sharpen.settings = VHSSharpenSettings {
                intensity: 0.4,
                frequency: 1.0,
            };
            e.snow_intensity = 0.0008 * k;
            e.composite_noise.settings.intensity = 0.09 * k;
            e.chroma_noise.settings.intensity = 0.2 * k;
            e.chroma_phase_noise_intensity = 0.004 * k;
        }
        _ => {
            // Classic VHS: LP tape speed with the library defaults, scaled by intensity.
            e.vhs_settings.settings.tape_speed = VHSTapeSpeed::LP;
            e.tracking_noise.settings.wave_intensity = 15.0 * k;
            e.tracking_noise.settings.snow_intensity = 0.025 * k;
            e.tracking_noise.settings.noise_intensity = 0.25 * k;
            e.vhs_settings.settings.edge_wave.settings = VHSEdgeWaveSettings {
                intensity: 0.5 * k,
                ..Default::default()
            };
            e.composite_noise.settings.intensity = 0.05 * k;
            e.chroma_noise.settings.intensity = 0.1 * k;
        }
    }
    e
}

/// Create a processor. Free with `ntsc_destroy`.
#[no_mangle]
pub extern "C" fn ntsc_create(preset: i32, intensity: f32) -> *mut NtscHandle {
    // Warm up the global context (thread pool) now rather than on the first frame.
    let _ = ctx::global();
    let h = NtscHandle {
        state: Mutex::new(State {
            effect: build_effect(preset, intensity),
            yiq: Vec::new(),
        }),
    };
    Box::into_raw(Box::new(h))
}

#[no_mangle]
pub extern "C" fn ntsc_destroy(handle: *mut NtscHandle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Change preset / intensity while running (thread-safe).
#[no_mangle]
pub extern "C" fn ntsc_set_preset(handle: *mut NtscHandle, preset: i32, intensity: f32) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &*handle };
    if let Ok(mut s) = h.state.lock() {
        s.effect = build_effect(preset, intensity);
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

    let buf = unsafe { std::slice::from_raw_parts_mut(pixels, rb * h_px) };
    let blit = BlitInfo::from_full_frame(w, h_px, rb);

    let mut view = YiqView::from_parts(&mut state.yiq, (w, h_px), field);
    view.set_from_strided_buffer::<Bgrx, u8, _>(ctx, buf, blit, ());
    state
        .effect
        .apply_effect_to_yiq(ctx, &mut view, frame, [1.0, 1.0]);
    view.write_to_strided_buffer::<Bgrx, u8, _>(ctx, buf, blit, DeinterlaceMode::Bob, ());
    0
}
