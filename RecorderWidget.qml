import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    PluginGlobalVar { id: stateVar; varName: "state"; defaultValue: "idle" }
    PluginGlobalVar { id: elapsedVar; varName: "elapsed"; defaultValue: 0 }
    PluginGlobalVar { id: backendVar; varName: "backend"; defaultValue: "" }
    PluginGlobalVar { id: lastFileVar; varName: "lastFile"; defaultValue: "" }
    PluginGlobalVar { id: errorVar; varName: "error"; defaultValue: "" }
    PluginGlobalVar { id: canvasVar; varName: "canvas"; defaultValue: "" }

    readonly property string state: stateVar.value || "idle"
    readonly property int elapsed: elapsedVar.value || 0
    readonly property string backend: backendVar.value || ""
    readonly property string lastFile: lastFileVar.value || ""
    readonly property string canvas: canvasVar.value || ""
    readonly property bool active: state !== "idle"

    property bool _confirmStop: false

    // ── Helpers ────────────────────────────────────────────────────────────
    function call(fn) {
        Quickshell.execDetached([Proc.dmsBin, "ipc", "call", "dankRecorder", fn]);
    }

    function formatTime(seconds) {
        const s = Math.max(0, seconds);
        const h = Math.floor(s / 3600);
        const m = Math.floor((s % 3600) / 60);
        const sec = s % 60;
        const pad = n => (n < 10 ? "0" : "") + n;
        return h > 0 ? h + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec);
    }

    readonly property string stateIcon: {
        switch (state) {
        case "resolving": return "progress_activity";
        case "armed": return "check_circle";
        case "starting": return "progress_activity";
        case "recording": return "stop_circle";
        case "paused": return "pause_circle";
        case "stopping": return "progress_activity";
        default: return "videocam";
        }
    }

    readonly property string primaryActionText: {
        if (state === "resolving") return I18n.trFor("dankRecorder", "Cancel");
        if (state === "armed") return I18n.trFor("dankRecorder", "Start recording");
        if (active) return I18n.trFor("dankRecorder", "Stop");
        return I18n.trFor("dankRecorder", "Start");
    }

    readonly property string statusText: {
        switch (state) {
        case "resolving": return I18n.trFor("dankRecorder", "Choosing capture area…");
        case "armed": return I18n.trFor("dankRecorder", "Confirm") + (canvas ? " · " + canvas : "");
        case "starting": return I18n.trFor("dankRecorder", "Starting…");
        case "recording": return I18n.trFor("dankRecorder", "Recording") + " · " + formatTime(elapsed);
        case "paused": return I18n.trFor("dankRecorder", "Paused") + " · " + formatTime(elapsed);
        case "stopping": return I18n.trFor("dankRecorder", "Saving…");
        default: return lastFile ? I18n.trFor("dankRecorder", "Ready") : I18n.trFor("dankRecorder", "Tap to record");
        }
    }

    function toggleRecord() {
        if (state === "resolving") {
            call("stop");
            return;
        }
        if (state === "armed") {
            call("confirm");
            return;
        }
        if (state === "idle") {
            call("start");
            return;
        }
        if (state === "starting" || state === "stopping")
            return;
        if (!_confirmStop) {
            _confirmStop = true;
            confirmTimer.restart();
            return;
        }
        confirmTimer.stop();
        _confirmStop = false;
        call("stop");
    }

    Timer {
        id: confirmTimer
        interval: 3000
        repeat: false
        onTriggered: root._confirmStop = false
    }

    // ── Bar pill ───────────────────────────────────────────────────────────
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            Item {
                id: horizontalIconSlot
                readonly property int glyphSize: Theme.barIconSize(root.barThickness, -4, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                readonly property bool loading: root.state === "resolving" || root.state === "starting" || root.state === "stopping"
                width: glyphSize
                height: glyphSize
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    anchors.centerIn: parent
                    visible: !horizontalIconSlot.loading
                    name: root._confirmStop ? "stop_circle" : root.stateIcon
                    size: horizontalIconSlot.glyphSize
                    color: root._confirmStop ? Theme.warning
                        : root.state === "recording" ? Theme.error
                        : root.state === "paused" ? Theme.warning
                        : root.state === "idle" ? Theme.widgetIconColor
                        : Theme.primary
                }

                DankIcon {
                    id: horizontalSpinner
                    anchors.centerIn: parent
                    visible: horizontalIconSlot.loading
                    name: "progress_activity"
                    size: horizontalIconSlot.glyphSize
                    color: Theme.primary

                    RotationAnimator on rotation {
                        running: horizontalSpinner.visible
                        from: 0
                        to: 360
                        duration: 900
                        loops: Animation.Infinite
                    }
                }
            }

            StyledText {
                visible: root.active
                anchors.verticalCenter: parent.verticalCenter
                text: root._confirmStop ? I18n.trFor("dankRecorder", "Stop?")
                    : root.state === "resolving" ? I18n.trFor("dankRecorder", "Choosing…")
                    : root.state === "armed" ? I18n.trFor("dankRecorder", "Start?")
                    : root.formatTime(root.elapsed)
                color: root._confirmStop ? Theme.warning : Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            Item {
                id: verticalIconSlot
                readonly property int glyphSize: Theme.barIconSize(root.barThickness, -4, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                readonly property bool loading: root.state === "resolving" || root.state === "starting" || root.state === "stopping"
                width: glyphSize
                height: glyphSize
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    anchors.centerIn: parent
                    visible: !verticalIconSlot.loading
                    name: root._confirmStop ? "stop_circle" : root.stateIcon
                    size: verticalIconSlot.glyphSize
                    color: root._confirmStop ? Theme.warning
                        : root.state === "recording" ? Theme.error
                        : root.state === "paused" ? Theme.warning
                        : root.state === "idle" ? Theme.widgetIconColor
                        : Theme.primary
                }

                DankIcon {
                    id: verticalSpinner
                    anchors.centerIn: parent
                    visible: verticalIconSlot.loading
                    name: "progress_activity"
                    size: verticalIconSlot.glyphSize
                    color: Theme.primary

                    RotationAnimator on rotation {
                        running: verticalSpinner.visible
                        from: 0
                        to: 360
                        duration: 900
                        loops: Animation.Infinite
                    }
                }
            }

            StyledText {
                visible: root.active && root.state !== "armed" && root.state !== "resolving"
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.formatTime(root.elapsed)
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
            }
        }
    }

    // ── Popout ─────────────────────────────────────────────────────────────
    popoutWidth: 340

    popoutContent: Component {
        Item {
            id: popout
            width: 340
            implicitWidth: width
            implicitHeight: content.implicitHeight + Theme.spacingM * 2
            property var closePopout: null

            Column {
                id: content
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                Item {
                    width: parent.width
                    height: title.implicitHeight

                    Column {
                        id: title
                        anchors.fill: parent
                        spacing: 2

                        StyledText {
                            width: parent.width
                            text: root.active ? root.statusText : I18n.trFor("dankRecorder", "Screen recording")
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Bold
                            color: root.state === "recording" ? Theme.error : Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            text: root.active
                                ? (root.backend || I18n.trFor("dankRecorder", "Recording in progress"))
                                : I18n.trFor("dankRecorder", "Choose what you want to capture")
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    Rectangle {
                        width: 28
                        height: 28
                        radius: width / 2
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        color: closeArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.12) : "transparent"

                        DankIcon {
                            anchors.centerIn: parent
                            name: "close"
                            size: Theme.iconSize - 6
                            color: Theme.surfaceVariantText
                        }

                        MouseArea {
                            id: closeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (popout.closePopout)
                                    popout.closePopout();
                            }
                        }
                    }
                }

                Row {
                    visible: root.state === "idle"
                    width: parent.width
                    spacing: Theme.spacingS

                    Rectangle {
                        width: (parent.width - parent.spacing) / 2
                        height: 112
                        radius: Theme.cornerRadius
                        color: fullScreenArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.86) : Theme.primary

                        Column {
                            width: parent.width
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                anchors.horizontalCenter: parent.horizontalCenter
                                name: "desktop_windows"
                                size: Theme.iconSize + 2
                                color: Theme.primaryText
                            }

                            StyledText {
                                width: parent.width
                                text: I18n.trFor("dankRecorder", "Full screen")
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.primaryText
                            }

                            StyledText {
                                width: parent.width
                                text: I18n.trFor("dankRecorder", "Record this display")
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.primaryText
                                opacity: 0.82
                            }
                        }

                        MouseArea {
                            id: fullScreenArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.call("startFullscreen");
                                if (popout.closePopout)
                                    popout.closePopout();
                            }
                        }
                    }

                    Rectangle {
                        width: (parent.width - parent.spacing) / 2
                        height: 112
                        radius: Theme.cornerRadius
                        color: regionArea.containsMouse ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.outline, regionArea.containsMouse ? 0.7 : 0.35)

                        Column {
                            width: parent.width
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                anchors.horizontalCenter: parent.horizontalCenter
                                name: "crop_square"
                                size: Theme.iconSize + 2
                                color: Theme.surfaceText
                            }

                            StyledText {
                                width: parent.width
                                text: I18n.trFor("dankRecorder", "Region")
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                            }

                            StyledText {
                                width: parent.width
                                text: I18n.trFor("dankRecorder", "Select an area")
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }
                        }

                        MouseArea {
                            id: regionArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.call("startRegion");
                                if (popout.closePopout)
                                    popout.closePopout();
                            }
                        }
                    }
                }

                Row {
                    visible: root.state !== "idle"
                    width: parent.width
                    spacing: Theme.spacingS

                    DankButton {
                        width: (parent.width - parent.spacing) / 2
                        text: root.state === "recording" || root.state === "paused"
                            ? (root._confirmStop ? I18n.trFor("dankRecorder", "Stop?") : I18n.trFor("dankRecorder", "Stop recording"))
                            : root.state === "armed" ? I18n.trFor("dankRecorder", "Start recording")
                            : I18n.trFor("dankRecorder", "Cancel")
                        enabled: root.state !== "starting" && root.state !== "stopping"
                        backgroundColor: root.state === "recording" || root.state === "paused" ? Theme.error : Theme.primary
                        textColor: Theme.primaryText
                        onClicked: {
                            if (root.state === "armed") {
                                root.call("confirm");
                                if (popout.closePopout)
                                    popout.closePopout();
                            } else if (root.state === "resolving") {
                                root.call("stop");
                            } else {
                                confirmTimer.stop();
                                root._confirmStop = false;
                                root.call("stop");
                            }
                        }
                    }

                    DankButton {
                        width: (parent.width - parent.spacing) / 2
                        visible: root.state === "recording" || root.state === "paused"
                        text: root.state === "paused" ? I18n.trFor("dankRecorder", "Resume") : I18n.trFor("dankRecorder", "Pause")
                        onClicked: root.call("pause")
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    DankButton {
                        width: root.lastFile.length > 0 ? (parent.width - parent.spacing) / 2 : parent.width
                        text: I18n.trFor("dankRecorder", "Open recordings")
                        backgroundColor: "transparent"
                        textColor: Theme.surfaceVariantText
                        onClicked: root.call("openFolder")
                    }

                    DankButton {
                        width: parent.width / 2
                        visible: root.lastFile.length > 0
                        text: I18n.trFor("dankRecorder", "Open latest")
                        backgroundColor: "transparent"
                        textColor: Theme.surfaceVariantText
                        onClicked: root.call("openLast")
                    }
                }

                StyledText {
                    visible: (errorVar.value || "").length > 0
                    width: parent.width
                    text: errorVar.value || ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }
        }
    }

    // ── Control center tile ────────────────────────────────────────────────
    ccWidgetIcon: root.stateIcon
    ccWidgetPrimaryText: I18n.trFor("dankRecorder", "Dank Recorder")
    ccWidgetSecondaryText: root.statusText
    ccWidgetIsActive: root.active
    ccWidgetIsToggle: true
    onCcWidgetToggled: root.toggleRecord()
}
