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
  property alias diskSelect: diskSelect

  property bool opened: false
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

  // Declared after the theme-backed properties above on purpose: touching Style first changes the
  // singleton construction order and leaves Color.menu undefined.
  // Height the open disk list needs below its trigger: search field + up to 6 rows.
  readonly property real diskListHeight: Style.space(56) + Math.min(Math.max(diskOptions.length, 1), 6) * Style.spacing.popupRowHeight

  readonly property bool terminal: vm.stage === "failed" || vm.stage === "running" || vm.stage === "stopped" || vm.stage === "cancelled"
  readonly property bool failed: vm.stage === "failed"

  // The disk list is anchored to its trigger; if the trigger goes away (switch turned off, dialog
  // reopened) while the list is open, it loses its anchor, jumps to the top of the window and keeps
  // the card stretched. Close it whenever the switch goes off.
  onMountDisksChanged: { if (!mountDisks) diskSelect.close() }

  // ---------------------------------------------------------------- entry points

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    diskSelect.close()
    root.view = payload.view === "progress" ? "progress" : "dialog"

    if (root.view === "dialog") {
      root.closeOnExit = true
      root.allMonitors = false
      root.mountDisks = !!payload.mountDisks   // test hook: start with the switch on
      root.selectedDisks = []
      root.answersFile = payload.answersFile || ""
      root.diskOptions = payload.disks || []
      // Test hook: open with the disk list expanded (used to check the popup's look).
      if (payload.openDisks) {
        root.mountDisks = true
        openDisksTimer.restart()
      }
    } else {
      root.stateFile = payload.stateFile || ""
      stateWatcher.reload()
    }

    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    dismissTimer.stop()
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
      answersOut.path = root.answersFile
      answersOut.setText(JSON.stringify({
        action: action,
        closeOnExit: root.closeOnExit,
        allMonitors: root.allMonitors,
        disks: disks
      }) + "\n")
    }
    root.dismiss()
  }

  function start() { answer("start") }
  function cancel() { answer("cancel") }

  Timer {
    id: openDisksTimer
    interval: 400
    repeat: false
    onTriggered: diskSelect.open()
  }

  FileView {
    id: answersOut
    printErrors: false
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

  readonly property string progressTitle: root.vm.mode === "shutdown" ? "Shutting down Windows" : "Starting Windows"

  // ---------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-windows-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    // Clicking outside cancels the dialog; the progress window is not dismissed by accident.
    MouseArea {
      anchors.fill: parent
      onClicked: { if (root.view === "dialog") root.cancel(); else if (root.terminal) root.dismiss() }
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
            else if (root.terminal) root.dismiss()
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

          MultiSelect {
            id: diskSelect
            visible: root.view === "dialog" && root.mountDisks
            width: parent.width
            height: visible ? implicitHeight : 0
            label: "Disks"
            // Default popup fill from the theme (translucent, above the blur layer rule's
            // ignore_alpha). The card grows while the list is open so the popup stays over the
            // card, where the compositor blurs, and Cancel/Start are hidden meanwhile.
            options: root.diskOptions
            values: root.selectedDisks
            emptyText: "No external disks found"
            noSelectionText: "None selected"
            fontFamily: root.fontFamily
            onChanged: function(values) { root.selectedDisks = values }
          }

          Row {
            id: buttonsRow
            visible: root.view === "dialog"
            anchors.right: parent.right
            spacing: Style.spacing.huge
            // The disk list opens over these buttons; hide them meanwhile so they
            // cannot show through the blurred popup.
            opacity: diskSelect.popupOpen ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 120 } }

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

          // The disk list is drawn in this same surface and the compositor only blurs where the
          // card is, so the whole popup must stay over the card. The space is reserved as soon as
          // the switch is on (not when the list opens): the card is centered, so growing it at that
          // moment moved the trigger after the popup had measured its position and left the first
          // list floating too low. The list covers the (hidden) buttons row too, so only the rest
          // of its height is added.
          Item {
            visible: root.view === "dialog"
            width: parent.width
            height: root.mountDisks ? Math.max(0, root.diskListHeight - buttonsRow.height - Style.spacing.huge) : 0
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

          // Only a failure keeps the window open, so only then is there anything to close.
          Button {
            visible: root.view === "progress" && root.failed
            anchors.right: parent.right
            text: "Close"
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
