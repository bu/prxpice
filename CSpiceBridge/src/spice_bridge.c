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
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <os/log.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>
#include <netdb.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

#define BLOG(fmt, ...) do { \
    os_log(OS_LOG_DEFAULT, "[SpiceBridge] " fmt, ##__VA_ARGS__); \
} while(0)

#ifdef HAVE_SPICE
#include <spice-client.h>
#endif

// ---------------------------------------------------------------------------
// Singleton shared GLib main loop — one thread runs g_main_loop_run on the
// global default context for the app lifetime.  All SpiceSessions attach
// their GIO sources to that context, so every session's callbacks are
// dispatched by this single thread (no multi-thread context ownership fights).
// ---------------------------------------------------------------------------
static GMainLoop      *s_shared_loop = NULL;
static pthread_once_t  s_loop_once   = PTHREAD_ONCE_INIT;

static void *shared_loop_thread(void *arg) {
    (void)arg;
    pthread_setname_np("com.prxpice.glib-mainloop");
    BLOG("shared GLib loop: started");
    g_main_loop_run(s_shared_loop);
    BLOG("shared GLib loop: exited");
    return NULL;
}

static void init_shared_loop(void) {
    s_shared_loop = g_main_loop_new(NULL, FALSE); // global default context
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&t, &attr, shared_loop_thread, NULL);
    pthread_attr_destroy(&attr);
}

static void ensure_shared_loop(void) {
    pthread_once(&s_loop_once, init_shared_loop);
}
// ---------------------------------------------------------------------------

struct SpiceBridgeSession {
    SpiceBridgeCallbacks callbacks;
    SpiceBridgeState state;

#ifdef HAVE_SPICE
    SpiceSession *spice_session;
    SpiceMainChannel *main_channel;
    SpiceInputsChannel *inputs_channel;
    SpiceDisplayChannel *display_channel;
    SpicePlaybackChannel *playback_channel;
    SpiceRecordChannel   *record_channel;
    // Disconnect synchronization: quit_loop waits until on_session_disconnected fires
    GMutex   disconnect_mutex;
    GCond    disconnect_cond;
    gboolean disconnect_notified;
#endif

    int32_t display_width;
    int32_t display_height;
    pthread_mutex_t lock;

    // TLS relay — bypasses GIO's missing TLS backend (GDummyTlsBackend)
    int relay_listen_fd;   // local loopback listener (-1 = unused)
    int relay_running;     // 1 while relay accept loop is active
};

// Route a debug message to the Swift debug callback
static void debug_notify(SpiceBridgeSession *session, const char *fmt, ...) {
    if (!session || !session->callbacks.on_debug) return;
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    session->callbacks.on_debug(session->callbacks.context, buf);
}
#define DBLOG(session, fmt, ...) do { \
    BLOG(fmt, ##__VA_ARGS__); \
    debug_notify(session, fmt, ##__VA_ARGS__); \
} while(0)

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

// Forward declarations
static void on_channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer user_data);
static void on_display_primary_create(SpiceDisplayChannel *channel, gint format, gint width, gint height, gint stride, gint shmid, gpointer imgdata, gpointer user_data);
static void on_display_invalidate(SpiceDisplayChannel *channel, gint x, gint y, gint w, gint h, gpointer user_data);
static void on_display_primary_destroy(SpiceDisplayChannel *channel, gpointer user_data);
static void on_cursor_set(SpiceCursorChannel *channel, gint width, gint height, gint hot_x, gint hot_y, gpointer rgba, gpointer user_data);
static void on_cursor_move(SpiceCursorChannel *channel, gint x, gint y, gpointer user_data);
static void on_playback_start(SpicePlaybackChannel *channel, gint format, gint channels, gint freq, gpointer user_data);
static void on_playback_data(SpicePlaybackChannel *channel, gpointer data, gint size, gpointer user_data);
static void on_playback_stop(SpicePlaybackChannel *channel, gpointer user_data);
static void on_record_start(SpiceRecordChannel *channel, gint format, gint channels, gint freq, gpointer user_data);
static void on_record_stop(SpiceRecordChannel *channel, gpointer user_data);

// GObject signal handlers

static void on_channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    const char *evname = "UNKNOWN";
    switch (event) {
        case SPICE_CHANNEL_OPENED:           evname = "OPENED"; break;
        case SPICE_CHANNEL_CLOSED:           evname = "CLOSED"; break;
        case SPICE_CHANNEL_ERROR_CONNECT:    evname = "ERR_CONNECT"; break;
        case SPICE_CHANNEL_ERROR_TLS:        evname = "ERR_TLS"; break;
        case SPICE_CHANNEL_ERROR_LINK:       evname = "ERR_LINK"; break;
        case SPICE_CHANNEL_ERROR_AUTH:       evname = "ERR_AUTH"; break;
        case SPICE_CHANNEL_ERROR_IO:         evname = "ERR_IO"; break;
        default: break;
    }
    DBLOG(session, "ch_event %s %s",
          g_type_name(G_TYPE_FROM_INSTANCE(channel)), evname);
}

static void on_channel_new(SpiceSession *s, SpiceChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    gint channel_id = 0;
    g_object_get(channel, "channel-id", &channel_id, NULL);
    DBLOG(session, "ch_new type=%s id=%d",
          g_type_name(G_TYPE_FROM_INSTANCE(channel)), channel_id);

    // Always watch channel events so we see connect/error on every channel
    g_signal_connect(channel, "channel-event", G_CALLBACK(on_channel_event), session);

    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        DBLOG(session, "ch_new: main channel, connecting");
        session->main_channel = SPICE_MAIN_CHANNEL(channel);
        spice_channel_connect(channel);
    } else if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        DBLOG(session, "ch_new: display channel, connecting");
        session->display_channel = SPICE_DISPLAY_CHANNEL(channel);

        g_signal_connect(channel, "display-primary-create",
                        G_CALLBACK(on_display_primary_create), session);
        g_signal_connect(channel, "display-invalidate",
                        G_CALLBACK(on_display_invalidate), session);
        g_signal_connect(channel, "display-primary-destroy",
                        G_CALLBACK(on_display_primary_destroy), session);

        /* Request H.264 as the preferred video codec for display streams.
         * VideoToolbox provides hardware H.264 decode on iOS.
         * Falls back to MJPEG automatically if the server doesn't support H.264. */
        spice_channel_connect(channel);
        static const gint codecs[] = {
            SPICE_VIDEO_CODEC_TYPE_H264,
            SPICE_VIDEO_CODEC_TYPE_H265,
            SPICE_VIDEO_CODEC_TYPE_MJPEG,
        };
        GError *codec_err = NULL;
        spice_display_channel_change_preferred_video_codec_types(
            channel, codecs, G_N_ELEMENTS(codecs), &codec_err);
        if (codec_err) {
            DBLOG(session, "ch_new: codec pref not accepted: %s", codec_err->message);
            g_error_free(codec_err);
        } else {
            DBLOG(session, "ch_new: preferred codecs: H264, H265, MJPEG");
        }
    } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        BLOG("on_channel_new: is inputs channel, connecting");
        session->inputs_channel = SPICE_INPUTS_CHANNEL(channel);
        spice_channel_connect(channel);
    } else if (SPICE_IS_CURSOR_CHANNEL(channel)) {
        BLOG("on_channel_new: is cursor channel, connecting");
        g_signal_connect(channel, "cursor-set",
                        G_CALLBACK(on_cursor_set), session);
        g_signal_connect(channel, "cursor-move",
                        G_CALLBACK(on_cursor_move), session);
        spice_channel_connect(channel);
    } else if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {
        DBLOG(session, "ch_new: playback channel, connecting");
        session->playback_channel = SPICE_PLAYBACK_CHANNEL(channel);
        g_signal_connect(channel, "playback-start", G_CALLBACK(on_playback_start), session);
        g_signal_connect(channel, "playback-data",  G_CALLBACK(on_playback_data),  session);
        g_signal_connect(channel, "playback-stop",  G_CALLBACK(on_playback_stop),  session);
        spice_channel_connect(channel);
    } else if (SPICE_IS_RECORD_CHANNEL(channel)) {
        DBLOG(session, "ch_new: record channel, connecting");
        session->record_channel = SPICE_RECORD_CHANNEL(channel);
        g_signal_connect(channel, "record-start", G_CALLBACK(on_record_start), session);
        g_signal_connect(channel, "record-stop",  G_CALLBACK(on_record_stop),  session);
        spice_channel_connect(channel);
    } else {
        spice_channel_connect(channel);
    }
}

static void on_channel_destroy(SpiceSession *s, SpiceChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        session->main_channel = NULL;
    } else if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        session->display_channel = NULL;
    } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        session->inputs_channel = NULL;
    } else if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {
        session->playback_channel = NULL;
    } else if (SPICE_IS_RECORD_CHANNEL(channel)) {
        session->record_channel = NULL;
    }
}

static void on_session_disconnected(SpiceSession *spice_session, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "session: disconnected signal");
    // Unblock spice_bridge_quit_loop() which waits for this signal
    g_mutex_lock(&session->disconnect_mutex);
    session->disconnect_notified = TRUE;
    g_cond_signal(&session->disconnect_cond);
    g_mutex_unlock(&session->disconnect_mutex);
    notify_state_change(session, SPICE_BRIDGE_STATE_DISCONNECTED);
}

static void spice_glib_log_handler(const gchar *log_domain,
                                    GLogLevelFlags log_level,
                                    const gchar *message,
                                    gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    const char *level = (log_level & G_LOG_LEVEL_ERROR)    ? "ERR"  :
                        (log_level & G_LOG_LEVEL_CRITICAL) ? "CRIT" :
                        (log_level & G_LOG_LEVEL_WARNING)  ? "WARN" :
                        (log_level & G_LOG_LEVEL_MESSAGE)  ? "MSG"  : "DBG";
    DBLOG(session, "GLOG[%s/%s] %s",
          log_domain ? log_domain : "glib", level, message ? message : "");
}

static void on_display_primary_create(SpiceDisplayChannel *channel,
                                       gint format, gint width, gint height,
                                       gint stride, gint shmid, gpointer imgdata,
                                       gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;

    DBLOG(session, "display_create fmt=%d %dx%d stride=%d data=%p",
          format, width, height, stride, imgdata);

    pthread_mutex_lock(&session->lock);
    session->display_width = width;
    session->display_height = height;
    pthread_mutex_unlock(&session->lock);

    if (session->callbacks.on_display_create) {
        BLOG("on_display_primary_create: calling Swift on_display_create callback");
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

        // Get the current primary surface to obtain stride and data pointer
        SpiceDisplayPrimary primary;
        gint stride = 0;
        const uint8_t *data = NULL;
        if (spice_display_channel_get_primary(SPICE_CHANNEL(channel), 0, &primary)) {
            stride = primary.stride;
            data = (const uint8_t *)primary.data;
        }

        session->callbacks.on_display_invalidate(
            session->callbacks.context,
            0, // surface_id
            &rect,
            data,
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

static void on_playback_start(SpicePlaybackChannel *channel,
                               gint format, gint channels, gint freq,
                               gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "playback_start: fmt=%d ch=%d freq=%d", format, channels, freq);
    if (session->callbacks.on_playback_start)
        session->callbacks.on_playback_start(session->callbacks.context,
                                              (int32_t)channels, (int32_t)freq);
}

static void on_playback_data(SpicePlaybackChannel *channel,
                              gpointer data, gint size,
                              gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    if (session->callbacks.on_playback_data && data)
        session->callbacks.on_playback_data(session->callbacks.context,
                                             (const uint8_t *)data, (int32_t)size);
}

static void on_playback_stop(SpicePlaybackChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "playback_stop");
    if (session->callbacks.on_playback_stop)
        session->callbacks.on_playback_stop(session->callbacks.context);
}

static void on_record_start(SpiceRecordChannel *channel,
                             gint format, gint channels, gint freq,
                             gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "record_start: fmt=%d ch=%d freq=%d", format, channels, freq);
    if (session->callbacks.on_record_start)
        session->callbacks.on_record_start(session->callbacks.context,
                                            (int32_t)channels, (int32_t)freq);
}

static void on_record_stop(SpiceRecordChannel *channel, gpointer user_data) {
    SpiceBridgeSession *session = (SpiceBridgeSession *)user_data;
    DBLOG(session, "record_stop");
    if (session->callbacks.on_record_stop)
        session->callbacks.on_record_stop(session->callbacks.context);
}

#endif /* HAVE_SPICE */

// ---------------------------------------------------------------------------
// TLS relay — makes spice-glib see a plain SPICE server while we handle
// the proxy CONNECT + OpenSSL TLS handshake transparently.
//
// SPICE opens one TCP connection per channel (main, display, cursor, inputs).
// The relay listener accepts each connection and spawns a per-channel worker
// thread that does: proxy CONNECT → OpenSSL TLS → bidirectional relay.
// ---------------------------------------------------------------------------

typedef struct {
    SpiceBridgeSession *session;
    char real_host[256];
    int  real_tls_port;
    char proxy_host[64];
    int  proxy_port;
    int  has_proxy;
    int  client_fd;  // already-accepted fd (set per worker)
} TlsRelayArgs;

// Resolve hostname → IPv4
static int resolve_host(const char *host, struct in_addr *out) {
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) return -1;
    *out = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
    freeaddrinfo(res);
    return 0;
}

// Worker thread: handles one SPICE channel connection end-to-end
static void *tls_relay_worker(void *arg) {
    TlsRelayArgs *a = (TlsRelayArgs *)arg;
    SpiceBridgeSession *session = a->session;
    int client_fd = a->client_fd;
    int server_fd = -1;
    SSL_CTX *ctx  = NULL;
    SSL *ssl      = NULL;

    // 1. Connect to proxy or directly to server
    {
        const char *conn_host = a->has_proxy ? a->proxy_host : a->real_host;
        int  conn_port        = a->has_proxy ? a->proxy_port : a->real_tls_port;

        struct in_addr addr4;
        if (resolve_host(conn_host, &addr4) < 0) {
            DBLOG(session, "relay[%d]: resolve failed for %s", client_fd, conn_host);
            goto worker_cleanup;
        }
        struct sockaddr_in sa = {0};
        sa.sin_family = AF_INET;
        sa.sin_port   = htons((uint16_t)conn_port);
        sa.sin_addr   = addr4;

        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd >= 0) {
            int nodelay = 1;
            setsockopt(server_fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
        }
        if (server_fd < 0 || connect(server_fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
            DBLOG(session, "relay[%d]: connect to %s:%d failed errno=%d",
                  client_fd, conn_host, conn_port, errno);
            goto worker_cleanup;
        }
    }

    // 2. HTTP CONNECT tunnel (if using proxy)
    if (a->has_proxy) {
        char req[512];
        snprintf(req, sizeof(req),
            "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n",
            a->real_host, a->real_tls_port,
            a->real_host, a->real_tls_port);
        send(server_fd, req, strlen(req), 0);

        char resp[1024] = {0};
        int total = 0;
        while (total < (int)sizeof(resp) - 1) {
            int r = (int)recv(server_fd, resp + total, sizeof(resp) - 1 - total, 0);
            if (r <= 0) break;
            total += r;
            if (strstr(resp, "\r\n\r\n")) break;
        }
        if (!strstr(resp, "200")) {
            DBLOG(session, "relay[%d]: proxy CONNECT failed: %.40s", client_fd, resp);
            goto worker_cleanup;
        }
    }

    // 3. TLS handshake
    {
        ctx = SSL_CTX_new(TLS_client_method());
        if (!ctx) { DBLOG(session, "relay[%d]: SSL_CTX_new failed", client_fd); goto worker_cleanup; }
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);

        ssl = SSL_new(ctx);
        if (!ssl) { DBLOG(session, "relay[%d]: SSL_new failed", client_fd); goto worker_cleanup; }
        SSL_set_fd(ssl, server_fd);
        SSL_set_tlsext_host_name(ssl, a->real_host);

        if (SSL_connect(ssl) != 1) {
            char errbuf[256];
            ERR_error_string_n(ERR_get_error(), errbuf, sizeof(errbuf));
            DBLOG(session, "relay[%d]: SSL_connect failed: %s", client_fd, errbuf);
            goto worker_cleanup;
        }
        DBLOG(session, "relay[%d]: TLS OK cipher=%s", client_fd, SSL_get_cipher(ssl));
    }

    // 4. Bidirectional relay loop
    {
        int ssl_fd = SSL_get_fd(ssl);
        uint8_t buf[16384];

        while (session->relay_running) {
            if (SSL_pending(ssl) > 0) {
                int n = SSL_read(ssl, buf, sizeof(buf));
                if (n <= 0) break;
                for (int off = 0; off < n; ) {
                    int w = (int)write(client_fd, buf + off, (size_t)(n - off));
                    if (w <= 0) goto worker_done;
                    off += w;
                }
                continue;
            }

            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(client_fd, &rfds);
            FD_SET(ssl_fd, &rfds);
            int maxfd = (client_fd > ssl_fd ? client_fd : ssl_fd) + 1;
            struct timeval tv = {5, 0};
            int ns = select(maxfd, &rfds, NULL, NULL, &tv);
            if (ns < 0) break;
            if (ns == 0) continue;

            if (FD_ISSET(client_fd, &rfds)) {
                int n = (int)read(client_fd, buf, sizeof(buf));
                if (n <= 0) break;
                if (SSL_write(ssl, buf, n) <= 0) break;
            }
            if (FD_ISSET(ssl_fd, &rfds)) {
                int n = SSL_read(ssl, buf, sizeof(buf));
                if (n <= 0) break;
                for (int off = 0; off < n; ) {
                    int w = (int)write(client_fd, buf + off, (size_t)(n - off));
                    if (w <= 0) goto worker_done;
                    off += w;
                }
            }
        }
    }

worker_done:
worker_cleanup:
    if (ssl)       { SSL_shutdown(ssl); SSL_free(ssl); }
    if (ctx)       { SSL_CTX_free(ctx); }
    if (server_fd >= 0) close(server_fd);
    if (client_fd >= 0) close(client_fd);
    free(a);
    return NULL;
}

// Accept loop thread: accepts one connection per SPICE channel, spawns worker
static void *tls_relay_thread(void *arg) {
    TlsRelayArgs *tmpl = (TlsRelayArgs *)arg; // read-only template
    SpiceBridgeSession *session = tmpl->session;

    DBLOG(session, "relay: accept loop started");
    while (session->relay_running) {
        struct sockaddr_in addr;
        socklen_t addrlen = sizeof(addr);
        int cfd = accept(session->relay_listen_fd, (struct sockaddr *)&addr, &addrlen);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            break; // listener closed by disconnect
        }

        // Allocate per-worker args (copy of template + client fd)
        TlsRelayArgs *wa = malloc(sizeof(TlsRelayArgs));
        if (!wa) { close(cfd); continue; }
        *wa = *tmpl;
        wa->client_fd = cfd;

        pthread_t wt;
        if (pthread_create(&wt, NULL, tls_relay_worker, wa) != 0) {
            close(cfd);
            free(wa);
        } else {
            pthread_detach(wt);
        }
    }

    DBLOG(session, "relay: accept loop exited");
    free(tmpl);
    return NULL;
}

// ---------------------------------------------------------------------------
// Public API implementation

SpiceBridgeSession *spice_bridge_session_new(const SpiceBridgeCallbacks *callbacks) {
    SpiceBridgeSession *session = calloc(1, sizeof(SpiceBridgeSession));
    if (!session) return NULL;

    if (callbacks) {
        session->callbacks = *callbacks;
    }
    session->state = SPICE_BRIDGE_STATE_DISCONNECTED;
    pthread_mutex_init(&session->lock, NULL);
    session->relay_listen_fd = -1;
    session->relay_running   = 0;

#ifdef HAVE_SPICE
    BLOG("spice_bridge_session_new: HAVE_SPICE is active, creating session");

    // Disconnect synchronization — quit_loop waits until on_session_disconnected fires
    g_mutex_init(&session->disconnect_mutex);
    g_cond_init(&session->disconnect_cond);
    session->disconnect_notified = FALSE;

    // All sessions share the global default GLib context (NULL).
    // ensure_shared_loop() starts a single dedicated thread that runs
    // g_main_loop_run on that context — called later from spice_bridge_run_loop.
    session->spice_session = spice_session_new();
    g_signal_connect(session->spice_session, "channel-new",
                     G_CALLBACK(on_channel_new), session);
    g_signal_connect(session->spice_session, "channel-destroy",
                     G_CALLBACK(on_channel_destroy), session);
    g_signal_connect(session->spice_session, "disconnected",
                     G_CALLBACK(on_session_disconnected), session);

    // Capture internal spice-glib warnings/errors via the GLib log system
    g_log_set_handler("GSpice",   G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);
    g_log_set_handler("Spice",    G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);
    g_log_set_handler("GLib",     G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);
    g_log_set_handler("GLib-GIO", G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);
    g_log_set_handler(NULL,       G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL, spice_glib_log_handler, session);

    // Check if GIO has a working TLS backend — required for SPICE TLS
    GTlsBackend *tls_be = g_tls_backend_get_default();
    gboolean tls_ok = tls_be ? g_tls_backend_supports_tls(tls_be) : FALSE;
    DBLOG(session, "GIO TLS: backend=%s supports=%d",
          tls_be ? g_type_name(G_TYPE_FROM_INSTANCE(tls_be)) : "NONE", (int)tls_ok);
#endif

    return session;
}

void spice_bridge_session_free(SpiceBridgeSession *session) {
    if (!session) return;

    spice_bridge_disconnect(session);
    spice_bridge_quit_loop(session);

#ifdef HAVE_SPICE
    // Clear all Swift callbacks before GObject finalization to prevent
    // spice_session_dispose -> g_warn_message -> log_handler -> on_debug
    // from dispatching back into Swift while the view hierarchy is torn down.
    memset(&session->callbacks, 0, sizeof(session->callbacks));

    if (session->spice_session) {
        g_object_unref(session->spice_session);
    }
    g_mutex_clear(&session->disconnect_mutex);
    g_cond_clear(&session->disconnect_cond);
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

    DBLOG(session, "connect host=%s port=%d tls=%d", host, port, tls_port);

    notify_state_change(session, SPICE_BRIDGE_STATE_CONNECTING);

#ifdef HAVE_SPICE
    if (tls_port > 0) {
        // ----------------------------------------------------------------
        // TLS relay path: GIO has no TLS backend (GDummyTlsBackend).
        // We create a local loopback listener, start a relay thread that
        // does proxy CONNECT + OpenSSL TLS, and tell spice-glib to connect
        // to 127.0.0.1:relay_port over plain TCP.
        // ----------------------------------------------------------------

        // Build relay args — parse proxy URL if present
        TlsRelayArgs *ra = calloc(1, sizeof(TlsRelayArgs));
        if (!ra) {
            notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
            return false;
        }
        ra->session = session;
        strncpy(ra->real_host, host, sizeof(ra->real_host) - 1);
        ra->real_tls_port = tls_port;
        ra->has_proxy = (proxy != NULL);
        if (proxy) {
            const char *p = strstr(proxy, "://");
            const char *h = p ? p + 3 : proxy;
            const char *col = strrchr(h, ':');
            if (col) {
                ra->proxy_port = atoi(col + 1);
                int hl = (int)(col - h);
                if (hl >= (int)sizeof(ra->proxy_host)) hl = (int)sizeof(ra->proxy_host) - 1;
                memcpy(ra->proxy_host, h, hl);
            } else {
                strncpy(ra->proxy_host, h, sizeof(ra->proxy_host) - 1);
                ra->proxy_port = 3128;
            }
        }

        // Create local listener on 127.0.0.1:0
        int lfd = socket(AF_INET, SOCK_STREAM, 0);
        if (lfd < 0) {
            DBLOG(session, "relay: socket failed errno=%d", errno);
            free(ra);
            notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
            return false;
        }
        int one = 1;
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in la = {0};
        la.sin_family = AF_INET;
        la.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        la.sin_port = 0;
        if (bind(lfd, (struct sockaddr *)&la, sizeof(la)) < 0 ||
            listen(lfd, 16) < 0) {
            DBLOG(session, "relay: bind/listen failed errno=%d", errno);
            close(lfd);
            free(ra);
            notify_state_change(session, SPICE_BRIDGE_STATE_ERROR);
            return false;
        }
        socklen_t llen = sizeof(la);
        getsockname(lfd, (struct sockaddr *)&la, &llen);
        int relay_port = ntohs(la.sin_port);
        session->relay_listen_fd = lfd;
        DBLOG(session, "relay: listener on 127.0.0.1:%d -> %s:%d (proxy=%s)",
              relay_port, host, tls_port, proxy ? proxy : "none");

        // Launch relay thread (detached)
        session->relay_running = 1;
        pthread_t rt;
        pthread_create(&rt, NULL, tls_relay_thread, ra);
        pthread_detach(rt);

        // Point spice-glib at our local relay (plain TCP, no proxy, no TLS)
        g_object_set(session->spice_session,
                     "host", "127.0.0.1",
                     "port", g_strdup_printf("%d", relay_port),
                     NULL);
        // Do NOT set tls-port or proxy — relay handles them
        if (password) {
            g_object_set(session->spice_session, "password", password, NULL);
        }
    } else {
        // ----------------------------------------------------------------
        // Plain (non-TLS) path — use spice-glib proxy/TLS handling as-is
        // ----------------------------------------------------------------
        g_object_set(session->spice_session,
                     "host", host,
                     "port", g_strdup_printf("%d", port),
                     NULL);
        if (password) {
            g_object_set(session->spice_session, "password", password, NULL);
        }
        if (ca_cert) {
            char ca_tmp[256] = {0};
            const char *tmpdir = g_get_tmp_dir();
            size_t tlen = strlen(tmpdir);
            if (tlen > 0 && tmpdir[tlen - 1] == '/')
                snprintf(ca_tmp, sizeof(ca_tmp), "%sspice_ca_XXXXXX.pem", tmpdir);
            else
                snprintf(ca_tmp, sizeof(ca_tmp), "%s/spice_ca_XXXXXX.pem", tmpdir);
            int fd = mkstemps(ca_tmp, 4);
            if (fd >= 0) {
                write(fd, ca_cert, strlen(ca_cert));
                close(fd);
                DBLOG(session, "ca-file=%s", ca_tmp);
                g_object_set(session->spice_session, "ca-file", ca_tmp, NULL);
            } else {
                DBLOG(session, "ca-file: failed to create temp file");
            }
        }
        if (host_subject) {
            g_object_set(session->spice_session, "cert-subject", host_subject, NULL);
        }
        if (proxy) {
            g_object_set(session->spice_session, "proxy", proxy, NULL);
        }
        g_object_set(session->spice_session, "verify", (guint)0, NULL);
        DBLOG(session, "verify=0 (TLS cert check disabled)");
    }

    gboolean success = spice_session_connect(session->spice_session);
    DBLOG(session, "spice_session_connect=%d", success);

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

    // Stop relay accept loop by closing the listener fd
    session->relay_running = 0;
    if (session->relay_listen_fd >= 0) {
        close(session->relay_listen_fd);
        session->relay_listen_fd = -1;
    }
    // Per-channel worker threads are detached and will exit when their fds close

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
    DBLOG(session, "run_loop: ensuring shared GLib loop is running");
#ifdef HAVE_SPICE
    ensure_shared_loop();
#endif
}

void spice_bridge_quit_loop(SpiceBridgeSession *session) {
    if (!session) return;
#ifdef HAVE_SPICE
    // Wait (up to 5 s) for on_session_disconnected to fire before the caller
    // proceeds to free the session.  Prevents use-after-free in GLib callbacks.
    g_mutex_lock(&session->disconnect_mutex);
    if (!session->disconnect_notified) {
        gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
        g_cond_wait_until(&session->disconnect_cond, &session->disconnect_mutex, deadline);
    }
    g_mutex_unlock(&session->disconnect_mutex);
    // The shared GLib loop is not stopped — it serves all sessions for the app lifetime.
#endif
}

void spice_bridge_record_send_data(SpiceBridgeSession *session,
                                    const uint8_t *data,
                                    size_t size,
                                    uint32_t time_ms) {
#ifdef HAVE_SPICE
    if (!session || !session->record_channel || !data || size == 0) return;
    spice_record_channel_send_data(session->record_channel,
                                   (gpointer)data, (gsize)size, (guint32)time_ms);
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
