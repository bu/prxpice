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

/// Receives right-mouse events. `pressed` is true for rightMouseDown,
/// false for rightMouseUp. Return true to swallow the event so AppKit's
/// context menu does not appear; return false to let it through (e.g.
/// when capture mode is off and the user is interacting with toolbar UI).
typedef bool (*PRXRightClickHandler)(bool pressed, void *context);

/// Install a local NSEvent monitor for rightMouseDown / rightMouseUp.
/// Used to forward real Mac right-clicks to the VM instead of letting
/// AppKit show its own context menu. Returns NULL on non-macCatalyst.
void *PRXInstallRightClickMonitor(PRXRightClickHandler handler, void *context);

/// Remove a monitor returned by PRXInstallRightClickMonitor.
void PRXRemoveRightClickMonitor(void *token);
