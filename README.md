# sysmon

A Wayland desktop widget developed with **Quickshell** that displays live CPU, memory, and disk metrics, and offers a one-click cache cleanup.

**Version:** `v1.0.0-alpha`

## Files

- `shell.qml`: the widget — renders the three metrics as progress bars, plus the deletion estimate and the "Clean Cache" button.
- `scripts/sysmon.sh`: metrics collector. Reads `/proc/stat`, `/proc/meminfo`, and `df -P /`, and emits one line of JSON.
- `scripts/cleanup_cache.sh`: the cache cleanup. Walks a curated list of caches and disposable files, prompting before each deletion.

## Metrics

Each metric is a percentage in the range 0–100, refreshed every 2 seconds.

| Metric | Source | Notes |
|---|---|---|
| CPU | `/proc/stat` | Sampled twice 0.1 s apart to compute a usage delta. |
| Memory | `/proc/meminfo` | Used share of `MemTotal`, based on `MemAvailable`. |
| Disk | `df -P /` | Root filesystem only. Matches df's `Use%` column. |

## Cache cleanup

The widget shows a **deletion estimate** — the total storage occupied by the current cleanup candidates, refreshed periodically. It is a preview of what the cleanup would remove, not a post-deletion measurement.

The "Clean Cache" button opens the cleanup in a new terminal window, where it prompts for confirmation before each deletion. A terminal is required because the cleanup is interactive; it is currently hardcoded to `gnome-terminal`.

## Run

1. Ensure Quickshell is installed.
2. From this repository, run:

   ```bash
   quickshell -p shell.qml
   ```

The compositor is detected automatically at startup:

| Compositor | Window type | Positioning |
|---|---|---|
| Sway, Hyprland (wlroots) | `PanelWindow` via layer shell | Anchored to top-right edge |
| GNOME, other | `FloatingWindow` fallback | Floating (position by window manager) |

Detection checks `SWAYSOCK` and `HYPRLAND_INSTANCE_SIGNATURE` environment variables.

## qmlls setup

Use your editor's QML language server (`qmlls`) with this repository opened at:

`<repository-root>`

so it can index `shell.qml` and provide completions/diagnostics.
