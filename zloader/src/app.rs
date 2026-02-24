//! Root GPUI view for zloader.
//!
//! `ZLoaderApp` owns the plugin host and audio engine, lays out the UI,
//! and drives the periodic idle/position-poll timer.

use std::time::Duration;

use gpui::{div, prelude::*, px, rgb, Entity, IntoElement, SharedString, Window};
use gpui_component::button::{Button, ButtonVariants};
use gpui_component::slider::SliderEvent;

use crate::engine::AudioEngine;
use crate::host::{ParamInfo, PluginHost, PluginInfo};
use crate::params::ParamsView;
use crate::waveform::{WaveformPeaks, WaveformView};

// ---------------------------------------------------------------------------
// AppState — owns the non-Send FFI resources
// ---------------------------------------------------------------------------

/// Owns the FFI resources. Kept in a GPUI entity so it lives on the main thread.
pub struct AppState {
    pub host: PluginHost,
    pub engine: AudioEngine,
    pub plugin_info: PluginInfo,
    pub params: Vec<ParamInfo>,
}

// ---------------------------------------------------------------------------
// ZLoaderApp — root view
// ---------------------------------------------------------------------------

pub struct ZLoaderApp {
    state: Entity<AppState>,
    waveform: Entity<WaveformView>,
    params_view: Entity<ParamsView>,
    is_playing: bool,
    plugin_name: SharedString,
}

impl ZLoaderApp {
    pub fn new(
        state: Entity<AppState>,
        peaks: WaveformPeaks,
        cx: &mut gpui::Context<Self>,
    ) -> Self {
        let plugin_name: SharedString = state
            .read_with(cx, |s, _| s.plugin_info.name.clone())
            .into();

        let params = state.read_with(cx, |s, _| s.params.clone());

        // Build the waveform view.
        let waveform = cx.new(|_cx| WaveformView::new(peaks));

        // Build the params view.
        let params_view = cx.new(|cx| ParamsView::new(&params, cx));

        // Subscribe to slider changes and forward to the plugin host.
        // This runs on the main thread with full access to cx.
        let state_for_params = state.clone();
        params_view
            .read_with(cx, |pv, _| {
                // Collect slider entities to subscribe to them from the parent cx.
                pv.sliders
                    .iter()
                    .map(|s| (s.info.id, s.slider.clone()))
                    .collect::<Vec<_>>()
            })
            .into_iter()
            .for_each(|(param_id, slider_entity)| {
                let state_weak = state_for_params.downgrade();
                cx.subscribe(
                    &slider_entity,
                    move |_this, _slider, event: &SliderEvent, cx| {
                        let SliderEvent::Change(value) = event;
                        let v = value.start() as f64;
                        if let Some(state_entity) = state_weak.upgrade() {
                            state_entity.read_with(cx, |s, _| {
                                s.host.set_param_value(param_id, v);
                            });
                        }
                    },
                )
                .detach();
            });

        // Spawn a repeating timer to poll playback position and call idle.
        let state_weak = state.downgrade();
        let waveform_weak = waveform.downgrade();
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(30))
                    .await;

                let should_stop = cx.update(|cx| {
                    let Some(state_entity) = state_weak.upgrade() else {
                        return true;
                    };
                    let Some(waveform_entity) = waveform_weak.upgrade() else {
                        return true;
                    };

                    // Poll position and call idle.
                    let (position, is_playing) = state_entity.update(cx, |s, _cx| {
                        s.host.idle();
                        (s.engine.position(), s.engine.is_playing())
                    });

                    // Update waveform playhead.
                    waveform_entity.update(cx, |w, cx| {
                        w.position = position;
                        cx.notify();
                    });

                    // Update root view playing state.
                    this.update(cx, |app, cx| {
                        app.is_playing = is_playing;
                        cx.notify();
                    })
                    .is_err()
                });

                if should_stop.unwrap_or(true) {
                    break;
                }
            }
        })
        .detach();

        Self {
            state,
            waveform,
            params_view,
            is_playing: false,
            plugin_name,
        }
    }

    fn on_rewind(&mut self, _window: &mut Window, cx: &mut gpui::Context<Self>) {
        self.state.update(cx, |s, _cx| {
            s.engine.seek(0);
        });
        self.waveform.update(cx, |w, cx| {
            w.position = 0;
            cx.notify();
        });
        cx.notify();
    }

    fn on_play_stop(&mut self, _window: &mut Window, cx: &mut gpui::Context<Self>) {
        let is_playing = self.state.read_with(cx, |s, _| s.engine.is_playing());
        self.state.update(cx, |s, _cx| {
            if is_playing {
                s.engine.stop();
            } else {
                let _ = s.engine.play();
            }
        });
        self.is_playing = !is_playing;
        cx.notify();
    }
}

impl Render for ZLoaderApp {
    fn render(&mut self, window: &mut Window, cx: &mut gpui::Context<Self>) -> impl IntoElement {
        let play_label: SharedString = if self.is_playing {
            "Stop".into()
        } else {
            "Play".into()
        };
        let plugin_name = self.plugin_name.clone();
        let waveform = self.waveform.clone();
        let params_view = self.params_view.clone();

        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(0x0f0f1a))
            .text_color(rgb(0xffffff))
            .p(px(16.0))
            .gap(px(16.0))
            // Header: plugin name
            .child(
                div().flex().flex_row().items_center().gap(px(8.0)).child(
                    div()
                        .text_size(px(20.0))
                        .size_full()
                        .bg(rgb(0x0000FF))
                        .text_color(rgb(0xffffff))
                        .child("test".clone()),
                ),
            )
            // Waveform
            .child(waveform)
            // Bottom: transport + params
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap(px(24.0))
                    .flex_1()
                    .min_h(px(0.0))
                    // Transport controls
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(8.0))
                            .w(px(120.0))
                            .flex_shrink_0()
                            .child(div().text_sm().text_color(rgb(0x888888)).child("Transport"))
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .gap(px(8.0))
                                    .child(Button::new("rewind").label("<<").on_click(cx.listener(
                                        |app, _ev, window, cx| {
                                            app.on_rewind(window, cx);
                                        },
                                    )))
                                    .child(
                                        Button::new("play_stop")
                                            .primary()
                                            .label(play_label)
                                            .on_click(cx.listener(|app, _ev, window, cx| {
                                                app.on_play_stop(window, cx);
                                            })),
                                    ),
                            ),
                    )
                    // Parameter panel
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .flex_1()
                            .min_h(px(0.0))
                            .gap(px(8.0))
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(rgb(0x888888))
                                    .child("Parameters"),
                            )
                            .child(params_view),
                    ),
            )
    }
}
