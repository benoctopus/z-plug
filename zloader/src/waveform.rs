//! Waveform display using GPUI's `canvas()` element.
//!
//! Renders a pre-computed peak overview of the loaded audio file, with a
//! playhead line indicating the current playback position. Clicking or
//! dragging on the waveform emits a [`WaveformEvent::Seek`] event with the
//! target sample position.

use gpui::{
    canvas, div, prelude::*, px, rgb, Background, BorderStyle, Bounds, Corners, Edges, Hsla,
    IntoElement, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, PaintQuad, Pixels,
    Point, Size, Window,
};

// ---------------------------------------------------------------------------
// Peak data
// ---------------------------------------------------------------------------

/// Pre-computed min/max peak pairs for waveform rendering.
/// One entry per display column (pixel-width bucket).
#[derive(Clone)]
pub struct WaveformPeaks {
    /// (min, max) pairs in [-1.0, 1.0], one per display column.
    pub peaks: Vec<(f32, f32)>,
    /// Total number of samples in the source file (for playhead math).
    pub total_samples: u64,
}

impl WaveformPeaks {
    /// Build peak data from raw interleaved f32 samples.
    ///
    /// `num_columns` is the target display width in pixels. The samples are
    /// divided into that many equal-sized buckets; min/max are computed per
    /// bucket across all channels.
    pub fn from_samples(samples: &[f32], channels: usize, num_columns: usize) -> Self {
        let total_frames = if channels > 0 {
            samples.len() / channels
        } else {
            0
        };

        let total_samples = total_frames as u64;

        if total_frames == 0 || num_columns == 0 {
            return Self {
                peaks: vec![(0.0, 0.0); num_columns.max(1)],
                total_samples,
            };
        }

        let frames_per_col = (total_frames as f64 / num_columns as f64).max(1.0);
        let mut peaks = Vec::with_capacity(num_columns);

        for col in 0..num_columns {
            let start_frame = (col as f64 * frames_per_col) as usize;
            let end_frame = ((col + 1) as f64 * frames_per_col) as usize;
            let end_frame = end_frame.min(total_frames);

            let mut min = 0.0f32;
            let mut max = 0.0f32;

            for frame in start_frame..end_frame {
                for ch in 0..channels {
                    let sample = samples[frame * channels + ch];
                    if sample < min {
                        min = sample;
                    }
                    if sample > max {
                        max = sample;
                    }
                }
            }

            peaks.push((min, max));
        }

        Self {
            peaks,
            total_samples,
        }
    }
}

// ---------------------------------------------------------------------------
// WaveformEvent
// ---------------------------------------------------------------------------

/// Events emitted by [`WaveformView`].
pub enum WaveformEvent {
    /// The user scrubbed to a new position; value is the target sample index.
    Seek(u64),
}

// ---------------------------------------------------------------------------
// WaveformView
// ---------------------------------------------------------------------------

/// A GPUI view that renders the waveform and a playhead.
pub struct WaveformView {
    pub peaks: WaveformPeaks,
    /// Current playback position in samples (updated by the app timer).
    pub position: u64,
    /// True while the left mouse button is held down on the waveform.
    pub dragging: bool,
    /// Last-known canvas bounds, used to convert mouse X to a sample position.
    bounds: Bounds<Pixels>,
}

impl gpui::EventEmitter<WaveformEvent> for WaveformView {}

impl WaveformView {
    pub fn new(peaks: WaveformPeaks) -> Self {
        Self {
            peaks,
            position: 0,
            dragging: false,
            bounds: Bounds::default(),
        }
    }

    /// Convert a window-space mouse position to a sample index.
    fn sample_from_mouse(&self, mouse_position: Point<Pixels>) -> u64 {
        let x = f32::from(mouse_position.x) - f32::from(self.bounds.origin.x);
        let width = f32::from(self.bounds.size.width);
        if width <= 0.0 || self.peaks.total_samples == 0 {
            return 0;
        }
        let progress = (x / width).clamp(0.0, 1.0);
        (progress as f64 * self.peaks.total_samples as f64) as u64
    }
}

impl Render for WaveformView {
    fn render(&mut self, _window: &mut Window, cx: &mut gpui::Context<Self>) -> impl IntoElement {
        let peaks = self.peaks.clone();
        let position = self.position;
        let weak = cx.weak_entity();

        div()
            .w_full()
            .h(px(120.0))
            .bg(rgb(0x1a1a2e))
            .rounded(px(6.0))
            .overflow_hidden()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, _window, cx| {
                    this.dragging = true;
                    this.position = this.sample_from_mouse(event.position);
                    cx.emit(WaveformEvent::Seek(this.position));
                    cx.notify();
                }),
            )
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _window, cx| {
                if event.dragging() {
                    this.position = this.sample_from_mouse(event.position);
                    cx.emit(WaveformEvent::Seek(this.position));
                    cx.notify();
                }
            }))
            .capture_any_mouse_up(cx.listener(|this, _event: &MouseUpEvent, _window, _cx| {
                this.dragging = false;
            }))
            .child(
                canvas(
                    move |bounds, _window, cx| {
                        if let Some(entity) = weak.upgrade() {
                            entity.update(cx, |view, _cx| {
                                view.bounds = bounds;
                            });
                        }
                    },
                    move |bounds, _prepaint, window, _cx| {
                        draw_waveform(window, bounds, &peaks, position);
                    },
                )
                .w_full()
                .h_full(),
            )
    }
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

fn paint_rect(window: &mut Window, x: f32, y: f32, w: f32, h: f32, color: Hsla) {
    window.paint_quad(PaintQuad {
        bounds: Bounds {
            origin: Point { x: px(x), y: px(y) },
            size: Size {
                width: px(w),
                height: px(h),
            },
        },
        corner_radii: Corners::all(px(0.0)),
        background: Background::from(color),
        border_widths: Edges::all(px(0.0)),
        border_color: gpui::transparent_black(),
        border_style: BorderStyle::default(),
    });
}

fn draw_waveform(
    window: &mut Window,
    bounds: Bounds<Pixels>,
    peaks: &WaveformPeaks,
    position: u64,
) {
    let width = f32::from(bounds.size.width);
    let height = f32::from(bounds.size.height);
    let origin_x = f32::from(bounds.origin.x);
    let origin_y = f32::from(bounds.origin.y);
    let mid_y = origin_y + height / 2.0;
    let half_h = height / 2.0 * 0.9;

    let num_cols = peaks.peaks.len().max(1);
    let waveform_color: Hsla = rgb(0x4a9eff).into();
    let center_color: Hsla = rgb(0x2a4a6e).into();
    let playhead_color: Hsla = rgb(0xffffff).into();

    // Draw waveform bars.
    for (i, &(min_val, max_val)) in peaks.peaks.iter().enumerate() {
        let x = origin_x + (i as f32 / num_cols as f32) * width;
        let bar_width = (width / num_cols as f32).max(1.0);

        let top = mid_y - max_val.abs().min(1.0) * half_h;
        let bottom = mid_y + min_val.abs().min(1.0) * half_h;
        let bar_height = (bottom - top).max(1.0);

        paint_rect(window, x, top, bar_width - 0.5, bar_height, waveform_color);
    }

    // Draw center line.
    paint_rect(window, origin_x, mid_y - 0.5, width, 1.0, center_color);

    // Draw playhead.
    if peaks.total_samples > 0 {
        let progress = position as f32 / peaks.total_samples as f32;
        let playhead_x = origin_x + progress.clamp(0.0, 1.0) * width;
        paint_rect(window, playhead_x, origin_y, 2.0, height, playhead_color);
    }
}
