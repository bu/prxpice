#ifndef SPICE_BRIDGE_H
#define SPICE_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle for a SPICE session
typedef struct SpiceBridgeSession SpiceBridgeSession;

// Connection state
typedef enum {
    SPICE_BRIDGE_STATE_DISCONNECTED = 0,
    SPICE_BRIDGE_STATE_CONNECTING,
    SPICE_BRIDGE_STATE_CONNECTED,
    SPICE_BRIDGE_STATE_DISCONNECTING,
    SPICE_BRIDGE_STATE_ERROR
} SpiceBridgeState;

// Mouse button mask (matches SPICE protocol)
typedef enum {
    SPICE_BRIDGE_MOUSE_BUTTON_LEFT   = (1 << 0),
    SPICE_BRIDGE_MOUSE_BUTTON_MIDDLE = (1 << 1),
    SPICE_BRIDGE_MOUSE_BUTTON_RIGHT  = (1 << 2),
    SPICE_BRIDGE_MOUSE_BUTTON_UP     = (1 << 3),
    SPICE_BRIDGE_MOUSE_BUTTON_DOWN   = (1 << 4)
} SpiceBridgeMouseButton;

// Display surface info passed to Swift
typedef struct {
    int32_t surface_id;
    int32_t width;
    int32_t height;
    int32_t stride;
    uint32_t format; // pixel format (BGRA)
    const uint8_t *data;
} SpiceBridgeSurface;

// Dirty rect for partial display updates
typedef struct {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
} SpiceBridgeRect;

// Callback types - Swift sets these function pointers
typedef void (*SpiceBridgeStateCallback)(void *context, SpiceBridgeState state);
typedef void (*SpiceBridgeDisplayCreateCallback)(void *context, const SpiceBridgeSurface *surface);
typedef void (*SpiceBridgeDisplayInvalidateCallback)(void *context, int32_t surface_id, const SpiceBridgeRect *rect, const uint8_t *data, int32_t stride);
typedef void (*SpiceBridgeDisplayDestroyCallback)(void *context, int32_t surface_id);
typedef void (*SpiceBridgeCursorSetCallback)(void *context, int32_t width, int32_t height, int32_t hot_x, int32_t hot_y, const uint8_t *data);
typedef void (*SpiceBridgeCursorMoveCallback)(void *context, int32_t x, int32_t y);
typedef void (*SpiceBridgeDebugCallback)(void *context, const char *message);

// Audio playback callbacks (VM → client, PCM S16 interleaved)
typedef void (*SpiceBridgePlaybackStartCallback)(void *context, int32_t channels, int32_t freq);
typedef void (*SpiceBridgePlaybackDataCallback)(void *context, const uint8_t *data, int32_t size);
typedef void (*SpiceBridgePlaybackStopCallback)(void *context);

// Audio record callbacks (client mic → VM)
typedef void (*SpiceBridgeRecordStartCallback)(void *context, int32_t channels, int32_t freq);
typedef void (*SpiceBridgeRecordStopCallback)(void *context);

// Callbacks configuration struct
typedef struct {
    void *context; // Opaque pointer to Swift object (Unmanaged<T>.toOpaque())

    SpiceBridgeStateCallback on_state_changed;
    SpiceBridgeDisplayCreateCallback on_display_create;
    SpiceBridgeDisplayInvalidateCallback on_display_invalidate;
    SpiceBridgeDisplayDestroyCallback on_display_destroy;
    SpiceBridgeCursorSetCallback on_cursor_set;
    SpiceBridgeCursorMoveCallback on_cursor_move;
    SpiceBridgeDebugCallback on_debug;

    SpiceBridgePlaybackStartCallback on_playback_start;
    SpiceBridgePlaybackDataCallback  on_playback_data;
    SpiceBridgePlaybackStopCallback  on_playback_stop;
    SpiceBridgeRecordStartCallback   on_record_start;
    SpiceBridgeRecordStopCallback    on_record_stop;
} SpiceBridgeCallbacks;

// Session lifecycle
SpiceBridgeSession *spice_bridge_session_new(const SpiceBridgeCallbacks *callbacks);
void spice_bridge_session_free(SpiceBridgeSession *session);

// Connection management
bool spice_bridge_connect(SpiceBridgeSession *session,
                          const char *host,
                          int port,
                          int tls_port,
                          const char *password,
                          const char *ca_cert,
                          const char *host_subject,
                          const char *proxy);

void spice_bridge_disconnect(SpiceBridgeSession *session);

SpiceBridgeState spice_bridge_get_state(const SpiceBridgeSession *session);

// Input - keyboard
void spice_bridge_key_press(SpiceBridgeSession *session, uint32_t scancode);
void spice_bridge_key_release(SpiceBridgeSession *session, uint32_t scancode);

// Input - mouse (absolute positioning mode)
void spice_bridge_mouse_position(SpiceBridgeSession *session,
                                  int32_t x, int32_t y,
                                  int32_t display_id,
                                  uint32_t button_mask);

// Input - mouse (relative motion mode)
void spice_bridge_mouse_motion(SpiceBridgeSession *session,
                                int32_t dx, int32_t dy,
                                uint32_t button_mask);

// Input - mouse button press/release
void spice_bridge_mouse_button_press(SpiceBridgeSession *session,
                                      uint32_t button,
                                      uint32_t button_mask);

void spice_bridge_mouse_button_release(SpiceBridgeSession *session,
                                        uint32_t button,
                                        uint32_t button_mask);

// GLib main loop management
// Call from a dedicated pthread to run the GLib event loop
void spice_bridge_run_loop(SpiceBridgeSession *session);

// Signal the GLib main loop to quit (thread-safe)
void spice_bridge_quit_loop(SpiceBridgeSession *session);

// Send mic audio data to the VM (call from record tap; time_ms = ms since record-start)
void spice_bridge_record_send_data(SpiceBridgeSession *session,
                                    const uint8_t *data,
                                    size_t size,
                                    uint32_t time_ms);

// Query display info
bool spice_bridge_get_display_info(const SpiceBridgeSession *session,
                                    int32_t *out_width,
                                    int32_t *out_height);

#ifdef __cplusplus
}
#endif

#endif /* SPICE_BRIDGE_H */
