# Design Doc: sysmon

**Author:** Marcelo Pereira Barbosa  
**Created:** 2026-06-08  
**Last Updated:** 2026-06-08  
**Status:** Implemented  

---

## Overview

`sysmon` is a lightweight Wayland desktop widget built with [Quickshell](https://quickshell.outfoxxed.me/) that displays live CPU, memory, and disk usage as progress bars, and provides a one-click button to launch an interactive cache cleanup script in a terminal window. It runs on both wlroots-based compositors (Sway, Hyprland) and GNOME Wayland by detecting the compositor at startup and choosing the appropriate window type.

---

## Background

Wayland compositors differ fundamentally in the window protocols they expose. wlroots-based compositors (Sway, Hyprland) implement `zwlr_layer_shell_v1`, which allows client applications to create panels anchored to screen edges. GNOME's compositor (mutter) deliberately does not implement this protocol and has no plans to do so.

A widget that hard-codes `PanelWindow` (Quickshell's layer-shell window type) works perfectly on wlroots but produces a black/invisible window on GNOME because no EGL surface is ever created. Conversely, a widget that uses only `FloatingWindow` works on GNOME but forfeits screen-edge anchoring and exclusive zones on wlroots.

---

## Goals

1. Display live CPU, memory, and disk (root filesystem) usage as labeled progress bars that update every 2 seconds.
2. Work correctly on wlroots compositors with the widget anchored to the top-right screen edge via the layer-shell protocol.
3. Work correctly on GNOME Wayland as a visible floating window, with no errors in the Quickshell log beyond a cosmetic D-Bus portal warning outside our control.
4. Provide a "Clean Cache" button that opens an interactive terminal session running `cleanup_cache.sh`, preserving the script's `y/N` prompts and colored output.
5. Share a single widget layout (`SysmonContent`) between both window types to avoid duplicating display logic.
6. Show the current cleanup deletion estimate in the widget before launching the interactive cleanup session.

---

## Non-Goals

- **Multi-monitor support.** The widget appears on one screen. `Variants` over `Quickshell.screens` is not used.
- **Network or GPU metrics.** Only CPU, memory, and disk (root filesystem) are monitored.
- **Configurable update interval or metric thresholds.** The 2-second poll interval and 0–100% scale are fixed.
- **Notifications or alerts.** No visual or system notification is triggered when a metric exceeds a threshold.
- **Historical graphs or time-series data.** Only the current sample is displayed.
- **Cross-platform support.** The widget reads Linux-specific `/proc/stat`, `/proc/meminfo`, and `df -P /`. Windows and macOS are not supported.
- **A configuration UI.** Settings (colors, margins, terminal emulator) are edited directly in `shell.qml`.

---

## Design

### Component overview

```
shell.qml  (Quickshell entry point)
│
├── Scope  (root — non-visual container, holds shared state)
│   ├── Process: compositorCheck     — detects compositor at startup
│   ├── Process: metricsProcess      — runs sysmon.sh, parses JSON
│   ├── Process: cleanupProcess      — launches gnome-terminal with cleanup_cache.sh
│   ├── Process: cleanupEstimateProcess — requests the current cleanup estimate
│   ├── Timer                        — fires updateUsage() every 2 s
│   ├── Timer                        — refreshes the cleanup estimate periodically
│   ├── component SysmonContent      — shared inline component (labels + bars + estimate + button)
│   ├── Component: panelWindowComponent   — PanelWindow for wlroots
│   └── Component: floatingWindowComponent — FloatingWindow for GNOME
│
scripts/
├── sysmon.sh          — collects CPU / memory / disk, emits JSON on stdout
└── cleanup_cache.sh   — interactive cache cleanup (requires a TTY)
```

### Compositor detection

At startup, `compositorCheck` runs:

```sh
printf '%s:%s' "${SWAYSOCK:-}" "${HYPRLAND_INSTANCE_SIGNATURE:-}"
```

If either environment variable is non-empty, the compositor is treated as wlroots-compatible and `PanelWindow` is created; otherwise `FloatingWindow` is created. Detection completes in under 50 ms (process fork + printf).

`Scope.onCompositorCheckedChanged` calls `Component.createObject(root)` with the selected component. The window that is not selected is never instantiated, which prevents `PanelWindow` from attempting layer-shell initialization on GNOME (the source of the `eglSwapBuffers` error).

### Metrics pipeline

`sysmon.sh` is the sole source of metric data. It reads `/proc/stat` twice with a 0.1 s sleep to compute a CPU usage delta, reads `/proc/meminfo` for memory, and calls `df -P /` for disk. It emits one line of JSON on stdout:

```json
{"cpu": 4.90, "memory": 14.49, "disk": 94.17}
```

All three values are percentages in the range 0–100.

`metricsProcess` (a Quickshell `Process`) starts the script and collects its stdout via `StdioCollector`. `onStreamFinished` parses the JSON and updates `root.cpuUsage`, `root.memoryUsage`, and `root.diskUsage`. A guard in `updateUsage()` prevents a new invocation while one is already running, ensuring invocations never overlap even if a run takes longer than 2 s.

Metric values are clamped with `clampPercent()` before assignment to guard against malformed `/proc` output returning values outside 0–100.

### Shared widget content (`SysmonContent`)

Both `PanelWindow` and `FloatingWindow` instantiate `SysmonContent`, an inline QML component defined at document scope. Because inline components are part of the enclosing document's scope, `SysmonContent` can reference `root.*` properties (e.g., `root.cpuUsage`) directly as live bindings without prop-drilling.

The layout is a `Column` containing a title, three label+`ProgressBar` pairs (CPU, Memory, Disk), a deletion estimate line, and a "Clean Cache" button.

### Cache cleanup button

`cleanup_cache.sh` is an interactive script: it calls `read -rp` approximately 20 times to prompt `y/N` before each deletion step. Quickshell's `Process` connects stdin/stdout via pipes rather than a TTY. Running the script through a pipe would cause `read -rp` to receive EOF, silently skipping all prompts.

The button therefore launches `gnome-terminal -- bash <path>`, which opens a new terminal window where the script runs interactively. `gnome-terminal` daemonizes immediately, so `cleanupProcess.running` returns to `false` within milliseconds of the click. A guard in `runCleanup()` prevents double-launch while the process object is briefly in the running state.

### Cleanup deletion estimate

The widget requests the current deletion estimate by running `cleanup_cache.sh --estimate-total-json` through a dedicated `Process`. The script emits one JSON object with a byte total and a formatted display string, which the QML layer parses into the estimate line shown above the cleanup button. A periodic timer refreshes that value so the widget stays reasonably current without embedding cleanup discovery logic in QML.

### Window sizing

`implicitWidth` is fixed at 260 px. `implicitHeight` is set explicitly on both window components (currently 224 px) to accommodate the layout: title (16 px) + three metric rows (label 13 px + progress bar ~20 px each, 6 px inner spacing) + deletion estimate text + "Clean Cache" button (28 px) + outer margins (12 px each side) + outer column spacing (10 px between items).

---

## Alternatives Considered

### FloatingWindow everywhere (no compositor detection)

Simpler: one window type, no startup process. Rejected because `FloatingWindow` on wlroots compositors cannot be anchored to a screen edge, cannot declare an exclusive zone to push maximized windows away, and does not appear on all workspaces. These are first-class features of `PanelWindow` + layer-shell that would be permanently lost.

### GNOME Shell extension for layer-shell support

GNOME does not implement `zwlr_layer_shell_v1` and has no extension that adds it. This path does not exist as of 2026.

### Loader instead of createObject for conditional windows

A `Loader` requires a visual parent (`Item` hierarchy) to function correctly. `Scope` is a non-visual QML object. `Component.createObject(root)` creates the window as a `QObject` child of `Scope` for lifecycle management, while the window itself registers as a top-level Wayland surface independently. This is the correct pattern when the root is non-visual.

### Free gigabytes instead of used percentage for disk

`free_gb` would require a different display widget (a `Text` label showing a number, not a `ProgressBar`). Reporting used percentage keeps all three metrics on the same 0–100 scale, allows `SysmonContent` to use identical `ProgressBar` logic for all three, and is consistent with how CPU and memory are already expressed.

### Running cleanup_cache.sh via Process (no terminal)

The script is interactive by design and cannot be made non-interactive without stripping its confirmation prompts — which would make every cleanup run fully automatic, a behavior the script explicitly avoids. Opening a terminal preserves the intent of the script.

---

## Open Questions

1. **Terminal emulator on wlroots.** The cleanup button is hardcoded to `gnome-terminal`. Users on Hyprland or Sway typically run `foot`, `alacritty`, or `kitty`. A `$TERMINAL` environment variable fallback or a configurable property in `shell.qml` would improve portability.

2. **sudo prompts in cleanup_cache.sh.** Section 28 (AWS CLI old versions) calls `sudo rm -rf`. When launched from the widget via `gnome-terminal`, the sudo prompt appears in the terminal window and works correctly. No special handling is needed, but this behavior is worth documenting for contributors who might consider running the script non-interactively.
