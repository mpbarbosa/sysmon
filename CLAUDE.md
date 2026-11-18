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

# Full interactive cleanup (needs a real TTY; 45 sections, ~48 y/N prompts)
bash scripts/cleanup_cache.sh

# The sections, numbered — the list is read from the script's own markers
bash scripts/cleanup_cache.sh --list-sections

# Run one section and nothing else, by number or by title substring
bash scripts/cleanup_cache.sh --only 44
bash scripts/cleanup_cache.sh --only worktree

# After adding a section: every one of them must still run on its own
for n in $(seq 1 45); do yes n | bash scripts/cleanup_cache.sh --only "$n" >/dev/null || echo "FAIL $n"; done
```

There is no lint or test runner. When iterating on QML, `timeout 8 quickshell -p shell.qml` is a useful smoke launch.

## Architecture

Three files form a strict producer/consumer contract; changing one side means changing the other.

- **`shell.qml`** — the entire UI. The root is a non-visual `Scope` that owns all state (`cpuUsage`, `memoryUsage`, `diskUsage`, `cleanupEstimate*`) and every `Process`/`Timer`. It does **not** create a window directly.
- **`scripts/sysmon.sh`** — the only metrics backend. Reads `/proc/stat` twice (0.1s apart for the CPU delta), `/proc/meminfo`, and `df -P /`. Emits one line of JSON with `cpu`, `memory`, `disk` keys, all percentages 0–100.
- **`scripts/cleanup_cache.sh`** — interactive cleanup, 45 numbered sections of top-level code. Modes: `--estimate-total-json` prints `{"bytes":N,"formatted":"..."}` and exits, `--list-sections` prints the sections, `--only <n|text>` runs just the matching ones, and no args runs the whole y/N walkthrough.

### Two patterns that are load-bearing — don't "simplify" them away

1. **Compositor detection picks the window type at runtime.** At startup `compositorCheck` reads `SWAYSOCK`/`HYPRLAND_INSTANCE_SIGNATURE`. If either is set → wlroots → `PanelWindow` (layer-shell, anchored top-right). Otherwise → `FloatingWindow` (GNOME, which has no layer-shell). Only the selected window is ever instantiated via `Component.createObject(root)` in `onCompositorCheckedChanged` — instantiating `PanelWindow` on GNOME produces an invisible window (`eglSwapBuffers` failure). The shared layout lives in the inline component `SysmonContent`, which both window types instantiate and which reads `root.*` directly as live bindings (no prop-drilling).

2. **The cleanup button launches a terminal, not a `Process` pipe.** `cleanup_cache.sh` uses `read -rp`; Quickshell `Process` wires stdin via a pipe, so `read` would hit EOF and silently skip every confirmation. The button runs `gnome-terminal -- bash <path>` so the script gets a real TTY. (`gnome-terminal` is hardcoded — a known portability gap for Sway/Hyprland users on `foot`/`alacritty`/`kitty`; see DESIGN.md Open Questions.)

### Conventions

- **JSON contract:** `sysmon.sh` stdout is one JSON object with `cpu`/`memory`/`disk`. `shell.qml` and DESIGN.md are authoritative. Rename a field → update both sides.
- **Never overlap polls.** `updateUsage()`/`updateCleanupEstimate()` no-op while their `Process.running` is already true. The 2s metrics timer and 60s estimate timer both rely on this.
- **Clamp and parse defensively in QML.** `clampPercent()` forces values into 0–100; any `JSON.parse` failure resets metrics to 0 rather than leaving stale UI.
- **Bash stays `/proc`-based and failure-tolerant.** Unreadable `/proc/stat` or `/proc/meminfo` emits zeroed metrics and exits 0 — never fail noisily.
- **Quit is a visible × in the title row**, not a right-click. `closeArea` calls `Qt.quit()` (`Quickshell.quit()` does not exist in 0.3.0). It replaced a right-click `MouseArea`: on the development machine `BTN_RIGHT` reached libinput but never reached *any* Quickshell window, layer-shell or `FloatingWindow`, while left clicks arrived at both. Don't reintroduce a right-click-only control without first confirming right-button events reach a window on the target compositor.
- **Section markers are structure, not decoration.** `--only` and `--list-sections` work by reading the `# ── <n>. <title> ──` comments out of the script's own text and sourcing the lines between one marker and the next. Renaming a marker changes what `--only` selects; dropping the `<n>.` prefix hides that section from both flags while the full walkthrough still runs it.
- **A section must run on its own.** Sections are top-level code, not functions, so one that reads a variable an earlier section set works in the full run and dies under `--only` on `unbound variable`. Two did: 28 read 27's `GHCUP_GHC_DIR` and 31 read 24's `GITHUB_DIR`, both now `${X:-default}`. Reading the code did not catch it — the loop in Commands above did, so run it after adding a section.
- **Nothing in the walkthrough may be fatal.** Every section is 1 of 45 and `set -e` is on, so an unguarded failure silently cancels every section after it. A refused `sudo` in section 26 ended a real run at 26 with nothing on screen to say why; each deletion now checks its own status, reports, and carries on.
- **The system tools here are not GNU.** `/usr/bin/readlink` and `stat` are uutils coreutils and `find` is `bfs`. uutils `readlink` stops at the first argument it cannot read, so one `readlink /proc/[0-9]*/cwd` over a /proc full of root-owned processes returned a truncated list under zsh and *nothing at all* under bash — exit 1, empty stderr, swallowed by `|| true` — which left section 44's liveness gate dead while its tests stayed green. It now reads cwds with `stat -c '%N'`: one exec, 0.03s, each argument reported independently, same output shape on GNU. `bfs` has no `-printf`, and a probe using it prints nothing, which reads exactly like "no matches" and will send you chasing the wrong bug. Check `readlink --version` / `find --version` before trusting a flag.
- **A guard that reads the live system must be tested through its reader.** `path_has_running_process` takes its cwd list as optional arguments, so every test fed it a synthetic list — proving the comparison and never the `/proc` read that supplies it in production. It is now fail-closed: an empty cwd list means the read failed, not that the machine is idle, because this script's own shell is always a process with a working directory. Test it by starting a real process in a real directory, and check both directions — a gate that always refuses is as useless as one that never does.
- **Path independence.** QML resolves script paths via `Qt.resolvedUrl(...)` from the QML file location, so the widget works regardless of the launching cwd. Don't assume the repo root.
- **Window height is derived, not hand-tuned.** `SysmonContent` exposes `implicitHeight` (its column's implicit height plus margins) and both window components bind their own `implicitHeight` to it. Adding or removing a row needs no height edit. Don't reintroduce a literal height: the window is a Wayland surface, so content that overflows it is silently cut off with no visual clue — that is how the "Clean Cache" button went missing when the disk row was added.

## Documentation map

- `DESIGN.md` — full design doc with rationale and rejected alternatives. Read this before changing the windowing or cleanup-launch logic.
- `CONTEXT.md` — domain vocabulary (Widget, Metric, wlroots compositor, Deletion estimate, Stale project). Use these terms; it lists words to avoid (panel, purge, freed space, etc.).
- `README.md` — user-facing run instructions and compositor table.
