pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// Tests a Fusebox / CLIProxyAPI connection from unsaved settings. A draft key
// is written to the test process's stdin, never to its arguments. On Fusebox
// a second line says whether Costs can read its usage history.
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
  // Fusebox usage history, reported beside the account result; empty elsewhere.
  property string usageMessage: ""
  property bool usageOk: false
  // Every test is a generation with its own process and request ID. Editing
  // a tested value or starting another test retires the running process, and
  // a result is accepted only from the current generation's process when it
  // echoes that generation's request ID, so a late answer about an earlier
  // URL or key can never be shown as the result for the current draft.
  property int generation: 0
  property string requestId: ""
  property var run: null
  readonly property bool testing: status === "testing"
  signal revealRequested(var item)
  spacing: Style.spacing.sm

  function retire() {
    if (run) run.retire()
    run = null
    exitGrace.stop()
  }
  function reset() {
    generation++
    requestId = ""
    retire()
    status = "idle"
    message = ""
    implementation = ""
    usageMessage = ""
    usageOk = false
  }
  function fail(text) {
    retire()
    status = "failed"
    message = text
  }
  function test() {
    if (testing || url.trim() === "") return
    reset()
    requestId = generation + "-" + Math.floor(Math.random() * 0x7fffffff).toString(36) + Date.now().toString(36)
    var started = runComponent.createObject(root, {
      generation: generation,
      requestId: requestId,
      request: { url: url.trim(), key: key, keyFile: keyFile, requireFusebox: requireFusebox, requestId: requestId }
    })
    if (!started) {
      status = "failed"
      message = "Could not run the connection test."
      return
    }
    run = started
    status = "testing"
    started.running = true
  }
  // Applies one stdout line from the run of `forGeneration` / `forRequest`.
  function settle(data, forGeneration, forRequest) {
    if (forGeneration !== generation || forRequest !== requestId || status !== "testing") return
    var result = null
    try { result = JSON.parse(data) } catch (e) { result = null }
    if (!result || result.schemaVersion !== 1 || typeof result.message !== "string"
        || result.requestId !== forRequest) {
      fail("Could not test the connection.")
      return
    }
    implementation = result.implementation === "go" || result.implementation === "rust" ? result.implementation : ""
    status = result.ok === true ? "ok" : "failed"
    message = result.message.slice(0, 300)
    var usage = result.usage
    usageOk = !!usage && usage.ok === true
    usageMessage = usage && typeof usage.message === "string" ? usage.message.slice(0, 300) : ""
  }
  onUrlChanged: reset()
  onKeyFileChanged: reset()
  onKeyChanged: reset()
  onRequireFuseboxChanged: reset()
  Component.onDestruction: retire()

  Component {
    id: runComponent

    Process {
      id: runProcess
      property int generation: -1
      property string requestId: ""
      // The draft request, written to stdin once and then cleared.
      property var request: null
      property bool retired: false
      command: ["python3", "-u", root.scriptPath]
      stdinEnabled: true

      // Stops this run for good; its output is ignored from now on.
      function retire() {
        retired = true
        request = null
        if (running) running = false
        else destroy()
      }

      onStarted: {
        write(JSON.stringify(request) + "\n")
        request = null
      }
      stdout: SplitParser {
        onRead: function(data) {
          if (!runProcess.retired) root.settle(data, runProcess.generation, runProcess.requestId)
        }
      }
      stderr: SplitParser { splitMarker: "" }
      onRunningChanged: {
        if (running) return
        if (retired) {
          destroy()
        } else if (root.run === runProcess && root.testing) {
          // The process can report that it stopped before its last stdout
          // line is delivered; give that line a moment before failing.
          exitGrace.restart()
        } else if (root.run !== runProcess) {
          destroy()
        }
      }
    }
  }

  Timer {
    id: exitGrace
    interval: 500
    onTriggered: if (root.testing) root.fail("Could not run the connection test. Check that python3 is available.")
  }

  Timer {
    interval: 15000
    running: root.testing
    onTriggered: root.fail("The connection test timed out.")
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

  Text {
    objectName: "connectionTestUsage"
    width: parent.width
    visible: root.usageMessage !== ""
    text: (root.usageOk ? "✓ " : "⚠ ") + root.usageMessage
    color: root.usageOk ? UsageLogic.dimColor(root.foreground) : root.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
  }
}
