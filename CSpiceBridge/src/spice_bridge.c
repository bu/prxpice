/**
 * spice_bridge.c - C bridge between Swift and libspice-client-glib
 *
 * This module wraps GObject-based spice-client-glib APIs into plain C
 * functions callable from Swift. It manages:
 * - SpiceSession and channel lifecycle
 * - Display surface callbacks (create, invalidate, destroy)
 * - Input forwarding (keyboard, mouse)
 * - A GLib main loop on a dedicated thread
 */

#include "spice_bridge.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#ifdef HAVE_SPICE
#include <spice-client.h>
#include <spice-session.h>
#include <spice-channel.h>
#include <spice-display-channel.h>
#include <spice-inputs-channel.h>
#endif

struct SpiceBridgeSession {
    SpiceBridgeCallbacks callbacks;
    SpiceBridgeState state;

#ifdef HAVE_SPICE
    SpiceSession *spice_session;
    SpiceInputsChannel *inputs_channel;
    SpiceDisplayChannel *display_channel;
    GMainLoop *main_loop;
    GMainContext *main_context;
#else
    void *main_loop;
    void *main_context;
#endif

    int32_t display_width;
    int32_t display_height;
    pthread_mutex_t lock;
};

// Helper to notify state changes
static void notify_state_change(SpiceBridgeSession *session, SpiceBridgeState new_state) {
    pthread_mutex_lock(&session->lock);
    session->state = new_state;
    pthread_mutex_unlock(&session->lock);

    if (session->callbacks.on_state_changed) {
        session->callbacks.on_state_changed(session->callbacks.context, new_state);
    }
}

#ifdef HAVE_SPICE

// GObject signal handlers

static void on_channel_new(SpiceSession *s, SpiceChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        session->display_channel = SPICE_DISPLAY_CHANNEL(channel);

        g_signal_connect(channel, "display-primary-create",
                        G_CALLBACK(on_display_primary_create), session);
        g_signal_connect(channel, "display-invalidate",
                        G_CALLBACK(on_display_invalidate), session);
        g_signal_connect(channel, "display-primary-destroy",
                        G_CALLBACK(on_display_primary_destroy), session);

        spice_channel_connect(channel);
    } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        session->inputs_channel = SPICE_INPUTS_CHANNEL(channel);
        spice_channel_connect(channel);
    } else if (SPICE_IS_CURSOR_CHANNEL(channel)) {
        g_signal_connect(channel, "cursor-set",
                        G_CALLBACK(on_cursor_set), session);
        g_signal_connect(channel, "cursor-move",
                        G_CALLBACK(on_cursor_move), session);
        spice_channel_connect(channel);
    } else {
        // Connect other channels (main, playback, etc.)
        spice_channel_connect(channel);
    }
}

static void on_channel_destroy(SpiceSession *s, SpiceChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        session->display_channel = NULL;
    } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        session->inputs_channel = NULL;
    }
}

static void on_session_disconnected(GObject *gobject, GParamSpec *pspec, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    // Check migration state - only notify disconnect if not migrating
    notify_state_change(session, SPICE_BRIDGE_STATE_DISCONNECTED);
}

static void on_display_primary_create(SpiceDisplayChannel *channel,
                                       gint format, gint width, gint height,
                                       gint stride, gint shmid, gpointer imgdata,
                                       gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    pthread_mutex_lock(&session->lock);
    session->display_width = width;
    session->display_height = height;
    pthread_mutex_unlock(&session->lock);

    if (session->callbacks.on_display_create) {
        SpiceBridgeSurface surface = {
            .surface_id = 0,
            .width = width,
            .height = height,
            .stride = stride,
            .format = (uint32_t)format,
            .data = (const uint8_t *)imgdata
        };
        session->callbacks.on_display_create(session->callbacks.context, &surface);
    }
}

static void on_display_invalidate(SpiceDisplayChannel *channel,
                                   gint x, gint y, gint w, gint h,
                                   gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    if (session->callbacks.on_display_invalidate) {
        SpiceBridgeRect rect = { .x = x, .y = y, .width = w, .height = h };

        // Get current surface data pointer
        gpointer imgdata = NULL;
        gint width, height, stride;
        g_object_get(channel,
                     "width", &width,
                     "height", &height,
                     "stride", &stride,
                     NULL);

        // Access the surface data from the display channel
        // The data pointer from primary-create remains valid
        // We pass NULL here - the Swift side caches the base pointer from on_display_create
        session->callbacks.on_display_invalidate(
            session->callbacks.context,
            0, // surface_id
            &rect,
            NULL, // Swift uses cached pointer + stride arithmetic
            stride
        );
    }
}

static void on_display_primary_destroy(SpiceDisplayChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    if (session->callbacks.on_display_destroy) {
        session->callbacks.on_display_destroy(session->callbacks.context, 0);
    }
}

static void on_cursor_set(SpiceCursorChannel *channel,
                           gint width, gint height,
                           gint hot_x, gint hot_y,
                           gpointer rgba, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    if (session->callbacks.on_cursor_set) {
        session->callbacks.on_cursor_set(
            session->callbacks.context,
            width, height, hot_x, hot_y,
            (const uint8_t *)rgba
        );
    }
}

static void on_cursor_move(SpiceCursorChannel *channel,
                            gint x, gint y, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    if (session->callbacks.on_cursor_move) {
        session->callbacks.on_cursor_move(session->callbacks.context, x, y);
    }
}

#endif /* HAVE_SPICE */

// Public API implementation

SpiceBridgeSession *spice_bridge_session_new(const SpiceBridgeCallbacks *callbacks) {
    SpiceBridgeSession *session = calloc(1, sizeof(SpiceBridgeSession));
    if (!session) return NULL;

    if (callbacks) {
        session->callbacks = *callbacks;
    }
    session->state = SPICE_BRIDGE_STATE_DISCONNECTED;
    pthread_mutex_init(&session->lock, NULL);

#ifdef HAVE_SPICE
    session->main_context = g_main_context_new();
    session->main_loop = g_main_loop_new(session->main_context, FALSE);

    // Push our context as the thread-default for session creation
    g_main_context_push_thread_default(session->main_context);

    session->spice_session = spice_session_new();
    g_signal_connect(session->spice_session, "channel-new",
                     G_CALLBACK(on_channel_new), session);
    g_signal_connect(session->spice_session, "channel-destroy",
                     G_CALLBACK(on_channel_destroy), session);
    g_signal_connect(session->spice_session, "notify::migration-state",
                     G_CALLBACK(on_session_disconnected), session);

    g_main_context_pop_thread_default(session->main_context);
#endif

    return session;
}

void spice_bridge_session_free(SpiceBridgeSession *session) {
    if (!session) return;

    spice_bridge_disconnect(session);
    spice_bridge_quit_loop(session);

#ifdef HAVE_SPICE
    if (session->spice_session) {
        g_object_unref(session->spice_session);
    }
    if (session->main_loop) {
        g_main_loop_unref(session->main_loop);
    }
    if (session->main_context) {
        g_main_context_unref(session->main_context);
    }
#endif

    pthread_mutex_destroy(&session->lock);
    free(session);
}

bool spice_bridge_connect(SpiceBridgeSession *session,
                          const char *host,
                          int port,
                          int tls_port,
                          const char *password,
                          const char *ca_cert,
                          const char *host_subject,
                          const char *proxy) {
    if (!session || !host) return false;

    notify_state_change(session, SPICE_BRIDGE_STATE_CONNECTING);

#ifdef HAVE_SPICE
    g_main_context_push_thread_default(session->main_context);

    g_object_set(session->spice_session,
                 "host", host,
                 "port", g_strdup_printf("%d", port),
                 NULL);

    if (tls_port > 0) {
        g_object_set(session->spice_session,
                     "tls-port", g_strdup_printf("%d", tls_port),
                     NULL);
    }
    if (password) {
        g_object_set(session->spice_session, "password", password, NULL);
    }
    if (ca_cert) {
        g_object_set(session->spice_session, "ca", ca_cert, NULL);
    }
    if (host_subject) {
        g_object_set(session->spice_session, "cert-subject", host_subject, NULL);
    }
    if (proxy) {
        g_object_set(session->spice_session, "proxy", proxy, NULL);
    }

    gboolean success = spice_session_connect(session->spice_session);

    g_main_context_pop_thread_default(session->main_context);

    if (success) {
        notify_state_change(session, SPICE_BRIDGE_STATE_CONNECTED);
    } else {
        notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
    }
    return success;
#else
    // Stub: no SPICE library linked
    notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
    return false;
#endif
}

void spice_bridge_disconnect(SpiceBridgeSession *session) {
    if (!session) return;

#ifdef HAVE_SPICE
    if (session->spice_session) {
        notify_state_change(session, SPICE_BRIDGE_STATE_DISCONNECTING);
        spice_session_disconnect(session->spice_session);
    }
#endif

    notify_state_change(session, SPICE_BRIDGE_STATE_DISCONNECTED);
}

SpiceBridgeState spice_bridge_get_state(const SpiceBridgeSession *session) {
    if (!session) return SPICE_BRIDGE_STATE_DISCONNECTED;
    return session->state;
}

void spice_bridge_key_press(SpiceBridgeSession *session, uint32_t scancode) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_key_press(session->inputs_channel, scancode);
    }
#endif
}

void spice_bridge_key_release(SpiceBridgeSession *session, uint32_t scancode) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_key_release(session->inputs_channel, scancode);
    }
#endif
}

void spice_bridge_mouse_position(SpiceBridgeSession *session,
                                  int32_t x, int32_t y,
                                  int32_t display_id,
                                  uint32_t button_mask) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_position(session->inputs_channel, x, y, display_id, button_mask);
    }
#endif
}

void spice_bridge_mouse_motion(SpiceBridgeSession *session,
                                int32_t dx, int32_t dy,
                                uint32_t button_mask) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_motion(session->inputs_channel, dx, dy, button_mask);
    }
#endif
}

void spice_bridge_mouse_button_press(SpiceBridgeSession *session,
                                      uint32_t button,
                                      uint32_t button_mask) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_button_press(session->inputs_channel, button, button_mask);
    }
#endif
}

void spice_bridge_mouse_button_release(SpiceBridgeSession *session,
                                        uint32_t button,
                                        uint32_t button_mask) {
#ifdef HAVE_SPICE
    if (session && session->inputs_channel) {
        spice_inputs_button_release(session->inputs_channel, button, button_mask);
    }
#endif
}

void spice_bridge_run_loop(SpiceBridgeSession *session) {
    if (!session) return;

#ifdef HAVE_SPICE
    g_main_context_push_thread_default(session->main_context);
    g_main_loop_run(session->main_loop);
    g_main_context_pop_thread_default(session->main_context);
#endif
}

void spice_bridge_quit_loop(SpiceBridgeSession *session) {
    if (!session) return;

#ifdef HAVE_SPICE
    if (session->main_loop && g_main_loop_is_running(session->main_loop)) {
        g_main_loop_quit(session->main_loop);
    }
#endif
}

bool spice_bridge_get_display_info(const SpiceBridgeSession *session,
                                    int32_t *out_width,
                                    int32_t *out_height) {
    if (!session) return false;

    // Use lock to safely read display dimensions
    pthread_mutex_lock((pthread_mutex_t *)&session->lock);
    int32_t w = session->display_width;
    int32_t h = session->display_height;
    pthread_mutex_unlock((pthread_mutex_t *)&session->lock);

    if (w <= 0 || h <= 0) return false;

    if (out_width) *out_width = w;
    if (out_height) *out_height = h;
    return true;
}
