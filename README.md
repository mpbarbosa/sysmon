# sysmon

A shell desktop widget developed with **Quickshell** and **qmlls** to show CPU and memory consumption.

## Files

- `shell.qml`: Quickshell panel that renders CPU and memory usage.
- `scripts/sysmon.sh`: Linux metrics collector (reads `/proc/stat` and `/proc/meminfo`).

## Run

1. Ensure Quickshell is installed.
2. From this repository, run:

   ```bash
   quickshell -p shell.qml
   ```

## qmlls setup

Use your editor's QML language server (`qmlls`) with this repository opened at:

`<repository-root>`

so it can index `shell.qml` and provide completions/diagnostics.
