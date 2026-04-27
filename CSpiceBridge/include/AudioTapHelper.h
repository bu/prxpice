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
