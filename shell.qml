import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property bool compositorChecked: false
    property bool wlroots: false
    property real cpuUsage: 0
    property real memoryUsage: 0
    property real diskUsage: 0
    property real cleanupEstimateBytes: 0
    property string cleanupEstimateFormatted: "0B"
    property bool cleanupEstimateAvailable: false
    property string cpuAccessibleName: "CPU usage: " + root.cpuUsage.toFixed(1) + "%"
    property string memoryAccessibleName: "Memory usage: " + root.memoryUsage.toFixed(1) + "%"
    property string diskAccessibleName: "Disk usage: " + root.diskUsage.toFixed(1) + "%"
    property string cleanupEstimateAccessibleName: {
        if (cleanupEstimateProcess.running) {
            return "Deletion estimate: calculating";
        }

        if (!root.cleanupEstimateAvailable) {
            return "Deletion estimate unavailable";
        }

        return "Deletion estimate: " + root.cleanupEstimateFormatted;
    }
    property string monitorScriptPath: {
        var url = Qt.resolvedUrl("scripts/sysmon.sh").toString();
        if (url.startsWith("file://")) {
            return decodeURIComponent(url.slice(7));
        }

        return url;
    }
    property string cleanupScriptPath: {
        var url = Qt.resolvedUrl("scripts/cleanup_cache.sh").toString();
        if (url.startsWith("file://")) {
            return decodeURIComponent(url.slice(7));
        }

        return url;
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

    function runCleanup() {
        if (cleanupProcess.running) {
            return;
        }

        cleanupProcess.running = true;
        cleanupEstimateRefreshTimer.restart();
    }

    function updateCleanupEstimate() {
        if (cleanupEstimateProcess.running) {
            return;
        }

        cleanupEstimateProcess.running = true;
    }

    onCompositorCheckedChanged: {
        if (!compositorChecked) {
            return;
        }

        var comp = wlroots ? panelWindowComponent : floatingWindowComponent;
        comp.createObject(root);
        updateUsage();
        updateCleanupEstimate();
    }

    // Detects wlroots compositor by checking SWAYSOCK and HYPRLAND_INSTANCE_SIGNATURE.
    Process {
        id: compositorCheck
        command: ["sh", "-c", "printf '%s:%s' \"${SWAYSOCK:-}\" \"${HYPRLAND_INSTANCE_SIGNATURE:-}\""]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var parts = text.trim().split(":");
                root.wlroots = parts[0] !== "" || parts[1] !== "";
                root.compositorChecked = true;
            }
        }
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
                    root.diskUsage = root.clampPercent(Number(payload.disk));
                } catch (error) {
                    console.error("Failed to parse metrics:", error);
                    root.cpuUsage = 0;
                    root.memoryUsage = 0;
                    root.diskUsage = 0;
                }
            }
        }
    }

    Process {
        id: cleanupProcess
        command: ["gnome-terminal", "--", "bash", root.cleanupScriptPath]
        running: false
    }

    Process {
        id: cleanupEstimateProcess
        command: ["bash", root.cleanupScriptPath, "--estimate-total-json"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var payload = JSON.parse(text.trim());
                    var bytes = Number(payload.bytes);
                    var formatted = String(payload.formatted || "");

                    if (!Number.isFinite(bytes) || formatted.length === 0) {
                        throw new Error("Invalid cleanup estimate payload");
                    }

                    root.cleanupEstimateBytes = Math.max(0, bytes);
                    root.cleanupEstimateFormatted = formatted;
                    root.cleanupEstimateAvailable = true;
                } catch (error) {
                    console.error("Failed to parse cleanup estimate:", error);
                    root.cleanupEstimateBytes = 0;
                    root.cleanupEstimateFormatted = "0B";
                    root.cleanupEstimateAvailable = false;
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

    Timer {
        interval: 60000
        running: root.compositorChecked
        repeat: true
        onTriggered: root.updateCleanupEstimate()
    }

    Timer {
        id: cleanupEstimateRefreshTimer
        interval: 15000
        repeat: false
        onTriggered: root.updateCleanupEstimate()
    }

    component SysmonContent: Rectangle {
        anchors.fill: parent
        radius: 10
        color: "#cc1e1e2e"
        border.color: "#665f7a"

        // The window binds its height to this, so adding or removing a row in the
        // column below needs no manual re-tuning. Margins count twice: top and bottom.
        implicitHeight: contentColumn.implicitHeight + contentColumn.anchors.margins * 2

        Column {
            id: contentColumn
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
                width: parent.width
                spacing: 6

                Text {
                    text: "CPU: " + root.cpuUsage.toFixed(1) + "%"
                    color: "#cdd6f4"
                    font.pixelSize: 13
                }

                ProgressBar {
                    from: 0
                    to: 1
                    value: Math.max(0, Math.min(1, root.clampPercent(root.cpuUsage) / 100))
                    width: parent.width
                    Accessible.name: root.cpuAccessibleName
                }

                Text {
                    text: "Memory: " + root.memoryUsage.toFixed(1) + "%"
                    color: "#cdd6f4"
                    font.pixelSize: 13
                }

                ProgressBar {
                    from: 0
                    to: 1
                    value: Math.max(0, Math.min(1, root.clampPercent(root.memoryUsage) / 100))
                    width: parent.width
                    Accessible.name: root.memoryAccessibleName
                }

                Text {
                    text: "Disk: " + root.diskUsage.toFixed(1) + "%"
                    color: "#cdd6f4"
                    font.pixelSize: 13
                }

                ProgressBar {
                    from: 0
                    to: 1
                    value: Math.max(0, Math.min(1, root.clampPercent(root.diskUsage) / 100))
                    width: parent.width
                    Accessible.name: root.diskAccessibleName
                }
            }

            Text {
                width: parent.width
                text: cleanupEstimateProcess.running
                    ? "Deletion estimate: calculating..."
                    : (root.cleanupEstimateAvailable
                        ? "Deletion estimate: " + root.cleanupEstimateFormatted
                        : "Deletion estimate: unavailable")
                color: "#bac2de"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Accessible.name: root.cleanupEstimateAccessibleName
            }

            Rectangle {
                width: parent.width
                height: 28
                radius: 6
                color: cleanupBtn.pressed ? "#6689b4fa" : (cleanupBtn.containsMouse ? "#4489b4fa" : "#2289b4fa")
                border.color: "#4489b4fa"

                Text {
                    anchors.centerIn: parent
                    text: "Clean Cache"
                    color: "#cdd6f4"
                    font.pixelSize: 12
                }

                MouseArea {
                    id: cleanupBtn
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.runCleanup()
                    Accessible.role: Accessible.Button
                    Accessible.name: "Run cache cleanup"
                }
            }
        }
    }

    // wlroots compositors (Sway, Hyprland): anchored panel via layershell.
    Component {
        id: panelWindowComponent
        PanelWindow {
            anchors {
                top: true
                right: true
            }
            margins {
                top: 12
                right: 12
            }
            implicitWidth: 260
            implicitHeight: panelContent.implicitHeight
            color: "transparent"

            SysmonContent { id: panelContent }
        }
    }

    // GNOME and other compositors: floating window without layershell.
    Component {
        id: floatingWindowComponent
        FloatingWindow {
            implicitWidth: 260
            implicitHeight: floatingContent.implicitHeight
            color: "transparent"

            SysmonContent { id: floatingContent }
        }
    }
}
