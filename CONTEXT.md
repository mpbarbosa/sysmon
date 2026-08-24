# sysmon

A Wayland desktop widget that displays live system metrics and provides a one-click cache cleanup.

## Language

### Widget

**Widget**:
The sysmon desktop application. Appears anchored to the top-right screen edge on compositors that support layer shell, or as an unanchored floating window on others.
_Avoid_: panel, app, overlay, shell

**Metric**:
A single system usage value expressed as a percentage in the range 0–100. The widget tracks three metrics: CPU, memory, and disk (root filesystem). Metrics are never expressed as absolute values.
_Avoid_: stat, reading, measurement

### Compositor

**wlroots compositor**:
A Wayland compositor built on the wlroots library — Sway, Hyprland — that implements the layer-shell protocol. The widget anchors itself to the screen edge only on wlroots compositors.
_Avoid_: wlr compositor, layer-shell compositor

**Layer shell**:
The Wayland protocol extension that lets a client window anchor itself to a screen edge and declare an exclusive zone. Implemented by wlroots compositors; GNOME does not support it.
_Avoid_: layershell, wlr-layer-shell (acceptable as code identifiers only)

**Compositor detection**:
The decision made at widget startup — before any window is created — of whether the active compositor supports layer shell. Determines which window type the widget instantiates for the session.
_Avoid_: compositor check, environment detection, window selection

### Cache cleanup

**Cache cleanup**:
An interactive terminal session that walks through a curated list of caches and disposable files, prompting the user to confirm each deletion. Launched from the widget's "Clean Cache" button.
_Avoid_: purge, disk cleanup, cleanup run

**Deletion estimate**:
The total storage occupied by the cleanup candidates for one prompt before anything is removed. It is a preview value, not a post-deletion measurement.
_Avoid_: freed space, reclaimed space, actual savings

**Cleanup candidate**:
A file system path selected by one cleanup step as eligible for removal. A cleanup candidate may be a file, directory, or symlink entry. Docker's on-disk storage is also a cleanup candidate despite not being a path: it is measured with `docker system df` rather than `du`.
_Avoid_: cache target, deletion target, removable item

**Stale project**:
A project directory that has had no file modifications in more than 30 days, excluding its `node_modules` subtree. The cache cleanup targets `node_modules` in stale projects to reclaim disk space.
_Avoid_: old project, inactive project, unused project
