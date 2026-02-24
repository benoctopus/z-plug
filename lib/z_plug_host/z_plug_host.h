/*
 * z_plug_host.h — C API for the z_plug_host CLAP plugin host library.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Usage:
 *   1. Link against libz_plug_host.a
 *   2. #include "z_plug_host.h"
 *   3. Call zph_load_plugin() to load a .clap file
 *   4. Call zph_activate() then zph_start_processing()
 *   5. Call zph_process() in your audio loop
 *   6. Call zph_idle() periodically from the main thread
 *   7. Call zph_stop_processing(), zph_deactivate(), zph_destroy() to clean up
 */

#ifndef Z_PLUG_HOST_H
#define Z_PLUG_HOST_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * Opaque plugin handle
 * ---------------------------------------------------------------------- */

/** Opaque handle representing a loaded CLAP plugin instance. */
typedef struct ZphPlugin ZphPlugin;

/* -------------------------------------------------------------------------
 * Process status (mirrors clap_process_status)
 * ---------------------------------------------------------------------- */

typedef enum {
    ZPH_PROCESS_ERROR               = 0,
    ZPH_PROCESS_CONTINUE            = 1,
    ZPH_PROCESS_CONTINUE_IF_NOT_QUIET = 2,
    ZPH_PROCESS_TAIL                = 3,
    ZPH_PROCESS_SLEEP               = 4,
} ZphProcessStatus;

/* -------------------------------------------------------------------------
 * Plugin info
 * ---------------------------------------------------------------------- */

/**
 * Plugin metadata. String pointers are owned by the plugin and remain valid
 * for the lifetime of the ZphPlugin handle.
 */
typedef struct {
    const char* id;
    const char* name;
    const char* vendor;
    const char* version;
    const char* description;
    uint32_t    input_channels;
    uint32_t    output_channels;
    uint32_t    latency_samples;
} ZphPluginInfo;

/* -------------------------------------------------------------------------
 * Parameter info
 * ---------------------------------------------------------------------- */

/**
 * Parameter metadata. `name` and `module` are null-terminated strings stored
 * inline in the struct (not pointers into plugin memory).
 */
typedef struct {
    uint32_t id;
    char     name[256];
    char     module[1024];
    double   min_value;
    double   max_value;
    double   default_value;
    uint32_t flags;
} ZphParamInfo;

/* -------------------------------------------------------------------------
 * Lifecycle
 * ---------------------------------------------------------------------- */

/**
 * Load a .clap file and instantiate a plugin.
 *
 * @param path      Null-terminated path to the .clap file or bundle.
 * @param plugin_id Null-terminated plugin ID (e.g. "com.example.myplugin"),
 *                  or NULL to load the first available plugin.
 * @return          Opaque plugin handle, or NULL on failure.
 *
 * Internally calls entry.init() and plugin.init(). The returned plugin is in
 * the "initialized" state and ready for zph_activate().
 *
 * [main-thread]
 */
ZphPlugin* zph_load_plugin(const char* path, const char* plugin_id);

/**
 * Destroy a plugin handle and free all resources.
 *
 * Automatically stops processing and deactivates if needed.
 * The handle must not be used after this call.
 *
 * [main-thread]
 */
void zph_destroy(ZphPlugin* plugin);

/**
 * Activate the plugin for audio processing.
 *
 * Must be called before zph_start_processing(). The plugin may allocate
 * memory and prepare DSP state during this call.
 *
 * @param sample_rate  Output sample rate in Hz.
 * @param max_frames   Maximum number of frames per process() call.
 * @return             true on success.
 *
 * [main-thread]
 */
bool zph_activate(ZphPlugin* plugin, double sample_rate, uint32_t max_frames);

/**
 * Deactivate the plugin. Stops processing if currently running.
 *
 * [main-thread]
 */
void zph_deactivate(ZphPlugin* plugin);

/**
 * Start the audio processing state.
 *
 * Must be called from the audio thread after zph_activate().
 * After this call, zph_process() may be called.
 *
 * @return true on success.
 *
 * [audio-thread]
 */
bool zph_start_processing(ZphPlugin* plugin);

/**
 * Stop the audio processing state.
 *
 * Must be called from the audio thread.
 *
 * [audio-thread]
 */
void zph_stop_processing(ZphPlugin* plugin);

/* -------------------------------------------------------------------------
 * Audio processing
 * ---------------------------------------------------------------------- */

/**
 * Process one block of audio through the plugin.
 *
 * @param inputs        Array of `channel_count` non-interleaved input channel
 *                      buffers, each containing `frame_count` f32 samples.
 * @param outputs       Array of `channel_count` non-interleaved output channel
 *                      buffers, each containing `frame_count` f32 samples.
 * @param channel_count Number of audio channels.
 * @param frame_count   Number of frames to process.
 * @return              Process status.
 *
 * Any parameter changes queued via zph_set_param_value() are applied at
 * sample offset 0 of this block.
 *
 * [audio-thread]
 */
ZphProcessStatus zph_process(
    ZphPlugin*            plugin,
    const float* const*   inputs,
    float* const*         outputs,
    uint32_t              channel_count,
    uint32_t              frame_count
);

/* -------------------------------------------------------------------------
 * Plugin info
 * ---------------------------------------------------------------------- */

/**
 * Fill `out` with plugin metadata.
 *
 * @return true on success.
 *
 * [main-thread]
 */
bool zph_get_plugin_info(const ZphPlugin* plugin, ZphPluginInfo* out);

/* -------------------------------------------------------------------------
 * Parameters
 * ---------------------------------------------------------------------- */

/**
 * Return the number of parameters the plugin exposes.
 *
 * [main-thread]
 */
uint32_t zph_get_param_count(const ZphPlugin* plugin);

/**
 * Fill `out` with info about the parameter at `index`.
 *
 * @return true on success.
 *
 * [main-thread]
 */
bool zph_get_param_info(const ZphPlugin* plugin, uint32_t index, ZphParamInfo* out);

/**
 * Get the current value of a parameter by its stable ID.
 *
 * @param param_id  Stable parameter ID (from ZphParamInfo.id).
 * @param out       Receives the current value.
 * @return          true on success.
 *
 * [main-thread]
 */
bool zph_get_param_value(const ZphPlugin* plugin, uint32_t param_id, double* out);

/**
 * Queue a parameter change to be applied on the next zph_process() call.
 *
 * Thread-safe; may be called from any thread.
 */
void zph_set_param_value(ZphPlugin* plugin, uint32_t param_id, double value);

/* -------------------------------------------------------------------------
 * State persistence
 * ---------------------------------------------------------------------- */

/**
 * Save plugin state into `buffer`.
 *
 * To query the required buffer size, call with buffer=NULL and *size=0.
 * The function sets *size to the required byte count and returns false.
 * On success, sets *size to the number of bytes written and returns true.
 *
 * @param buffer  Destination buffer, or NULL to query size.
 * @param size    In/out: capacity on entry, bytes written on success.
 * @return        true if state was written successfully.
 *
 * [main-thread]
 */
bool zph_save_state(const ZphPlugin* plugin, uint8_t* buffer, uint32_t* size);

/**
 * Load plugin state from `buffer[0..size]`.
 *
 * @return true on success.
 *
 * [main-thread]
 */
bool zph_load_state(ZphPlugin* plugin, const uint8_t* buffer, uint32_t size);

/* -------------------------------------------------------------------------
 * Main-thread idle
 * ---------------------------------------------------------------------- */

/**
 * Handle deferred plugin callbacks.
 *
 * Must be called periodically from the main thread. Handles:
 *   - plugin->on_main_thread() requests
 *   - request_restart (deactivates the plugin; caller must re-activate)
 *   - parameter flush requests
 *   - latency change notifications
 *
 * [main-thread]
 */
void zph_idle(ZphPlugin* plugin);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* Z_PLUG_HOST_H */
