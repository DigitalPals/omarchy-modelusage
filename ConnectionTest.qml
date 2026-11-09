pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// Tests a Fusebox / CLIProxyAPI connection from unsaved settings. A draft key
// is written to the test process's stdin, never to its arguments.
Column {
  id: root
  property string url: ""
  property string keyFile: ""
  property string key: ""
  property bool requireFusebox: false
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("scripts/proxy-test.py")).replace(/^file:\/\//, ""))
  // idle, testing, ok or failed; any edit to the tested values returns to idle.
  property string status: "idle"
  property string message: ""
  property string implementation: ""
  property var request: null
  readonly property bool testing: status === "testing"
  signal revealRequested(var item)
  spacing: Style.spacing.sm

  function reset() {
    if (process.running) process.running = false
    request = null
    status = "idle"
    message = ""
    implementation = ""
  }
  function test() {
    if (testing || url.trim() === "") return
    reset()
    request = { url: url.trim(), key: key, keyFile: keyFile, requireFusebox: requireFusebox }
    status = "testing"
    process.body = ""
    process.running = true
  }
  function settle(data) {
    var result = null
    try { result = JSON.parse(data) } catch (e) { result = null }
    if (!result || result.schemaVersion !== 1 || typeof result.message !== "string") {
      status = "failed"
      message = "Could not test the connection."
      return
    }
    implementation = result.implementation === "go" || result.implementation === "rust" ? result.implementation : ""
    status = result.ok === true ? "ok" : "failed"
    message = result.message.slice(0, 300)
  }
  onUrlChanged: reset()
  onKeyFileChanged: reset()
  onKeyChanged: reset()
  onRequireFuseboxChanged: reset()
  Component.onDestruction: if (process.running) process.running = false

  Process {
    id: process
    property string body: ""
    command: ["python3", "-u", root.scriptPath]
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify(root.request) + "\n")
      root.request = null
    }
    stdout: SplitParser {
      onRead: function(data) {
        if (root.status !== "testing") return
        root.settle(data)
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onRunningChanged: if (!running) {
      root.request = null
      if (root.status === "testing") {
        root.status = "failed"
        root.message = "Could not run the connection test. Check that python3 is available."
      }
    }
  }

  Timer {
    interval: 15000
    running: root.testing
    onTriggered: {
      process.running = false
      root.status = "failed"
      root.message = "The connection test timed out."
    }
  }

  Ui.Button {
    id: testButton
    objectName: "connectionTestButton"
    text: root.testing ? "Testing…" : "Test connection"
    enabled: !root.testing && root.url.trim() !== ""
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    focusable: true
    Accessible.name: "Test connection"
    onClicked: root.test()
    onActiveFocusChanged: if (activeFocus) root.revealRequested(testButton)
  }

  Text {
    objectName: "connectionTestResult"
    width: parent.width
    visible: root.message !== ""
    text: (root.status === "ok" ? "✓ " : "") + root.message
    color: root.status === "failed" ? root.urgent : Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
  }
}
