# sysmon

A shell desktop widget developed with **Quickshell** and **qmlls** to show CPU and memory consumption.

## Files

- `/tmp/workspace/mpbarbosa/sysmon/shell.qml`: Quickshell panel that renders CPU and memory usage.
- `/tmp/workspace/mpbarbosa/sysmon/scripts/sysmon.sh`: Linux metrics collector (reads `/proc/stat` and `/proc/meminfo`).

## Run

1. Ensure Quickshell is installed.
2. From this repository, run:

   ```bash
   quickshell -p /tmp/workspace/mpbarbosa/sysmon/shell.qml
   ```

## qmlls setup

Use your editor's QML language server (`qmlls`) with this repository opened at:

`/tmp/workspace/mpbarbosa/sysmon`

so it can index `shell.qml` and provide completions/diagnostics.
