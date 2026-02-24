/*
 * z_plug_engine.h — C API for the z_plug_engine audio engine library.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * macOS only. Requires linking against:
 *   libz_plug_engine.a  libz_plug_host.a
 *   -framework AudioToolbox  -framework CoreAudio
 *
 * Usage:
 *   1. Load a plugin with z_plug_host: plugin = zph_load_plugin(...)
 *   2. Create an engine: engine = zpe_create(44100.0, 512)
 *   3. Load a WAV file: zpe_load_file(engine, "audio.wav")
 *   4. Attach plugin: zpe_set_plugin(engine, plugin)
 *   5. Activate plugin: zph_activate(plugin, 44100.0, 512)
 *   6. Start plugin processing: zph_start_processing(plugin)
 *   7. Play: zpe_play(engine)
 *   8. Poll position: zpe_get_position(engine)
 *   9. Cleanup: zpe_stop, zph_stop_processing, zph_deactivate, zpe_destroy, zph_destroy
 */

#ifndef Z_PLUG_ENGINE_H
#define Z_PLUG_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

/* Include z_plug_host for the ZphPlugin type */
#include "z_plug_host.h"

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * Opaque engine handle
 * ---------------------------------------------------------------------- */

/** Opaque handle representing an audio engine instance. */
typedef struct ZpeEngine ZpeEngine;

/* -------------------------------------------------------------------------
 * Lifecycle
 * ---------------------------------------------------------------------- */

/**
 * Create a new audio engine.
 *
 * @param sample_rate  Output sample rate in Hz. Pass 0 to use 44100 Hz.
 * @param buffer_size  Frames per audio callback. Pass 0 to use 512 frames.
 * @return             Opaque engine handle, or NULL on allocation failure.
 */
ZpeEngine* zpe_create(double sample_rate, uint32_t buffer_size);

/**
 * Destroy the engine and free all resources.
 *
 * Stops playback if running. Does NOT destroy any attached ZphPlugin.
 */
void zpe_destroy(ZpeEngine* engine);

/* -------------------------------------------------------------------------
 * File loading
 * ---------------------------------------------------------------------- */

/**
 * Load a WAV file for playback.
 *
 * Supported formats: PCM 16/24/32-bit integer, IEEE float 32-bit.
 * Stops playback and resets position if a file was already loaded.
 *
 * @param path  Null-terminated path to a .wav file.
 * @return      true on success.
 */
bool zpe_load_file(ZpeEngine* engine, const char* path);

/* -------------------------------------------------------------------------
 * Plugin attachment
 * ---------------------------------------------------------------------- */

/**
 * Attach a CLAP plugin to the engine.
 *
 * Audio from the loaded WAV file will be routed through the plugin before
 * output. The caller retains ownership of the plugin handle.
 *
 * Pass NULL to detach and use passthrough mode (WAV → output directly).
 *
 * The plugin must be activated and processing-started before calling
 * zpe_play(). The engine calls zph_process() from its audio callback thread.
 */
void zpe_set_plugin(ZpeEngine* engine, ZphPlugin* plugin);

/* -------------------------------------------------------------------------
 * Playback controls
 * ---------------------------------------------------------------------- */

/**
 * Start playback.
 *
 * Creates the CoreAudio AudioQueue if not already created.
 * Returns false if no file is loaded or audio initialization fails.
 */
bool zpe_play(ZpeEngine* engine);

/**
 * Pause playback. The current position is preserved.
 */
void zpe_pause(ZpeEngine* engine);

/**
 * Stop playback and reset position to 0.
 */
void zpe_stop(ZpeEngine* engine);

/**
 * Seek to a specific sample position.
 *
 * Thread-safe; may be called while playing.
 */
void zpe_seek(ZpeEngine* engine, uint64_t sample_position);

/* -------------------------------------------------------------------------
 * State queries
 * ---------------------------------------------------------------------- */

/** Return the current playback position in samples. */
uint64_t zpe_get_position(const ZpeEngine* engine);

/** Return the total length of the loaded file in samples. Returns 0 if no
 *  file is loaded. */
uint64_t zpe_get_length(const ZpeEngine* engine);

/** Return the engine's output sample rate in Hz. */
double zpe_get_sample_rate(const ZpeEngine* engine);

/** Return the channel count of the loaded file. Returns 0 if no file loaded. */
uint32_t zpe_get_channel_count(const ZpeEngine* engine);

/** Return true if the engine is currently playing. */
bool zpe_is_playing(const ZpeEngine* engine);

/* -------------------------------------------------------------------------
 * Looping
 * ---------------------------------------------------------------------- */

/**
 * Enable or disable looping.
 *
 * When enabled, playback restarts from the beginning when the end of the
 * file is reached.
 */
void zpe_set_looping(ZpeEngine* engine, bool loop);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* Z_PLUG_ENGINE_H */
