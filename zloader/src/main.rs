//! zloader — CLAP plugin debug/test tool.
//!
//! Usage:
//!   zloader <plugin.clap> <audio.wav>

mod app;
mod engine;
mod ffi;
mod host;
mod params;
mod transport;
mod waveform;

use std::path::PathBuf;

use anyhow::Result;
use clap::Parser;
use gpui::{prelude::*, px, size, App, Application, Bounds, WindowBounds, WindowOptions};
use gpui_component::{theme::Theme, Root};

use app::{AppState, ZLoaderApp};
use engine::AudioEngine;
use host::PluginHost;
use waveform::WaveformPeaks;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

#[derive(Parser, Debug)]
#[command(name = "zloader", about = "CLAP plugin debug/test tool")]
struct Args {
    /// Path to the .clap plugin file or bundle.
    plugin_path: PathBuf,

    /// Path to a WAV audio file to play through the plugin.
    audio_file: PathBuf,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() -> Result<()> {
    let args = Args::parse();

    if !args.plugin_path.exists() {
        anyhow::bail!("Plugin not found: {:?}", args.plugin_path);
    }
    if !args.audio_file.exists() {
        anyhow::bail!("Audio file not found: {:?}", args.audio_file);
    }

    let plugin_path = args.plugin_path.clone();
    let audio_path = args.audio_file.clone();

    Application::new().run(move |cx: &mut App| {
        // Load embedded Inter Variable font so text renders on all platforms.
        // The system font (.SystemUIFont / .AppleSystemUIFont) fails to rasterize
        // glyphs via GPUI's sprite atlas on some macOS configurations.

        // Initialize gpui-component theming and force dark mode to match our dark UI.
        gpui_component::init(cx);

        // Load plugin and audio on the main thread (FFI is not Send).
        let (state_entity, peaks) = match setup(cx, &plugin_path, &audio_path) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("Error: {e:#}");
                cx.quit();
                return;
            }
        };

        let bounds = Bounds::centered(None, size(px(900.0), px(600.0)), cx);

        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(gpui::TitlebarOptions {
                    title: Some("zloader".into()),
                    ..Default::default()
                }),
                ..Default::default()
            },
            move |window, cx| {
                let app_view = cx.new(|cx| ZLoaderApp::new(state_entity, peaks, cx));
                cx.new(|cx| Root::new(gpui::AnyView::from(app_view), window, cx))
            },
        )
        .expect("failed to open window");

        cx.activate(true);
    });

    Ok(())
}

// ---------------------------------------------------------------------------
// Setup: load plugin + audio, build peak data
// ---------------------------------------------------------------------------

const SAMPLE_RATE: f64 = 44100.0;
const BUFFER_SIZE: u32 = 512;
/// Number of waveform display columns (pre-computed peak resolution).
const WAVEFORM_COLUMNS: usize = 1200;

fn setup(
    cx: &mut App,
    plugin_path: &PathBuf,
    audio_path: &PathBuf,
) -> Result<(gpui::Entity<AppState>, WaveformPeaks)> {
    // Load the plugin.
    let mut host = PluginHost::load(plugin_path, None)?;
    let plugin_info = host.get_info()?;
    let params = host.get_params();

    // Create the audio engine and load the WAV file.
    let mut engine = AudioEngine::new(SAMPLE_RATE, BUFFER_SIZE)?;
    engine.load_file(audio_path)?;

    // Activate and start processing.
    host.activate(SAMPLE_RATE, BUFFER_SIZE)?;
    host.start_processing()?;

    // Attach plugin to engine.
    engine.set_plugin(Some(&mut host));

    // Read the WAV file for waveform peak computation.
    let peaks = build_peaks(audio_path)?;

    let state = cx.new(|_cx| AppState {
        host,
        engine,
        plugin_info,
        params,
    });

    Ok((state, peaks))
}

/// Read the WAV file and compute waveform peaks for display.
fn build_peaks(path: &PathBuf) -> Result<WaveformPeaks> {
    let data = std::fs::read(path)?;
    let (samples, channels) = parse_wav_samples(&data)?;
    let peaks = WaveformPeaks::from_samples(&samples, channels, WAVEFORM_COLUMNS);
    Ok(peaks)
}

/// Minimal WAV parser that extracts f32 samples from PCM/float WAV files.
/// Returns (interleaved_f32_samples, channel_count).
fn parse_wav_samples(data: &[u8]) -> Result<(Vec<f32>, usize)> {
    if data.len() < 44 {
        anyhow::bail!("WAV file too small");
    }

    if &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        anyhow::bail!("Not a valid RIFF/WAVE file");
    }

    let mut pos = 12usize;
    let mut fmt_channels: u16 = 0;
    let mut fmt_bits: u16 = 0;
    let mut fmt_audio_format: u16 = 0;
    let mut data_start = 0usize;
    let mut data_len = 0usize;

    while pos + 8 <= data.len() {
        let chunk_id = &data[pos..pos + 4];
        let chunk_size = u32::from_le_bytes(data[pos + 4..pos + 8].try_into()?) as usize;
        pos += 8;

        if chunk_id == b"fmt " {
            if chunk_size >= 16 {
                fmt_audio_format = u16::from_le_bytes(data[pos..pos + 2].try_into()?);
                fmt_channels = u16::from_le_bytes(data[pos + 2..pos + 4].try_into()?);
                fmt_bits = u16::from_le_bytes(data[pos + 14..pos + 16].try_into()?);
            }
        } else if chunk_id == b"data" {
            data_start = pos;
            data_len = chunk_size;
            break;
        }

        pos += chunk_size;
        if chunk_size % 2 != 0 {
            pos += 1;
        }
    }

    if data_start == 0 || fmt_channels == 0 {
        anyhow::bail!("Could not find fmt/data chunks in WAV file");
    }

    let raw = &data[data_start..data_start.saturating_add(data_len).min(data.len())];
    let channels = fmt_channels as usize;

    let samples: Vec<f32> = match (fmt_audio_format, fmt_bits) {
        (3, 32) => raw
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
            .collect(),
        (1, 16) => raw
            .chunks_exact(2)
            .map(|b| {
                let s = i16::from_le_bytes(b.try_into().unwrap());
                s as f32 / 32768.0
            })
            .collect(),
        (1, 24) => raw
            .chunks_exact(3)
            .map(|b| {
                let s = i32::from_le_bytes([b[0], b[1], b[2], 0]) >> 8;
                s as f32 / 8388608.0
            })
            .collect(),
        (1, 32) => raw
            .chunks_exact(4)
            .map(|b| {
                let s = i32::from_le_bytes(b.try_into().unwrap());
                s as f32 / 2147483648.0
            })
            .collect(),
        _ => anyhow::bail!(
            "Unsupported WAV format: audio_format={fmt_audio_format}, bits={fmt_bits}"
        ),
    };

    Ok((samples, channels))
}
