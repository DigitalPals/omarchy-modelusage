pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// Tests a Fusebox / CLIProxyAPI connection from unsaved settings. A draft key
// is written to the test process's stdin, never to its arguments.
Column {
  id: root
  property string url: ""
  property string keyFile: ""
  property string key: ""
  property bool requireFusebox: false
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family
  property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("scripts/proxy-test.py")).replace(/^file:\/\//, ""))
  // idle, testing, ok or failed; any edit to the tested values returns to idle.
  property string status: "idle"
  property string message: ""
  property string implementation: ""
  // The draft request for the run being started. It is written to stdin once
  // and cleared; a late stop notice from an earlier run never touches it.
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
    exitGrace.stop()
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
    // The process can report that it stopped before its last stdout line is
    // delivered; give that line a moment before calling the run a failure.
    onRunningChanged: if (!running && root.status === "testing") exitGrace.restart()
  }

  Timer {
    id: exitGrace
    interval: 500
    onTriggered: if (root.status === "testing" && !process.running) {
      root.status = "failed"
      root.message = "Could not run the connection test. Check that python3 is available."
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
    color: root.status === "failed" ? root.urgent : UsageLogic.dimColor(root.foreground)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
  }
}
