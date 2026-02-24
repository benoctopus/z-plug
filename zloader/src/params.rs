//! Parameter panel: a scrollable list of labeled sliders for each plugin parameter.

use gpui::{div, prelude::*, px, rgb, Entity, IntoElement, SharedString, Window};
use gpui_component::slider::{Slider, SliderState};

use crate::host::ParamInfo;

// ---------------------------------------------------------------------------
// Per-parameter slider entry
// ---------------------------------------------------------------------------

/// Holds the GPUI entity for one parameter's slider state.
pub struct ParamSlider {
    pub info: ParamInfo,
    pub slider: Entity<SliderState>,
}

// ---------------------------------------------------------------------------
// ParamsView
// ---------------------------------------------------------------------------

/// Panel of parameter sliders.
pub struct ParamsView {
    pub sliders: Vec<ParamSlider>,
}

impl ParamsView {
    /// Build the params view from a list of parameter infos.
    pub fn new(params: &[ParamInfo], cx: &mut gpui::Context<Self>) -> Self {
        let sliders = params
            .iter()
            .map(|info| {
                let min = info.min_value as f32;
                let max = info.max_value as f32;
                let default = info.default_value as f32;

                let slider = cx.new(|_cx| {
                    SliderState::new()
                        .min(min)
                        .max(max)
                        .default_value(default)
                });

                ParamSlider {
                    info: info.clone(),
                    slider,
                }
            })
            .collect();

        Self { sliders }
    }

}

impl Render for ParamsView {
    fn render(&mut self, _window: &mut Window, _cx: &mut gpui::Context<Self>) -> impl IntoElement {
        let mut rows = div()
            .flex()
            .flex_col()
            .gap(px(12.0))
            .w_full()
            .overflow_hidden();

        for entry in &self.sliders {
            let name: SharedString = entry.info.name.clone().into();
            let slider_entity = entry.slider.clone();

            let row = div()
                .flex()
                .flex_col()
                .gap(px(4.0))
                .w_full()
                .child(
                    div()
                        .text_sm()
                        .text_color(rgb(0xcccccc))
                        .child(name),
                )
                .child(Slider::new(&slider_entity));

            rows = rows.child(row);
        }

        rows
    }
}
