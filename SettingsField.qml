pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// A settings text field whose paste cannot stall the desktop shell. Qt's own
// paste reads the clipboard synchronously inside the shell, with no limit on
// how long the clipboard's owner takes or how much it sends. Here Ctrl+V and
// Shift+Insert, middle click and the context menu's Paste read the clipboard
// through a separate wl-paste process instead: at most `pasteCharLimit`
// characters within `pasteTimeoutMs`, or nothing is pasted. The text is
// inserted only while this field is still the focused field, and only for the
// latest request: typing, moving to another field or pasting again retires
// an earlier one, and a retired request's output is never used. Focus here
// means `focus`, not `activeFocus`, so a briefly inactive window keeps it.
Ui.TextField {
  id: root
  selectByMouse: true
  background: Ui.BorderSurface {
    color: Style.controlFill(root.activeFocus, root.hovered, root.foreground, root.accent)
    borderSpec: Border.controlSpec(root.activeFocus ? "focus" : root.hovered ? "hover-cursor" : "normal", root.foreground, root.accent)
    radius: Style.space(6)
  }

  property int pasteCharLimit: 16384
  property int pasteTimeoutMs: 2000
  property int pasteGeneration: 0
  property var pasteRequest: null
  readonly property bool pasting: pasteRequest !== null
  property alias pasteMenuItem: pasteMenuItem

  function retirePaste() {
    pasteDeadline.stop()
    if (pasteRequest) pasteRequest.retire()
    pasteRequest = null
  }
  // `primary`: the middle-click selection instead of the clipboard.
  function pasteFromClipboard(primary) {
    retirePaste()
    pasteGeneration++
    if (readOnly || !focus) return
    var request = pasteComponent.createObject(root, { generation: pasteGeneration, primary: primary === true })
    if (!request) return
    pasteRequest = request
    pasteDeadline.restart()
    request.running = true
  }
  // Ends `request`; `text` is null when it failed, timed out or was too large.
  function endPaste(request, text) {
    if (request !== pasteRequest) return
    pasteDeadline.stop()
    pasteRequest = null
    if (text === null || request.generation !== pasteGeneration || readOnly || !focus) return
    // One line: drop the line breaks a copied key or URL often ends with.
    var clean = String(text).replace(/[\r\n]+/g, "")
    if (clean === "") return
    if (selectedText !== "") remove(selectionStart, selectionEnd)
    // insert() honours maximumLength and emits textEdited, like a paste.
    insert(cursorPosition, clean)
  }

  // Connections, so that instances can keep their own handlers for these.
  Connections {
    target: root
    function onFocusChanged() { if (!root.focus) { root.retirePaste(); root.pasteGeneration++ } }
    function onTextEdited() { if (root.pasteRequest) { root.retirePaste(); root.pasteGeneration++ } }
    function onReadOnlyChanged() { if (root.readOnly) { root.retirePaste(); root.pasteGeneration++ } }
  }
  Component.onDestruction: retirePaste()

  Keys.onPressed: function(event) {
    if (!event.matches(StandardKey.Paste)) return
    event.accepted = true
    root.pasteFromClipboard(false)
  }

  // Middle click pastes the primary selection, as the native field would.
  MouseArea {
    objectName: "settingsFieldMiddlePaste"
    anchors.fill: parent
    acceptedButtons: Qt.MiddleButton
    onClicked: function(mouse) {
      if (root.readOnly) return
      root.forceActiveFocus()
      root.cursorPosition = root.positionAt(mouse.x, mouse.y)
      root.pasteFromClipboard(true)
    }
  }

  // Replaces Qt's default menu, whose Paste uses the synchronous native paste.
  // Its Paste runs once the menu has closed and returned focus to the field.
  ContextMenu.menu: Menu {
    id: editMenu
    property bool pasteChosen: false
    onClosed: if (pasteChosen) {
      pasteChosen = false
      root.forceActiveFocus()
      root.pasteFromClipboard(false)
    }
    MenuItem {
      text: "Cut"
      enabled: !root.readOnly && !root.password && root.selectedText !== ""
      onTriggered: root.cut()
    }
    MenuItem {
      text: "Copy"
      enabled: !root.password && root.selectedText !== ""
      onTriggered: root.copy()
    }
    MenuItem {
      id: pasteMenuItem
      text: "Paste"
      enabled: !root.readOnly
      onTriggered: {
        if (editMenu.visible) editMenu.pasteChosen = true
        else root.pasteFromClipboard(false)
      }
    }
    MenuSeparator {}
    MenuItem {
      text: "Select All"
      enabled: root.length > 0
      onTriggered: root.selectAll()
    }
  }

  Timer {
    id: pasteDeadline
    interval: root.pasteTimeoutMs
    onTriggered: root.retirePaste()
  }

  Component {
    id: pasteComponent

    Process {
      id: pasteProcess
      property int generation: -1
      property bool primary: false
      property bool retired: false
      property bool tooLarge: false
      property bool exitSeen: false
      property int exitCode: -1
      property string body: ""
      command: primary ? ["wl-paste", "--primary", "--no-newline", "--type", "text"]
        : ["wl-paste", "--no-newline", "--type", "text"]

      function retire() {
        retired = true
        body = ""
        if (running) running = false
        else destroy()
      }

      stdout: SplitParser {
        splitMarker: ""
        onRead: function(data) {
          if (pasteProcess.retired || pasteProcess.tooLarge) return
          var chunk = String(data)
          if (pasteProcess.body.length + chunk.length > root.pasteCharLimit) {
            pasteProcess.tooLarge = true
            pasteProcess.body = ""
            pasteProcess.running = false
            return
          }
          pasteProcess.body += chunk
        }
      }
      stderr: SplitParser { splitMarker: "" }
      onExited: function(code) {
        exitSeen = true
        exitCode = code
      }
      onRunningChanged: {
        if (running) return
        var complete = !retired && !tooLarge && exitSeen && exitCode === 0
        retired = true
        root.endPaste(pasteProcess, complete ? body : null)
        body = ""
        destroy()
      }
    }
  }
}
