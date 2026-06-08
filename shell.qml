import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

PanelWindow {
    id: root

    anchors {
        top: true
        right: true
    }

    margins {
        top: 12
        right: 12
    }

    implicitWidth: 260
    implicitHeight: 120
    color: "transparent"

    property real cpuUsage: 0
    property real memoryUsage: 0
    property string monitorScriptPath: {
        var url = Qt.resolvedUrl("scripts/sysmon.sh").toString();
        if (url.startsWith("file://")) {
            return decodeURIComponent(url.slice(7));
        }

        return url;
    }

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: "#cc1e1e2e"
        border.color: "#665f7a"

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10

            Text {
                text: "sysmon"
                color: "#cdd6f4"
                font.pixelSize: 16
                font.bold: true
            }

            Column {
                spacing: 6

                Text {
                    text: "CPU: " + root.cpuUsage.toFixed(1) + "%"
                    color: "#cdd6f4"
                    font.pixelSize: 13
                }

                ProgressBar {
                    from: 0
                    to: 1
                    value: root.clampPercent(root.cpuUsage) / 100
                    width: parent.width
                    Accessible.name: "CPU usage: " + root.cpuUsage.toFixed(1) + "%"
                }

                Text {
                    text: "Memory: " + root.memoryUsage.toFixed(1) + "%"
                    color: "#cdd6f4"
                    font.pixelSize: 13
                }

                ProgressBar {
                    from: 0
                    to: 1
                    value: root.clampPercent(root.memoryUsage) / 100
                    width: parent.width
                    Accessible.name: "Memory usage: " + root.memoryUsage.toFixed(1) + "%"
                }
            }
        }
    }

    function clampPercent(value) {
        if (!Number.isFinite(value)) {
            return 0;
        }

        return Math.max(0, Math.min(100, value));
    }

    function updateUsage() {
        if (metricsProcess.running) {
            return;
        }

        metricsProcess.running = true;
    }

    Process {
        id: metricsProcess
        command: ["bash", root.monitorScriptPath]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var payload = JSON.parse(text.trim());
                    root.cpuUsage = root.clampPercent(Number(payload.cpu));
                    root.memoryUsage = root.clampPercent(Number(payload.memory));
                } catch (error) {
                    console.error("Failed to parse metrics:", error);
                    root.cpuUsage = 0;
                    root.memoryUsage = 0;
                }
            }
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: root.updateUsage()
    }

    Component.onCompleted: root.updateUsage()
}
