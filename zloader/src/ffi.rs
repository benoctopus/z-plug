//! Raw FFI bindings to z_plug_host and z_plug_engine C APIs.
#![allow(dead_code)]
//!
//! These declarations mirror `lib/z_plug_host/z_plug_host.h` and
//! `lib/z_plug_engine/z_plug_engine.h` exactly. Do not use these types
//! directly; prefer the safe wrappers in `host.rs` and `engine.rs`.

use std::ffi::c_char;

// ---------------------------------------------------------------------------
// Opaque handle types
// ---------------------------------------------------------------------------

/// Opaque handle to a loaded CLAP plugin instance (`ZphPlugin*`).
#[repr(C)]
pub struct ZphPlugin {
    _private: [u8; 0],
}

/// Opaque handle to an audio engine instance (`ZpeEngine*`).
#[repr(C)]
pub struct ZpeEngine {
    _private: [u8; 0],
}

// ---------------------------------------------------------------------------
// Process status (mirrors clap_process_status)
// ---------------------------------------------------------------------------

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZphProcessStatus {
    Error = 0,
    Continue = 1,
    ContinueIfNotQuiet = 2,
    Tail = 3,
    Sleep = 4,
}

// ---------------------------------------------------------------------------
// Plugin info struct (matches ZphPluginInfo in z_plug_host.h)
// ---------------------------------------------------------------------------

/// Plugin metadata returned by `zph_get_plugin_info`.
/// String pointers are owned by the plugin and valid for the plugin lifetime.
#[repr(C)]
pub struct ZphPluginInfo {
    pub id: *const c_char,
    pub name: *const c_char,
    pub vendor: *const c_char,
    pub version: *const c_char,
    pub description: *const c_char,
    pub input_channels: u32,
    pub output_channels: u32,
    pub latency_samples: u32,
}

impl Default for ZphPluginInfo {
    fn default() -> Self {
        Self {
            id: std::ptr::null(),
            name: std::ptr::null(),
            vendor: std::ptr::null(),
            version: std::ptr::null(),
            description: std::ptr::null(),
            input_channels: 0,
            output_channels: 0,
            latency_samples: 0,
        }
    }
}

// ---------------------------------------------------------------------------
// Parameter info struct (matches ZphParamInfo in z_plug_host.h)
// ---------------------------------------------------------------------------

/// Parameter metadata returned by `zph_get_param_info`.
/// `name` and `module` are null-terminated strings stored inline.
#[repr(C)]
pub struct ZphParamInfo {
    pub id: u32,
    pub name: [u8; 256],
    pub module: [u8; 1024],
    pub min_value: f64,
    pub max_value: f64,
    pub default_value: f64,
    pub flags: u32,
}

impl Default for ZphParamInfo {
    fn default() -> Self {
        Self {
            id: 0,
            name: [0u8; 256],
            module: [0u8; 1024],
            min_value: 0.0,
            max_value: 1.0,
            default_value: 0.0,
            flags: 0,
        }
    }
}

// ---------------------------------------------------------------------------
// z_plug_host extern "C" declarations
// ---------------------------------------------------------------------------

extern "C" {
    /// Load a .clap file and instantiate a plugin. Returns NULL on failure.
    /// `plugin_id` may be NULL to load the first available plugin.
    pub fn zph_load_plugin(path: *const c_char, plugin_id: *const c_char) -> *mut ZphPlugin;

    /// Destroy a plugin handle and free all resources.
    pub fn zph_destroy(plugin: *mut ZphPlugin);

    /// Activate the plugin for audio processing.
    pub fn zph_activate(plugin: *mut ZphPlugin, sample_rate: f64, max_frames: u32) -> bool;

    /// Deactivate the plugin.
    pub fn zph_deactivate(plugin: *mut ZphPlugin);

    /// Start the audio processing state (call from audio thread after activate).
    pub fn zph_start_processing(plugin: *mut ZphPlugin) -> bool;

    /// Stop the audio processing state.
    pub fn zph_stop_processing(plugin: *mut ZphPlugin);

    /// Process one block of audio through the plugin.
    pub fn zph_process(
        plugin: *mut ZphPlugin,
        inputs: *const *const f32,
        outputs: *const *mut f32,
        channel_count: u32,
        frame_count: u32,
    ) -> ZphProcessStatus;

    /// Fill `out` with plugin metadata.
    pub fn zph_get_plugin_info(plugin: *const ZphPlugin, out: *mut ZphPluginInfo) -> bool;

    /// Return the number of parameters the plugin exposes.
    pub fn zph_get_param_count(plugin: *const ZphPlugin) -> u32;

    /// Fill `out` with info about the parameter at `index`.
    pub fn zph_get_param_info(
        plugin: *const ZphPlugin,
        index: u32,
        out: *mut ZphParamInfo,
    ) -> bool;

    /// Get the current value of a parameter by its stable ID.
    pub fn zph_get_param_value(
        plugin: *const ZphPlugin,
        param_id: u32,
        out: *mut f64,
    ) -> bool;

    /// Queue a parameter change to be applied on the next process call.
    pub fn zph_set_param_value(plugin: *mut ZphPlugin, param_id: u32, value: f64);

    /// Save plugin state. Pass buffer=NULL to query required size.
    pub fn zph_save_state(plugin: *const ZphPlugin, buffer: *mut u8, size: *mut u32) -> bool;

    /// Load plugin state from buffer.
    pub fn zph_load_state(plugin: *mut ZphPlugin, buffer: *const u8, size: u32) -> bool;

    /// Handle deferred plugin callbacks. Call periodically from the main thread.
    pub fn zph_idle(plugin: *mut ZphPlugin);
}

// ---------------------------------------------------------------------------
// z_plug_engine extern "C" declarations
// ---------------------------------------------------------------------------

extern "C" {
    /// Create a new audio engine.
    pub fn zpe_create(sample_rate: f64, buffer_size: u32) -> *mut ZpeEngine;

    /// Destroy the engine and free all resources.
    pub fn zpe_destroy(engine: *mut ZpeEngine);

    /// Load a WAV file for playback.
    pub fn zpe_load_file(engine: *mut ZpeEngine, path: *const c_char) -> bool;

    /// Attach a CLAP plugin to the engine.
    pub fn zpe_set_plugin(engine: *mut ZpeEngine, plugin: *mut ZphPlugin);

    /// Start playback.
    pub fn zpe_play(engine: *mut ZpeEngine) -> bool;

    /// Pause playback (position preserved).
    pub fn zpe_pause(engine: *mut ZpeEngine);

    /// Stop playback and reset position to 0.
    pub fn zpe_stop(engine: *mut ZpeEngine);

    /// Seek to a specific sample position.
    pub fn zpe_seek(engine: *mut ZpeEngine, sample_position: u64);

    /// Return the current playback position in samples.
    pub fn zpe_get_position(engine: *const ZpeEngine) -> u64;

    /// Return the total length of the loaded file in samples.
    pub fn zpe_get_length(engine: *const ZpeEngine) -> u64;

    /// Return the engine's output sample rate in Hz.
    pub fn zpe_get_sample_rate(engine: *const ZpeEngine) -> f64;

    /// Return the channel count of the loaded file.
    pub fn zpe_get_channel_count(engine: *const ZpeEngine) -> u32;

    /// Return true if the engine is currently playing.
    pub fn zpe_is_playing(engine: *const ZpeEngine) -> bool;

    /// Enable or disable looping.
    pub fn zpe_set_looping(engine: *mut ZpeEngine, enable: bool);
}
