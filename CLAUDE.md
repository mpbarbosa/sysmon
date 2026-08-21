# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`sysmon` is a single-file Quickshell (Wayland) desktop widget that shows live CPU, memory, and disk usage as progress bars and offers a one-click interactive cache cleanup. There is no build system, no package manager, and no test suite — the codebase is `shell.qml` plus two Bash scripts.

## Commands

```bash
# Launch the widget (from repo root, paths in QML resolve relative to shell.qml)
quickshell -p shell.qml

# Smallest behavior check for the metrics backend — must print one line of JSON
bash scripts/sysmon.sh
# → {"cpu":4.90,"memory":14.49,"disk":94.17}

# What the widget calls to populate the deletion estimate line
bash scripts/cleanup_cache.sh --estimate-total-json
# → {"bytes":12345,"formatted":"12K"}

# Full interactive cleanup (needs a real TTY; prompts y/N ~20 times)
bash scripts/cleanup_cache.sh
```

There is no lint or test runner. When iterating on QML, `timeout 8 quickshell -p shell.qml` is a useful smoke launch.

## Architecture

Three files form a strict producer/consumer contract; changing one side means changing the other.

- **`shell.qml`** — the entire UI. The root is a non-visual `Scope` that owns all state (`cpuUsage`, `memoryUsage`, `diskUsage`, `cleanupEstimate*`) and every `Process`/`Timer`. It does **not** create a window directly.
- **`scripts/sysmon.sh`** — the only metrics backend. Reads `/proc/stat` twice (0.1s apart for the CPU delta), `/proc/meminfo`, and `df -P /`. Emits one line of JSON with `cpu`, `memory`, `disk` keys, all percentages 0–100.
- **`scripts/cleanup_cache.sh`** — interactive cleanup (~1300 lines). Dual-mode: with `--estimate-total-json` it prints `{"bytes":N,"formatted":"..."}` and exits; with no args it runs the interactive y/N walkthrough.

### Two patterns that are load-bearing — don't "simplify" them away

1. **Compositor detection picks the window type at runtime.** At startup `compositorCheck` reads `SWAYSOCK`/`HYPRLAND_INSTANCE_SIGNATURE`. If either is set → wlroots → `PanelWindow` (layer-shell, anchored top-right). Otherwise → `FloatingWindow` (GNOME, which has no layer-shell). Only the selected window is ever instantiated via `Component.createObject(root)` in `onCompositorCheckedChanged` — instantiating `PanelWindow` on GNOME produces an invisible window (`eglSwapBuffers` failure). The shared layout lives in the inline component `SysmonContent`, which both window types instantiate and which reads `root.*` directly as live bindings (no prop-drilling).

2. **The cleanup button launches a terminal, not a `Process` pipe.** `cleanup_cache.sh` uses `read -rp`; Quickshell `Process` wires stdin via a pipe, so `read` would hit EOF and silently skip every confirmation. The button runs `gnome-terminal -- bash <path>` so the script gets a real TTY. (`gnome-terminal` is hardcoded — a known portability gap for Sway/Hyprland users on `foot`/`alacritty`/`kitty`; see DESIGN.md Open Questions.)

### Conventions

- **JSON contract:** `sysmon.sh` stdout is one JSON object with `cpu`/`memory`/`disk`. (Note: `.github/copilot-instructions.md` predates the disk metric and only mentions cpu/memory — `shell.qml` and DESIGN.md are authoritative.) Rename a field → update both sides.
- **Never overlap polls.** `updateUsage()`/`updateCleanupEstimate()` no-op while their `Process.running` is already true. The 2s metrics timer and 60s estimate timer both rely on this.
- **Clamp and parse defensively in QML.** `clampPercent()` forces values into 0–100; any `JSON.parse` failure resets metrics to 0 rather than leaving stale UI.
- **Bash stays `/proc`-based and failure-tolerant.** Unreadable `/proc/stat` or `/proc/meminfo` emits zeroed metrics and exits 0 — never fail noisily.
- **Right-click-to-quit depends on declaration order.** The quit `MouseArea` is declared before `contentColumn` so it sits *beneath* the cleanup button. It takes only `Qt.RightButton`; the cleanup button takes only the left. Moving it after the column, or widening its `acceptedButtons`, breaks the cleanup button's left click or hover. `Qt.quit()` is the call — `Quickshell.quit()` does not exist in 0.3.0.
- **Path independence.** QML resolves script paths via `Qt.resolvedUrl(...)` from the QML file location, so the widget works regardless of the launching cwd. Don't assume the repo root.
- **Window height is derived, not hand-tuned.** `SysmonContent` exposes `implicitHeight` (its column's implicit height plus margins) and both window components bind their own `implicitHeight` to it. Adding or removing a row needs no height edit. Don't reintroduce a literal height: the window is a Wayland surface, so content that overflows it is silently cut off with no visual clue — that is how the "Clean Cache" button went missing when the disk row was added.

## Documentation map

- `DESIGN.md` — full design doc with rationale and rejected alternatives. Read this before changing the windowing or cleanup-launch logic.
- `CONTEXT.md` — domain vocabulary (Widget, Metric, wlroots compositor, Deletion estimate, Stale project). Use these terms; it lists words to avoid (panel, purge, freed space, etc.).
- `README.md` — user-facing run instructions and compositor table.
