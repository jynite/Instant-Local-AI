pragma ComponentBehavior: Bound
// SPDX-FileCopyrightText: Copyright (c) 2026 saj
// SPDX-License-Identifier: MIT
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    required property var controller
    visible: true
    width: 1280
    height: 820
    minimumWidth: 860
    minimumHeight: 620
    title: "JYNERATION · Ollama Control HUD"

    property int currentPage: 0
    readonly property var controllerRef: controller
    readonly property bool compactNav: width < 1040
    readonly property color bg: "#040907"
    readonly property color sidebar: "#06100c"
    readonly property color surface: "#08130f"
    readonly property color raised: "#0d1d16"
    readonly property color line: "#173428"
    readonly property color ink: "#eaf5f0"
    readonly property color muted: "#91a79c"
    readonly property color accent: "#72ddb7"
    readonly property color accentSoft: "#123b2d"
    readonly property color warning: "#d6ad68"
    readonly property color danger: "#e0828a"
    readonly property color quiet: "#62786d"
    readonly property string uiFont: "Segoe UI"
    readonly property string monoFont: "Consolas"

    function statusColor(value) {
        var text = String(value || "").toUpperCase()
        if (text.indexOf("ERROR") >= 0 || text.indexOf("FAILED") >= 0 || text.indexOf("DOWN") >= 0)
            return danger
        if (text.indexOf("START") >= 0 || text.indexOf("STOPPING") >= 0 || text.indexOf("RESTART") >= 0 || text.indexOf("WAIT") >= 0)
            return warning
        if (text === "RUNNING" || text === "ONLINE" || text === "SUCCESS" || text === "READY" || text.indexOf("LOADED") >= 0)
            return accent
        return quiet
    }

    function displayStatus(row) {
        return row && row.pending ? row.pending : (row ? row.value : "WAITING")
    }

    function serviceValue(name) {
        if (!controllerRef)
            return "WAITING"
        var rows = controllerRef.statusRows
        for (var i = 0; i < rows.length; ++i)
            if (rows[i].name === name)
                return displayStatus(rows[i])
        return "UNKNOWN"
    }

    function detailValue(key, fallback) {
        if (!controllerRef || !controllerRef.details)
            return fallback
        var value = controllerRef.details[key]
        return value === undefined || value === null || String(value).length === 0 ? fallback : String(value)
    }

    function currentModelIndex() {
        if (!controllerRef)
            return -1
        var items = controllerRef.models
        var configured = detailValue("model", "")
        for (var i = 0; i < items.length; ++i)
            if (items[i].selected || items[i].name === configured)
                return i
        return items.length > 0 ? 0 : -1
    }

    function modelSummary(index) {
        if (!controllerRef || index < 0 || index >= controllerRef.models.length)
            return "Ollama is starting. Installed models will appear here."
        var item = controllerRef.models[index]
        var parts = [item.size, item.parameters, item.quantization].filter(function(value) { return String(value || "").length > 0 })
        return parts.length > 0 ? parts.join("  |  ") : "Installed locally"
    }

    function pageTitle() {
        return ["Runtime", "Operations", "About"][currentPage]
    }

    function pageSubtitle() {
        return [
            "Services and model selection in one place.",
            "Start, inspect, measure, and recover the local stack.",
            "Build details, credits, and local recovery tools."
        ][currentPage]
    }

    background: Rectangle { color: window.bg }

    component Surface: Rectangle {
        color: window.surface
        radius: 12
        border.width: 1
        border.color: window.line
    }

    component NavButton: Button {
        id: navControl
        property string label: ""
        property string compactLabel: ""
        property bool selected: false
        text: label
        Accessible.name: label
        Layout.fillWidth: true
        Layout.preferredHeight: 46
        leftPadding: window.compactNav ? 0 : 18
        rightPadding: window.compactNav ? 0 : 14
        contentItem: Label {
            text: window.compactNav ? navControl.compactLabel : navControl.label
            color: navControl.selected ? window.ink : window.muted
            font.family: window.uiFont
            font.pixelSize: window.compactNav ? 12 : 14
            font.bold: navControl.selected
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: window.compactNav ? Text.AlignHCenter : Text.AlignLeft
        }
        background: Rectangle {
            radius: 8
            color: navControl.selected ? window.accentSoft : (navControl.hovered ? window.raised : "transparent")
            border.width: navControl.activeFocus ? 1 : 0
            border.color: window.accent
            Rectangle {
                visible: navControl.selected
                width: 3
                height: 22
                radius: 2
                color: window.accent
                anchors.left: parent.left
                anchors.leftMargin: 5
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    component ActionButton: Button {
        id: actionControl
        property string command: ""
        property bool primary: false
        property bool destructive: false
        Accessible.name: text
        enabled: !!window.controllerRef && !window.controllerRef.busy
        implicitHeight: 40
        leftPadding: 16
        rightPadding: 16
        onClicked: if (window.controllerRef) window.controllerRef.run(command)
        contentItem: Label {
            text: actionControl.text
            color: actionControl.primary ? "#06100c" : (actionControl.destructive ? window.danger : window.ink)
            font.family: window.uiFont
            font.pixelSize: 13
            font.bold: actionControl.primary
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            radius: 8
            color: actionControl.primary
                   ? (actionControl.pressed ? "#58caa3" : window.accent)
                   : (actionControl.pressed ? window.accentSoft : (actionControl.hovered ? window.raised : window.surface))
            border.width: 1
            border.color: actionControl.activeFocus
                          ? window.accent
                          : (actionControl.destructive ? "#5a2a31" : window.line)
            scale: actionControl.pressed ? 0.98 : 1
            Behavior on scale { NumberAnimation { duration: 90 } }
        }
    }

    component StatusChip: Rectangle {
        id: chip
        property string value: "WAITING"
        implicitWidth: Math.min(190, chipLabel.implicitWidth + 22)
        implicitHeight: 28
        radius: 14
        color: Qt.rgba(window.statusColor(value).r, window.statusColor(value).g, window.statusColor(value).b, 0.12)
        border.width: 1
        border.color: Qt.rgba(window.statusColor(value).r, window.statusColor(value).g, window.statusColor(value).b, 0.34)
        Label {
            id: chipLabel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 11
            anchors.rightMargin: 11
            text: chip.value
            color: window.statusColor(chip.value)
            font.family: window.monoFont
            font.pixelSize: 10
            font.bold: true
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }
    }

    component CommandGroup: Surface {
        id: group
        property string heading: ""
        property string description: ""
        default property alias commands: commandGrid.data
        implicitHeight: groupColumn.implicitHeight + 36
        ColumnLayout {
            id: groupColumn
            anchors.fill: parent
            anchors.margins: 18
            spacing: 12
            Label {
                text: group.heading
                color: window.ink
                font.family: window.uiFont
                font.pixelSize: 17
                font.bold: true
            }
            Label {
                text: group.description
                color: window.muted
                font.family: window.uiFont
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            GridLayout {
                id: commandGrid
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 8
                rowSpacing: 8
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: window.compactNav ? 78 : 232
            color: window.sidebar
            border.width: 0
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: window.compactNav ? 12 : 18
                spacing: 7

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 64
                    RowLayout {
                        anchors.fill: parent
                        spacing: 12
                        Rectangle {
                            Layout.preferredWidth: 38
                            Layout.preferredHeight: 38
                            radius: 10
                            color: window.accent
                            Label {
                                anchors.centerIn: parent
                                text: "J"
                                color: "#06100c"
                                font.family: window.uiFont
                                font.pixelSize: 21
                                font.bold: true
                            }
                        }
                        ColumnLayout {
                            visible: !window.compactNav
                            spacing: 2
                            Label {
                                text: "JYNERATION"
                                color: window.ink
                                font.family: window.uiFont
                                font.pixelSize: 15
                                font.bold: true
                                font.letterSpacing: 1
                            }
                            Label {
                                text: "OLLAMA CONTROL HUD"
                                color: window.muted
                                font.family: window.uiFont
                                font.pixelSize: 9
                                font.letterSpacing: 0.8
                            }
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: window.line; Layout.bottomMargin: 9 }
                NavButton { label: "Runtime"; compactLabel: "01"; selected: window.currentPage === 0; onClicked: window.currentPage = 0 }
                NavButton { label: "Operations"; compactLabel: "02"; selected: window.currentPage === 1; onClicked: window.currentPage = 1 }
                NavButton { label: "About"; compactLabel: "03"; selected: window.currentPage === 2; onClicked: window.currentPage = 2 }
                Item { Layout.fillHeight: true }

                Surface {
                    visible: !window.compactNav
                    Layout.fillWidth: true
                    Layout.preferredHeight: 72
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 3
                        Label { text: "BETA"; color: window.accent; font.family: window.monoFont; font.pixelSize: 10; font.bold: true }
                        Label { text: window.controllerRef ? window.controllerRef.lastResult : "Loading"; color: window.muted; font.family: window.uiFont; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: window.bg

            ColumnLayout {
                anchors.fill: parent
                anchors.leftMargin: window.compactNav ? 22 : 30
                anchors.rightMargin: window.compactNav ? 22 : 30
                anchors.topMargin: 24
                anchors.bottomMargin: 24
                spacing: 16

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Label {
                            text: window.pageTitle()
                            color: window.ink
                            font.family: window.uiFont
                            font.pixelSize: 28
                            font.bold: true
                        }
                        Label {
                            text: window.pageSubtitle()
                            color: window.muted
                            font.family: window.uiFont
                            font.pixelSize: 13
                        }
                    }
                    ColumnLayout {
                        spacing: 2
                        Label { text: "LAST SYNC"; color: window.quiet; font.family: window.monoFont; font.pixelSize: 9; horizontalAlignment: Text.AlignRight; Layout.alignment: Qt.AlignRight }
                        Label { text: window.controllerRef ? window.controllerRef.lastSync : "Not synchronized"; color: window.muted; font.family: window.monoFont; font.pixelSize: 11; Layout.alignment: Qt.AlignRight }
                    }
                    ActionButton {
                        text: "Activity"
                        command: ""
                        enabled: true
                        onClicked: activityDrawer.open()
                    }
                    ActionButton { text: "Refresh"; command: "refresh"; primary: true }
                }

                Surface {
                    id: operationBanner
                    Layout.fillWidth: true
                    Layout.preferredHeight: 78
                    color: window.controllerRef && window.controllerRef.hasError ? "#1a0f11" : window.surface
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 18
                        anchors.rightMargin: 18
                        anchors.topMargin: 12
                        anchors.bottomMargin: 12
                        spacing: 14
                        Rectangle {
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 36
                            radius: 4
                            color: window.statusColor(window.controllerRef ? window.controllerRef.operationState : "WAITING")
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3
                            Label {
                                text: window.controllerRef ? window.controllerRef.operationTitle : "Loading runtime state"
                                color: window.ink
                                font.family: window.uiFont
                                font.pixelSize: 15
                                font.bold: true
                            }
                            Label {
                                text: window.controllerRef ? window.controllerRef.operationPhase : "Reading local services"
                                color: window.muted
                                font.family: window.uiFont
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                        StatusChip { value: window.controllerRef ? window.controllerRef.operationState.toUpperCase() : "WAITING" }
                        ActionButton {
                            visible: window.controllerRef ? window.controllerRef.busy : false
                            text: "Cancel"
                            command: ""
                            destructive: true
                            enabled: visible
                            onClicked: window.controllerRef.cancel()
                        }
                    }
                    Rectangle {
                        id: progressTrack
                        visible: window.controllerRef ? window.controllerRef.busy : false
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 1
                        anchors.rightMargin: 1
                        height: 3
                        color: window.accentSoft
                        clip: true
                        Rectangle {
                            id: progressSweep
                            width: Math.max(90, progressTrack.width * 0.28)
                            height: parent.height
                            radius: 2
                            color: window.accent
                        }
                        SequentialAnimation {
                            running: window.controllerRef ? window.controllerRef.busy : false
                            loops: Animation.Infinite
                            NumberAnimation {
                                target: progressSweep
                                property: "x"
                                from: -progressSweep.width
                                to: progressTrack.width
                                duration: 1050
                                easing.type: Easing.InOutCubic
                            }
                            PauseAnimation { duration: 90 }
                            onStopped: progressSweep.x = -progressSweep.width
                        }
                    }
                }

                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: window.currentPage

                    Item {
                        id: overviewPage
                        objectName: "OverviewPage"
                        ScrollView {
                            anchors.fill: parent
                            clip: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            ColumnLayout {
                                width: overviewPage.width
                                spacing: 14

                                Surface {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: window.width < 1120 ? 610 : 334
                                    GridLayout {
                                        anchors.fill: parent
                                        anchors.margins: 20
                                        columns: window.width < 1120 ? 1 : 2
                                        columnSpacing: 28
                                        rowSpacing: 18

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            spacing: 0
                                            RowLayout {
                                                Layout.fillWidth: true
                                                Layout.bottomMargin: 10
                                                Label { text: "Services"; color: window.ink; font.family: window.uiFont; font.pixelSize: 18; font.bold: true; Layout.fillWidth: true }
                                                Label { text: "LIVE"; color: window.accent; font.family: window.monoFont; font.pixelSize: 9; font.bold: true }
                                            }
                                            Repeater {
                                                model: window.controllerRef ? window.controllerRef.statusRows : []
                                                delegate: Item {
                                                    id: serviceDelegate
                                                    required property var modelData
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: 59
                                                    RowLayout {
                                                        anchors.fill: parent
                                                        spacing: 12
                                                        Rectangle {
                                                            Layout.preferredWidth: 7
                                                            Layout.preferredHeight: 7
                                                            radius: 4
                                                            color: window.statusColor(window.displayStatus(serviceDelegate.modelData))
                                                        }
                                                        ColumnLayout {
                                                            Layout.fillWidth: true
                                                            spacing: 2
                                                            Label { text: serviceDelegate.modelData.name; color: window.ink; font.family: window.uiFont; font.pixelSize: 13; font.bold: true }
                                                            Label { text: serviceDelegate.modelData.detail; color: window.muted; font.family: window.uiFont; font.pixelSize: 11 }
                                                        }
                                                        StatusChip { value: window.displayStatus(serviceDelegate.modelData) }
                                                    }
                                                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: window.line; opacity: 0.72 }
                                                }
                                            }
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            spacing: 10
                                            Label { text: "Model"; color: window.ink; font.family: window.uiFont; font.pixelSize: 18; font.bold: true }
                                            Label {
                                                text: "Used by Pi and local model commands."
                                                color: window.muted
                                                font.family: window.uiFont
                                                font.pixelSize: 11
                                            }
                                            ComboBox {
                                                id: modelPicker
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: 44
                                                model: window.controllerRef ? window.controllerRef.models : []
                                                textRole: "name"
                                                valueRole: "name"
                                                currentIndex: window.currentModelIndex()
                                                enabled: !!window.controllerRef && !window.controllerRef.busy && count > 0
                                                Accessible.name: "Active Ollama model"
                                                displayText: count > 0 ? currentText : (window.serviceValue("Ollama") === "RUNNING" ? "No installed models" : "Starting Ollama...")
                                                onActivated: {
                                                    if (window.controllerRef && currentValue && currentValue !== window.detailValue("model", ""))
                                                        window.controllerRef.selectModel(String(currentValue))
                                                }
                                                contentItem: Label {
                                                    leftPadding: 13
                                                    rightPadding: 34
                                                    text: modelPicker.displayText
                                                    color: modelPicker.enabled ? window.ink : window.muted
                                                    font.family: window.monoFont
                                                    font.pixelSize: 12
                                                    verticalAlignment: Text.AlignVCenter
                                                    elide: Text.ElideMiddle
                                                }
                                                background: Rectangle {
                                                    radius: 8
                                                    color: modelPicker.hovered ? window.raised : window.bg
                                                    border.width: 1
                                                    border.color: modelPicker.activeFocus ? window.accent : window.line
                                                }
                                            }
                                            Label {
                                                text: window.modelSummary(modelPicker.currentIndex)
                                                color: window.muted
                                                font.family: window.monoFont
                                                font.pixelSize: 10
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 16
                                                Label { text: "Context  " + window.detailValue("context", "Unknown"); color: window.muted; font.family: window.monoFont; font.pixelSize: 10 }
                                                Label { text: "Reasoning  " + window.detailValue("reasoning", "Unknown"); color: window.muted; font.family: window.monoFont; font.pixelSize: 10 }
                                                Item { Layout.fillWidth: true }
                                                Label { text: modelPicker.count + " installed"; color: window.quiet; font.family: window.monoFont; font.pixelSize: 10 }
                                            }
                                            Item { Layout.fillHeight: true }
                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 8
                                                ActionButton { text: "Open WebUI"; command: "webui"; primary: true; Layout.fillWidth: true }
                                                ActionButton { text: "Pi agent"; command: "pi"; Layout.fillWidth: true }
                                                ActionButton { text: "Stop all"; command: "stop"; destructive: true; Layout.fillWidth: true }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Item {
                        id: operationsPage
                        objectName: "OperationsPage"
                        ScrollView {
                            anchors.fill: parent
                            clip: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            GridLayout {
                                width: operationsPage.width
                                columns: window.width < 1120 ? 1 : 2
                                columnSpacing: 14
                                rowSpacing: 14

                                CommandGroup {
                                    Layout.fillWidth: true
                                    heading: "Runtime"
                                    description: "Start or stop the managed local services."
                                    ActionButton { text: "Launch stack"; command: "both"; primary: true; Layout.fillWidth: true }
                                    ActionButton { text: "Restart"; command: "restart"; Layout.fillWidth: true }
                                    ActionButton { text: "Ollama only"; command: "ollama"; Layout.fillWidth: true }
                                    ActionButton { text: "Open WebUI"; command: "webui"; Layout.fillWidth: true }
                                    ActionButton { text: "Pi agent"; command: "pi"; Layout.fillWidth: true }
                                    ActionButton { text: "Stop all"; command: "stop"; destructive: true; Layout.fillWidth: true }
                                }

                                CommandGroup {
                                    Layout.fillWidth: true
                                    heading: "Inspect"
                                    description: "Read status, health, service logs, and diagnostics."
                                    ActionButton { text: "Refresh status"; command: "refresh"; primary: true; Layout.fillWidth: true }
                                    ActionButton { text: "Health check"; command: "health"; Layout.fillWidth: true }
                                    ActionButton { text: "Live logs"; command: "logs"; Layout.fillWidth: true }
                                    ActionButton { text: "WebUI probe"; command: "probe"; Layout.fillWidth: true }
                                    ActionButton { text: "Diagnostics"; command: "diagnostics"; Layout.fillWidth: true }
                                    ActionButton { text: "Release details"; command: "about"; Layout.fillWidth: true }
                                }

                                CommandGroup {
                                    Layout.fillWidth: true
                                    heading: "Measure"
                                    description: "Inspect usage and run local model benchmarks."
                                    ActionButton { text: "Token usage"; command: "tokens"; Layout.fillWidth: true }
                                    ActionButton { text: "Live tokens"; command: "livetokens"; Layout.fillWidth: true }
                                    ActionButton { text: "Dashboard"; command: "dashboard"; Layout.fillWidth: true }
                                    ActionButton { text: "Benchmark"; command: "benchmark"; Layout.fillWidth: true }
                                    ActionButton { text: "Benchmark history"; command: "benchmarkhistory"; Layout.fillWidth: true }
                                }

                                CommandGroup {
                                    Layout.fillWidth: true
                                    heading: "Recovery"
                                    description: "Local repair tools that preserve project and user data."
                                    ActionButton {
                                        text: "Reset WebUI login"
                                        command: ""
                                        primary: true
                                        Layout.fillWidth: true
                                        onClicked: window.controllerRef.resetWebUICredentials()
                                    }
                                    ActionButton {
                                        text: "Open activity"
                                        command: ""
                                        enabled: true
                                        Layout.fillWidth: true
                                        onClicked: activityDrawer.open()
                                    }
                                    Label {
                                        text: "Credential recovery backs up the database and changes one password only."
                                        color: window.muted
                                        font.family: window.uiFont
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                        Layout.columnSpan: 2
                                        Layout.topMargin: 4
                                    }
                                }
                            }
                        }
                    }

                    Item {
                        id: aboutPage
                        objectName: "AboutPage"
                        ScrollView {
                            anchors.fill: parent
                            clip: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            Item {
                                width: aboutPage.width
                                height: aboutColumn.implicitHeight + 8
                                ColumnLayout {
                                    id: aboutColumn
                                    width: Math.min(760, parent.width)
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: 14

                                    Surface {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 192
                                        color: window.raised
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: 24
                                            spacing: 20
                                            Rectangle {
                                                Layout.preferredWidth: 64
                                                Layout.preferredHeight: 64
                                                radius: 12
                                                color: window.accent
                                                Label { anchors.centerIn: parent; text: "J"; color: "#06100c"; font.family: window.uiFont; font.pixelSize: 34; font.bold: true }
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 5
                                                Label { text: "JYNERATION"; color: window.ink; font.family: window.uiFont; font.pixelSize: 24; font.bold: true; font.letterSpacing: 1.2 }
                                                Label { text: "Ollama Control HUD"; color: window.accent; font.family: window.uiFont; font.pixelSize: 15 }
                                                Label {
                                                    text: "A local Windows and WSL controller for Ollama, Open WebUI, and Pi."
                                                    color: window.muted
                                                    font.family: window.uiFont
                                                    font.pixelSize: 12
                                                    wrapMode: Text.WordWrap
                                                    Layout.fillWidth: true
                                                }
                                            }
                                        }
                                    }

                                    Surface {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 226
                                        ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: 20
                                            spacing: 12
                                            Label { text: "Build and provenance"; color: window.ink; font.family: window.uiFont; font.pixelSize: 17; font.bold: true }
                                            GridLayout {
                                                Layout.fillWidth: true
                                                columns: 2
                                                rowSpacing: 10
                                                Label { text: "Release"; color: window.muted; font.family: window.uiFont; font.pixelSize: 12 }
                                                Label { text: "BETA"; color: window.ink; font.family: window.monoFont; font.pixelSize: 12; Layout.alignment: Qt.AlignRight }
                                                Label { text: "Author"; color: window.muted; font.family: window.uiFont; font.pixelSize: 12 }
                                                Label { text: "saj"; color: window.ink; font.family: window.monoFont; font.pixelSize: 12; Layout.alignment: Qt.AlignRight }
                                                Label { text: "License"; color: window.muted; font.family: window.uiFont; font.pixelSize: 12 }
                                                Label { text: "MIT"; color: window.ink; font.family: window.monoFont; font.pixelSize: 12; Layout.alignment: Qt.AlignRight }
                                                Label { text: "Integrity"; color: window.muted; font.family: window.uiFont; font.pixelSize: 12 }
                                                Label { text: "SHA256SUMS.txt"; color: window.ink; font.family: window.monoFont; font.pixelSize: 12; Layout.alignment: Qt.AlignRight }
                                            }
                                            Item { Layout.fillHeight: true }
                                            RowLayout {
                                                Layout.fillWidth: true
                                                ActionButton { text: "Release details"; command: "about"; Layout.fillWidth: true }
                                                ActionButton {
                                                    text: "Reset WebUI login"
                                                    command: ""
                                                    primary: true
                                                    Layout.fillWidth: true
                                                    onClicked: window.controllerRef.resetWebUICredentials()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Drawer {
        id: activityDrawer
        objectName: "activityDrawer"
        edge: Qt.RightEdge
        width: Math.min(560, window.width * 0.55)
        height: window.height
        modal: false
        interactive: true
        closePolicy: Popup.CloseOnEscape
        background: Rectangle {
            color: "#06100c"
            border.width: 1
            border.color: window.line
        }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 12
            RowLayout {
                Layout.fillWidth: true
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: "Activity"; color: window.ink; font.family: window.uiFont; font.pixelSize: 21; font.bold: true }
                    Label { text: window.controllerRef ? window.controllerRef.operationPhase : "Runtime output"; color: window.muted; font.family: window.uiFont; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                }
                ToolButton {
                    id: closeActivityButton
                    text: "Close"
                    Accessible.name: "Close activity"
                    onClicked: activityDrawer.close()
                    contentItem: Label { text: closeActivityButton.text; color: window.ink; font.family: window.uiFont; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { radius: 8; color: closeActivityButton.hovered ? window.raised : "transparent"; border.width: 1; border.color: closeActivityButton.activeFocus ? window.accent : window.line }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: window.line }
            TextArea {
                id: activityOutput
                Layout.fillWidth: true
                Layout.fillHeight: true
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.NoWrap
                text: window.controllerRef ? window.controllerRef.output : "Controller is unavailable."
                color: window.ink
                selectionColor: window.accentSoft
                selectedTextColor: window.ink
                font.family: window.monoFont
                font.pixelSize: 11
                leftPadding: 14
                rightPadding: 14
                topPadding: 14
                bottomPadding: 14
                background: Rectangle { color: window.bg; radius: 8; border.width: 1; border.color: activityOutput.activeFocus ? window.accent : window.line }
                onTextChanged: if (followTail.checked || (window.controllerRef && window.controllerRef.busy)) cursorPosition = length
            }
            RowLayout {
                Layout.fillWidth: true
                CheckBox {
                    id: followTail
                    text: "Follow output"
                    checked: true
                    Accessible.name: text
                    contentItem: Label { text: followTail.text; color: window.muted; font.family: window.uiFont; font.pixelSize: 11; leftPadding: followTail.indicator.width + followTail.spacing }
                }
                Item { Layout.fillWidth: true }
                ActionButton {
                    text: "Clear"
                    command: ""
                    enabled: !!window.controllerRef
                    onClicked: window.controllerRef.clearOutput()
                }
                ActionButton {
                    visible: window.controllerRef ? window.controllerRef.busy : false
                    text: "Cancel"
                    command: ""
                    destructive: true
                    enabled: visible
                    onClicked: window.controllerRef.cancel()
                }
            }
        }
    }

    Connections {
        target: window.controllerRef ? window.controllerRef : null
        ignoreUnknownSignals: true
        function onConsoleRequested() { activityDrawer.open() }
    }
}
