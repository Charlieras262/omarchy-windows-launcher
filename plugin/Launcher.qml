import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Windows launcher overlay. Two views over one window:
//
//   dialog    options before the VM starts (spec US1). Writes the choice as
//             JSON to payload.answersFile; the orchestrator waits on that file.
//   progress  launch / shutdown progress (spec US5): a title and a bar, nothing else;
//             a failure also shows its reason and a Close button. Pure renderer of the
//             state file the orchestrator keeps up to date; no logic here.
//
// Summon payload (JSON):
//   { "view": "dialog",   "answersFile": "...", "disks": [{value,label,description}] }
//   { "view": "progress", "stateFile": "..." }
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property double openedAt: 0
  property string view: "dialog"

  // --- dialog state
  property bool closeOnExit: true
  property bool allMonitors: false
  property bool mountDisks: false
  property var diskOptions: []
  property var selectedDisks: []
  property string answersFile: ""

  // --- progress state
  property string stateFile: ""
  property var vm: ({ stage: "idle", mode: "launch", percent: 0, message: "", error: "" })

  property string fontFamily: Style.font.menuFamily
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(380), panel.width - Style.gapsOut * 2)

  readonly property bool terminal: vm.stage === "failed" || vm.stage === "running" || vm.stage === "stopped" || vm.stage === "cancelled"
  readonly property bool failed: vm.stage === "failed"

  // ---------------------------------------------------------------- entry points

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    root.view = payload.view === "progress" ? "progress" : "dialog"

    if (root.view === "dialog") {
      root.closeOnExit = true
      root.allMonitors = false
      root.mountDisks = !!payload.mountDisks   // test hook: start with the switch on
      root.selectedDisks = []
      root.answersFile = payload.answersFile || ""
      root.diskOptions = payload.disks || []
    } else {
      root.stateFile = payload.stateFile || ""
      root.vm = ({ stage: "idle", mode: "launch", percent: 0, message: "", error: "" })
      stateWatcher.reload()
    }

    root.openedAt = Date.now()
    watchdog.restart()
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    dismissTimer.stop()
    watchdog.stop()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "charlieras262.windows-launcher")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---------------------------------------------------------------- dialog

  function answer(action) {
    if (root.answersFile !== "") {
      var disks = (root.mountDisks ? root.selectedDisks : [])
      // The orchestrator blocks on this file, so the write must not depend on a FileView whose
      // path was only just assigned (that race lost the answer and left the session lock held).
      // A short-lived shell does the write; the window closes once it is done.
      answersOut.command = ["sh", "-c", "printf '%s\\n' \"$1\" > \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"",
        "sh",
        JSON.stringify({
          action: action,
          closeOnExit: root.closeOnExit,
          allMonitors: root.allMonitors,
          disks: disks
        }),
        root.answersFile]
      answersOut.running = true
    }
    root.dismiss()
  }

  function toggleDisk(path) {
    var arr = root.selectedDisks.slice()
    var i = arr.indexOf(path)
    if (i === -1) arr.push(path)
    else arr.splice(i, 1)
    root.selectedDisks = arr
  }

  function start() { answer("start") }
  function cancel() { answer("cancel") }

  Process {
    id: answersOut
  }

  // ---------------------------------------------------------------- progress

  function applyState(text) {
    try {
      var parsed = JSON.parse(text)
      root.vm = parsed
    } catch (e) {
      return
    }
    if (root.view === "progress" && (root.vm.stage === "running" || root.vm.stage === "stopped"))
      dismissTimer.restart()
    else
      dismissTimer.stop()
  }

  FileView {
    id: stateWatcher
    path: root.view === "progress" ? root.stateFile : ""
    watchChanges: true
    printErrors: false
    onLoaded: root.applyState(text())
    // text() is stale inside the change signal itself; reload, then onLoaded parses.
    onFileChanged: reload()
  }

  // Launch: vanish once Windows is up. Shutdown: linger briefly so "stopped" is readable.
  Timer {
    id: dismissTimer
    interval: root.vm.stage === "stopped" ? 3000 : 800
    repeat: false
    onTriggered: root.dismiss()
  }

  // The overlay takes over the screen, so it must never outlive the thing it reports on.
  //  progress: the orchestrator rewrites the state file about once a second while it lives
  //            (updatedAt, epoch seconds); no update for 30 s means it died, so close.
  //  dialog:   the orchestrator gives up waiting for an answer after 5 minutes.
  Timer {
    id: watchdog
    interval: 5000
    repeat: true
    onTriggered: {
      if (!root.opened) { stop(); return }
      if (root.view === "dialog") {
        if (Date.now() - root.openedAt > 300000) root.cancel()
        return
      }
      var updated = (root.vm.updatedAt || 0) * 1000
      var last = Math.max(updated, root.openedAt)
      if (Date.now() - last > 30000) root.dismiss()
    }
  }

  readonly property string progressTitle: root.vm.mode === "shutdown" ? "Shutting down Windows" : "Starting Windows"

  // ---------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-windows-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    // The dialog is modal; the progress window only reports, so it neither grabs the keyboard
    // nor swallows clicks outside its card.
    WlrLayershell.keyboardFocus: root.view === "dialog" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region { item: root.view === "dialog" ? null : card }

    Rectangle {
      anchors.fill: parent
      visible: root.view === "dialog"
      color: root.scrim
    }

    // Clicking outside cancels the dialog.
    MouseArea {
      anchors.fill: parent
      enabled: root.view === "dialog"
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(content.implicitHeight + card.contentTopInset + card.contentBottomInset,
                       panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.AfterItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.view === "dialog") root.cancel()
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.view === "dialog") root.start()
            else if (root.terminal) root.dismiss()
            event.accepted = true
          }
        }
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Column {
          id: content
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.spacing.huge

          // ------------------------------------------------ dialog view
          Text {
            visible: root.view === "dialog"
            width: parent.width
            textFormat: Text.PlainText
            text: "Windows"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Toggle {
            visible: root.view === "dialog"
            width: parent.width
            label: "Close VM with the window"
            description: "Stops the Windows container when you close the window."
            checked: root.closeOnExit
            fontFamily: root.fontFamily
            onClicked: root.closeOnExit = !root.closeOnExit
          }

          Toggle {
            visible: root.view === "dialog"
            width: parent.width
            label: "Use all monitors"
            description: "One window across every screen; hides the bar meanwhile."
            checked: root.allMonitors
            fontFamily: root.fontFamily
            onClicked: root.allMonitors = !root.allMonitors
          }

          Toggle {
            visible: root.view === "dialog"
            width: parent.width
            label: "Mount external disks"
            description: "Hand whole disks to Windows for this session."
            checked: root.mountDisks
            fontFamily: root.fontFamily
            onClicked: root.mountDisks = !root.mountDisks
          }

          // Disks: one row per disk, always visible once the switch is on (no popup: a popup drawn
          // inside this surface can cover the buttons and loses its anchor when the layout changes).
          Column {
            visible: root.view === "dialog" && root.mountDisks
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.spacing.labelGap

            Text {
              textFormat: Text.PlainText
              text: "Disks"
              color: root.foreground
              opacity: 0.65
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Flickable {
              id: diskFlick
              width: parent.width
              height: Math.min(diskColumn.implicitHeight, Style.space(228))
              contentWidth: width
              contentHeight: diskColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: diskColumn
                width: diskFlick.width
                spacing: Style.spacing.labelGap

                Repeater {
                  model: root.diskOptions
                  delegate: Toggle {
                    required property var modelData
                    width: diskColumn.width
                    label: modelData.label
                    description: modelData.description
                    checked: root.selectedDisks.indexOf(modelData.value) !== -1
                    fontFamily: root.fontFamily
                    onClicked: root.toggleDisk(modelData.value)
                  }
                }
              }
            }

            Text {
              visible: root.diskOptions.length === 0
              textFormat: Text.PlainText
              text: "No external disks found"
              color: root.foreground
              opacity: 0.65
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Row {
            visible: root.view === "dialog"
            anchors.right: parent.right
            spacing: Style.spacing.huge
            Button {
              text: "Cancel"
              fontFamily: root.fontFamily
              bordered: true
              focusable: true
              onClicked: root.cancel()
            }
            Button {
              text: "Start"
              fontFamily: root.fontFamily
              bordered: true
              focusable: true
              selected: true
              onClicked: root.start()
            }
          }

          // ------------------------------------------------ progress view
          Text {
            visible: root.view === "progress"
            width: parent.width
            textFormat: Text.PlainText
            text: root.failed ? "Windows could not start" : root.progressTitle
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Rectangle {
            visible: root.view === "progress"
            width: parent.width
            height: Style.space(6)
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Rectangle {
              height: parent.height
              radius: parent.radius
              width: parent.width * Math.max(0, Math.min(100, root.vm.percent || 0)) / 100
              color: root.failed ? "#c0392b" : Color.accent
              Behavior on width { NumberAnimation { duration: 200 } }
            }
          }

          Text {
            visible: root.view === "progress" && root.failed && (root.vm.error || "") !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.vm.error || ""
            color: "#e57373"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // Always closable: hiding the window never stops the launch itself.
          Button {
            visible: root.view === "progress"
            anchors.right: parent.right
            text: root.terminal ? "Close" : "Hide"
            fontFamily: root.fontFamily
            bordered: true
            focusable: true
            onClicked: root.dismiss()
          }
        }
      }
    }
  }
}
