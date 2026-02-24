//! Safe Rust wrapper around the z_plug_host C API.
#![allow(dead_code)]

use std::ffi::{CStr, CString};
use std::path::Path;

use anyhow::{anyhow, bail, Result};

use crate::ffi;

// ---------------------------------------------------------------------------
// Param info (safe Rust representation)
// ---------------------------------------------------------------------------

/// Safe Rust representation of a plugin parameter.
#[derive(Debug, Clone)]
pub struct ParamInfo {
    pub id: u32,
    pub name: String,
    pub module: String,
    pub min_value: f64,
    pub max_value: f64,
    pub default_value: f64,
    pub flags: u32,
}

// ---------------------------------------------------------------------------
// Plugin info (safe Rust representation)
// ---------------------------------------------------------------------------

/// Safe Rust representation of plugin metadata.
#[derive(Debug, Clone)]
pub struct PluginInfo {
    pub id: String,
    pub name: String,
    pub vendor: String,
    pub version: String,
    pub description: String,
    pub input_channels: u32,
    pub output_channels: u32,
    pub latency_samples: u32,
}

// ---------------------------------------------------------------------------
// PluginHost
// ---------------------------------------------------------------------------

/// Safe wrapper around a loaded CLAP plugin instance.
///
/// All methods must be called from the main thread unless otherwise noted.
/// The underlying `ZphPlugin` pointer is freed on `Drop`.
pub struct PluginHost {
    ptr: *mut ffi::ZphPlugin,
}

// The Zig host library is designed for single-threaded main-thread use.
// We assert this by not implementing Send/Sync.

impl Drop for PluginHost {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { ffi::zph_destroy(self.ptr) };
        }
    }
}

impl PluginHost {
    /// Load a `.clap` file and instantiate a plugin.
    ///
    /// `plugin_id` may be `None` to load the first available plugin.
    pub fn load(path: &Path, plugin_id: Option<&str>) -> Result<Self> {
        let path_cstr = path_to_cstring(path)?;
        let id_cstr: Option<CString> = plugin_id
            .map(|s| CString::new(s).map_err(|e| anyhow!("invalid plugin_id: {e}")))
            .transpose()?;

        let id_ptr = id_cstr
            .as_ref()
            .map(|c| c.as_ptr())
            .unwrap_or(std::ptr::null());

        let ptr = unsafe { ffi::zph_load_plugin(path_cstr.as_ptr(), id_ptr) };
        if ptr.is_null() {
            bail!("zph_load_plugin returned NULL for {:?}", path);
        }
        Ok(Self { ptr })
    }

    /// Activate the plugin for audio processing.
    pub fn activate(&mut self, sample_rate: f64, max_frames: u32) -> Result<()> {
        let ok = unsafe { ffi::zph_activate(self.ptr, sample_rate, max_frames) };
        if !ok {
            bail!("zph_activate failed");
        }
        Ok(())
    }

    /// Deactivate the plugin.
    pub fn deactivate(&mut self) {
        unsafe { ffi::zph_deactivate(self.ptr) };
    }

    /// Start the audio processing state. Must be called before `process`.
    pub fn start_processing(&mut self) -> Result<()> {
        let ok = unsafe { ffi::zph_start_processing(self.ptr) };
        if !ok {
            bail!("zph_start_processing failed");
        }
        Ok(())
    }

    /// Stop the audio processing state.
    pub fn stop_processing(&mut self) {
        unsafe { ffi::zph_stop_processing(self.ptr) };
    }

    /// Retrieve plugin metadata.
    pub fn get_info(&self) -> Result<PluginInfo> {
        let mut raw = ffi::ZphPluginInfo::default();
        let ok = unsafe { ffi::zph_get_plugin_info(self.ptr, &mut raw) };
        if !ok {
            bail!("zph_get_plugin_info failed");
        }
        Ok(PluginInfo {
            id: cstr_ptr_to_string(raw.id),
            name: cstr_ptr_to_string(raw.name),
            vendor: cstr_ptr_to_string(raw.vendor),
            version: cstr_ptr_to_string(raw.version),
            description: cstr_ptr_to_string(raw.description),
            input_channels: raw.input_channels,
            output_channels: raw.output_channels,
            latency_samples: raw.latency_samples,
        })
    }

    /// Return the number of parameters the plugin exposes.
    pub fn param_count(&self) -> u32 {
        unsafe { ffi::zph_get_param_count(self.ptr) }
    }

    /// Retrieve metadata for all parameters.
    pub fn get_params(&self) -> Vec<ParamInfo> {
        let count = self.param_count();
        let mut params = Vec::with_capacity(count as usize);
        for i in 0..count {
            let mut raw = ffi::ZphParamInfo::default();
            if unsafe { ffi::zph_get_param_info(self.ptr, i, &mut raw) } {
                params.push(ParamInfo {
                    id: raw.id,
                    name: cstr_bytes_to_string(&raw.name),
                    module: cstr_bytes_to_string(&raw.module),
                    min_value: raw.min_value,
                    max_value: raw.max_value,
                    default_value: raw.default_value,
                    flags: raw.flags,
                });
            }
        }
        params
    }

    /// Get the current value of a parameter by its stable ID.
    pub fn get_param_value(&self, param_id: u32) -> Option<f64> {
        let mut value: f64 = 0.0;
        let ok = unsafe { ffi::zph_get_param_value(self.ptr, param_id, &mut value) };
        if ok { Some(value) } else { None }
    }

    /// Queue a parameter change to be applied on the next process call.
    /// Thread-safe; may be called from any thread.
    pub fn set_param_value(&self, param_id: u32, value: f64) {
        unsafe { ffi::zph_set_param_value(self.ptr, param_id, value) };
    }

    /// Handle deferred plugin callbacks. Call periodically from the main thread.
    pub fn idle(&mut self) {
        unsafe { ffi::zph_idle(self.ptr) };
    }

    /// Return the raw pointer for passing to the engine.
    pub fn raw_ptr(&mut self) -> *mut ffi::ZphPlugin {
        self.ptr
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn path_to_cstring(path: &Path) -> Result<CString> {
    let s = path
        .to_str()
        .ok_or_else(|| anyhow!("path is not valid UTF-8: {:?}", path))?;
    CString::new(s).map_err(|e| anyhow!("path contains null byte: {e}"))
}

fn cstr_ptr_to_string(ptr: *const std::ffi::c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

fn cstr_bytes_to_string(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}
