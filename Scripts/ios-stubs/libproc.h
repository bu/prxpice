/*
 * Stub for iOS cross-compilation.
 * libproc.h is macOS-only and not present in the iOS SDK.
 * Provides the minimal definitions used by GLib's gspawn.c.
 * Returning -1/0 causes GLib to fall back to its other methods.
 */
#ifndef LIBPROC_H_IOS_STUB
#define LIBPROC_H_IOS_STUB

#include <sys/types.h>
#include <stdint.h>

static inline int proc_pidpath(int pid, void *buffer, uint32_t buffersize) {
    (void)pid; (void)buffer; (void)buffersize;
    return -1;
}

static inline int proc_pidinfo(int pid, int flavor, uint64_t arg,
                                void *buffer, int buffersize) {
    (void)pid; (void)flavor; (void)arg; (void)buffer; (void)buffersize;
    return -1;
}

#endif /* LIBPROC_H_IOS_STUB */
