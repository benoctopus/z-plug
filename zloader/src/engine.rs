//! Safe Rust wrapper around the z_plug_engine C API.
#![allow(dead_code)]

use std::path::Path;

use anyhow::{anyhow, bail, Result};

use crate::ffi;
use crate::host::PluginHost;

// ---------------------------------------------------------------------------
// AudioEngine
// ---------------------------------------------------------------------------

/// Safe wrapper around the z_plug_engine audio engine.
///
/// Manages playback of a WAV file through an optional CLAP plugin using
/// CoreAudio AudioQueue on macOS.
///
/// All methods must be called from the main thread.
/// The underlying `ZpeEngine` pointer is freed on `Drop`.
pub struct AudioEngine {
    ptr: *mut ffi::ZpeEngine,
}

impl Drop for AudioEngine {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { ffi::zpe_destroy(self.ptr) };
        }
    }
}

impl AudioEngine {
    /// Create a new audio engine.
    ///
    /// `sample_rate`: output sample rate in Hz (0 defaults to 44100).
    /// `buffer_size`: frames per audio callback (0 defaults to 512).
    pub fn new(sample_rate: f64, buffer_size: u32) -> Result<Self> {
        let ptr = unsafe { ffi::zpe_create(sample_rate, buffer_size) };
        if ptr.is_null() {
            bail!("zpe_create returned NULL");
        }
        Ok(Self { ptr })
    }

    /// Load a WAV file for playback.
    ///
    /// Stops playback and resets position if a file was already loaded.
    pub fn load_file(&mut self, path: &Path) -> Result<()> {
        let path_cstr = path_to_cstring(path)?;
        let ok = unsafe { ffi::zpe_load_file(self.ptr, path_cstr.as_ptr()) };
        if !ok {
            bail!("zpe_load_file failed for {:?}", path);
        }
        Ok(())
    }

    /// Attach a CLAP plugin to the engine.
    ///
    /// Audio from the loaded WAV file will be routed through the plugin before
    /// output. The plugin must be activated and processing-started before
    /// calling `play()`.
    ///
    /// Pass `None` to detach and use passthrough mode.
    pub fn set_plugin(&mut self, host: Option<&mut PluginHost>) {
        let plugin_ptr = host
            .map(|h| h.raw_ptr())
            .unwrap_or(std::ptr::null_mut());
        unsafe { ffi::zpe_set_plugin(self.ptr, plugin_ptr) };
    }

    /// Start playback.
    pub fn play(&mut self) -> Result<()> {
        let ok = unsafe { ffi::zpe_play(self.ptr) };
        if !ok {
            bail!("zpe_play failed (no file loaded or audio init error)");
        }
        Ok(())
    }

    /// Pause playback. The current position is preserved.
    pub fn pause(&mut self) {
        unsafe { ffi::zpe_pause(self.ptr) };
    }

    /// Stop playback and reset position to 0.
    pub fn stop(&mut self) {
        unsafe { ffi::zpe_stop(self.ptr) };
    }

    /// Seek to a specific sample position.
    pub fn seek(&mut self, sample_position: u64) {
        unsafe { ffi::zpe_seek(self.ptr, sample_position) };
    }

    /// Return the current playback position in samples.
    pub fn position(&self) -> u64 {
        unsafe { ffi::zpe_get_position(self.ptr) }
    }

    /// Return the total length of the loaded file in samples.
    /// Returns 0 if no file is loaded.
    pub fn length(&self) -> u64 {
        unsafe { ffi::zpe_get_length(self.ptr) }
    }

    /// Return the engine's output sample rate in Hz.
    pub fn sample_rate(&self) -> f64 {
        unsafe { ffi::zpe_get_sample_rate(self.ptr) }
    }

    /// Return the channel count of the loaded file.
    /// Returns 0 if no file is loaded.
    pub fn channels(&self) -> u32 {
        unsafe { ffi::zpe_get_channel_count(self.ptr) }
    }

    /// Return true if the engine is currently playing.
    pub fn is_playing(&self) -> bool {
        unsafe { ffi::zpe_is_playing(self.ptr) }
    }

    /// Enable or disable looping.
    pub fn set_looping(&mut self, enable: bool) {
        unsafe { ffi::zpe_set_looping(self.ptr, enable) };
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn path_to_cstring(path: &Path) -> Result<std::ffi::CString> {
    let s = path
        .to_str()
        .ok_or_else(|| anyhow!("path is not valid UTF-8: {:?}", path))?;
    std::ffi::CString::new(s).map_err(|e| anyhow!("path contains null byte: {e}"))
}
