/*
 * Stub for iOS cross-compilation.
 * sys/proc_info.h is macOS-only and not present in the iOS SDK.
 * Provides the minimal definitions used by GLib's gspawn.c.
 */
#ifndef SYS_PROC_INFO_H_IOS_STUB
#define SYS_PROC_INFO_H_IOS_STUB

#include <stdint.h>

#define PROC_PIDLISTFDS 1

struct proc_fdinfo {
    int32_t  proc_fd;
    uint32_t proc_fdtype;
};

#define PROC_PIDLISTFD_SIZE ((int)sizeof(struct proc_fdinfo))

#endif /* SYS_PROC_INFO_H_IOS_STUB */
