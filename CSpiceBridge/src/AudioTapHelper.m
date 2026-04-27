#import "AudioTapHelper.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>

void EnterFullScreen(void) {
#if TARGET_OS_MACCATALYST
    // AppKit APIs are marked unavailable on Mac Catalyst at compile time even though
    // they exist at runtime. Use the ObjC runtime to bypass the restriction.
    Class cls = NSClassFromString(@"NSApplication");
    id app  = ((id(*)(Class,SEL))objc_msgSend)(cls, sel_getUid("sharedApplication"));
    id wins = ((id(*)(id,  SEL))objc_msgSend)(app, sel_getUid("windows"));
    id win  = ((id(*)(id,  SEL))objc_msgSend)(wins, sel_getUid("firstObject"));
    ((void(*)(id,SEL,id))objc_msgSend)(win, sel_getUid("toggleFullScreen:"), nil);
#endif
}

void *PRXInstallKeyDownMonitor(PRXKeyHandler handler, void *context) {
#if TARGET_OS_MACCATALYST
    if (!handler) return NULL;
    Class nsEvent = NSClassFromString(@"NSEvent");
    if (!nsEvent) return NULL;
    // NSEventMaskKeyDown == 1ULL << NSEventTypeKeyDown(10)
    NSUInteger mask = 1ULL << 10;
    id (^block)(id) = ^id(id event) {
        unsigned short keyCode = ((unsigned short(*)(id, SEL))objc_msgSend)(
            event, sel_getUid("keyCode"));
        NSUInteger flags = ((NSUInteger(*)(id, SEL))objc_msgSend)(
            event, sel_getUid("modifierFlags"));
        if (handler(keyCode, (unsigned long)flags, context)) {
            return nil; // swallow
        }
        return event;
    };
    id monitor = ((id(*)(Class, SEL, NSUInteger, id))objc_msgSend)(
        nsEvent,
        sel_getUid("addLocalMonitorForEventsMatchingMask:handler:"),
        mask, block);
    return (void *)CFBridgingRetain(monitor);
#else
    (void)handler; (void)context;
    return NULL;
#endif
}

void PRXRemoveKeyDownMonitor(void *token) {
#if TARGET_OS_MACCATALYST
    if (!token) return;
    id monitor = CFBridgingRelease(token);
    Class nsEvent = NSClassFromString(@"NSEvent");
    ((void(*)(Class, SEL, id))objc_msgSend)(
        nsEvent, sel_getUid("removeMonitor:"), monitor);
#else
    (void)token;
#endif
}
