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

void *PRXInstallMouseMovedMonitor(PRXVoidCallback handler, void *context) {
#if TARGET_OS_MACCATALYST
    if (!handler) return NULL;
    Class nsEvent = NSClassFromString(@"NSEvent");
    Class nsApp = NSClassFromString(@"NSApplication");
    if (!nsEvent || !nsApp) return NULL;
    // mouseMoved events are dropped by NSWindow unless it explicitly
    // opts in. Set the flag on every existing window.
    id app = ((id(*)(Class,SEL))objc_msgSend)(nsApp, sel_getUid("sharedApplication"));
    id wins = ((id(*)(id,SEL))objc_msgSend)(app, sel_getUid("windows"));
    NSUInteger count = ((NSUInteger(*)(id,SEL))objc_msgSend)(wins, sel_getUid("count"));
    for (NSUInteger i = 0; i < count; i++) {
        id win = ((id(*)(id,SEL,NSUInteger))objc_msgSend)(
            wins, sel_getUid("objectAtIndex:"), i);
        ((void(*)(id,SEL,BOOL))objc_msgSend)(
            win, sel_getUid("setAcceptsMouseMovedEvents:"), YES);
    }
    // NSEventMaskMouseMoved == 1ULL << NSEventTypeMouseMoved(5)
    NSUInteger mask = 1ULL << 5;
    id (^block)(id) = ^id(id event) {
        handler(context);
        return event; // never swallow; just observe
    };
    id monitor = ((id(*)(Class,SEL,NSUInteger,id))objc_msgSend)(
        nsEvent,
        sel_getUid("addLocalMonitorForEventsMatchingMask:handler:"),
        mask, block);
    return (void *)CFBridgingRetain(monitor);
#else
    (void)handler; (void)context;
    return NULL;
#endif
}

void PRXRemoveMouseMovedMonitor(void *token) {
#if TARGET_OS_MACCATALYST
    if (!token) return;
    id monitor = CFBridgingRelease(token);
    Class nsEvent = NSClassFromString(@"NSEvent");
    ((void(*)(Class,SEL,id))objc_msgSend)(
        nsEvent, sel_getUid("removeMonitor:"), monitor);
#else
    (void)token;
#endif
}

void *PRXObserveDidEnterFullScreen(PRXVoidCallback handler, void *context) {
#if TARGET_OS_MACCATALYST
    if (!handler) return NULL;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    id obs = [nc addObserverForName:@"NSWindowDidEnterFullScreenNotification"
                             object:nil
                              queue:[NSOperationQueue mainQueue]
                         usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        handler(context);
    }];
    return (void *)CFBridgingRetain(obs);
#else
    (void)handler; (void)context;
    return NULL;
#endif
}

void PRXRemoveFullScreenObserver(void *token) {
#if TARGET_OS_MACCATALYST
    if (!token) return;
    id obs = CFBridgingRelease(token);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
#else
    (void)token;
#endif
}

void *PRXInstallRightClickMonitor(PRXRightClickHandler handler, void *context) {
#if TARGET_OS_MACCATALYST
    if (!handler) return NULL;
    Class nsEvent = NSClassFromString(@"NSEvent");
    if (!nsEvent) return NULL;
    // NSEventMaskRightMouseDown(1<<3) | NSEventMaskRightMouseUp(1<<4)
    NSUInteger mask = (1ULL << 3) | (1ULL << 4);
    id (^block)(id) = ^id(id event) {
        NSUInteger type = ((NSUInteger(*)(id,SEL))objc_msgSend)(
            event, sel_getUid("type"));
        // NSEventTypeRightMouseDown == 3, NSEventTypeRightMouseUp == 4
        bool pressed = (type == 3);
        if (handler(pressed, context)) {
            return nil; // swallow so AppKit doesn't show its own menu
        }
        return event;
    };
    id monitor = ((id(*)(Class,SEL,NSUInteger,id))objc_msgSend)(
        nsEvent,
        sel_getUid("addLocalMonitorForEventsMatchingMask:handler:"),
        mask, block);
    return (void *)CFBridgingRetain(monitor);
#else
    (void)handler; (void)context;
    return NULL;
#endif
}

void PRXRemoveRightClickMonitor(void *token) {
#if TARGET_OS_MACCATALYST
    if (!token) return;
    id monitor = CFBridgingRelease(token);
    Class nsEvent = NSClassFromString(@"NSEvent");
    ((void(*)(Class,SEL,id))objc_msgSend)(
        nsEvent, sel_getUid("removeMonitor:"), monitor);
#else
    (void)token;
#endif
}
