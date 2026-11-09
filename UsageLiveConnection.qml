import QtQuick
import Quickshell.Io
import "UsageLogic.js" as UsageLogic

Item {
  id: root
  visible: false
  required property string scriptPath
  required property string proxyUrl
  required property string keyFile
  property var providers: []
  property var accounts: []
  property string connectionState: "reconnecting"
  property string message: "Connecting to live account activity…"
  property double lastSuccessAt: 0
  property bool stopped: false

  function unknown() {
    accounts = []
    connectionState = "reconnecting"
    message = "Reconnecting to live account activity…"
  }
  function stop() {
    stopped = true
    restart.stop()
    watchdog.stop()
    process.running = false
    // Let SIGTERM finish before disposing Process (its destructor kills it).
    dispose.restart()
  }
  function start() {
    if (stopped || process.running) return
    var command = ["python3", "-u", scriptPath].concat(UsageLogic.proxyArgs(proxyUrl, keyFile, "rust"))
    process.command = command
    process.body = ""
    process.running = true
    watchdog.restart()
  }
  function receive(data) {
    if (stopped) return
    process.body += data
    if (process.body.length > 1048576) { fail(); return }
    var newline
    while ((newline = process.body.indexOf("\n")) >= 0) {
      let line = process.body.slice(0, newline)
      process.body = process.body.slice(newline + 1)
      let parsed
      try { parsed = JSON.parse(line) } catch (e) { fail(); return }
      if (!UsageLogic.validLivePayload(parsed)) { fail(); return }
      watchdog.restart()
      if (parsed.heartbeat === true) continue
      providers = parsed.providers
      accounts = parsed.accounts
      connectionState = parsed.state
      message = parsed.message
      if (connectionState === "live") lastSuccessAt = Date.now()
    }
  }
  function fail() { unknown(); process.running = false; restart.restart() }
  Component.onCompleted: start()
  Component.onDestruction: stop()

  Process {
    id: process
    property string body: ""
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.receive(data) } }
    stderr: SplitParser { splitMarker: "" }
    onExited: if (root.stopped) { dispose.stop(); Qt.callLater(function() { root.destroy() }) }
    onRunningChanged: if (!running && !root.stopped) {
      root.unknown()
      watchdog.stop()
      restart.restart()
    }
  }
  Timer { id: watchdog; interval: 20000; onTriggered: root.fail() }
  Timer { id: restart; interval: 60000; onTriggered: root.start() }
  Timer { id: dispose; interval: 1000; onTriggered: root.destroy() }
}
