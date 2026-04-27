#pragma once

#include <stdbool.h>

/// Enters true macOS full-screen mode on the first application window.
/// No-op on non-macCatalyst builds.
void EnterFullScreen(void);

/// Receives keyCode and modifierFlags from an NSEvent keyDown.
/// Returns true to swallow the event, false to let AppKit handle it normally.
typedef bool (*PRXKeyHandler)(unsigned short keyCode,
                              unsigned long modifierFlags,
                              void *context);

/// Install a global keyDown NSEvent monitor (Mac Catalyst only). Used to
/// intercept keystrokes (notably Esc) that AppKit's NSWindow consumes
/// before UIKit's UIKeyCommand priority can apply. Returns an opaque token,
/// or NULL on non-macCatalyst builds / failure.
void *PRXInstallKeyDownMonitor(PRXKeyHandler handler, void *context);

/// Remove a monitor returned by PRXInstallKeyDownMonitor.
void PRXRemoveKeyDownMonitor(void *token);

/// Generic context-only callback used by the capture-mode auto-triggers.
typedef void (*PRXVoidCallback)(void *context);

/// Enable mouseMoved delivery on every NSWindow and install a local
/// NSEvent monitor that fires whenever the mouse moves inside one of the
/// app's windows. Used to engage VM input capture without requiring a
/// click. Returns an opaque token, or NULL on non-macCatalyst.
void *PRXInstallMouseMovedMonitor(PRXVoidCallback handler, void *context);

/// Remove a monitor returned by PRXInstallMouseMovedMonitor.
void PRXRemoveMouseMovedMonitor(void *token);

/// Subscribe to NSWindowDidEnterFullScreenNotification. Used to engage
/// VM input capture as soon as the macOS window goes fullscreen.
void *PRXObserveDidEnterFullScreen(PRXVoidCallback handler, void *context);

/// Remove an observer returned by PRXObserveDidEnterFullScreen.
void PRXRemoveFullScreenObserver(void *token);
