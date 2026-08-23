import QtQuick
import Quickshell.Io
import "UsageLogic.js" as UsageLogic

// Process boundary for all provider/network work. The QML side only consumes
// the versioned normalized contract emitted by scripts/usage-fetch.py.
Item {
  id: root
  visible: false

  property var settings: ({})
  property var payload: ({ schemaVersion: 1, generatedAt: "", providers: [] })
  property bool loading: false
  property string fetchError: ""
  property double lastSuccessAt: 0
  property double lastAttemptAt: 0
  property bool pendingRefresh: false

  readonly property int refreshIntervalSec: Math.max(60, Math.min(3600,
    Math.round(Number(setting("refreshIntervalSec", 900)) || 900)))
  readonly property var enabledProviderIds: normalizedProviderIds(setting(
    "enabledProviders", ["claude", "codex", "kimi"]))
  readonly property var providers: payload ? UsageLogic.listOrEmpty(payload.providers) : []
  readonly property string scriptPath: localPath(Qt.resolvedUrl("scripts/usage-fetch.py"))
  readonly property double nextRefreshAt: lastAttemptAt > 0
    ? lastAttemptAt + refreshIntervalSec * 1000 : 0

  signal refreshed()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function normalizedProviderIds(value) {
    var allowed = ["claude", "codex", "kimi"]
    var requested = UsageLogic.isListLike(value) ? value : allowed
    var result = []
    for (var i = 0; i < allowed.length; i++) {
      if (UsageLogic.contains(requested, allowed[i])) result.push(allowed[i])
    }
    return result
  }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (e) { return value }
  }

  function requestRefresh(manual) {
    if (manual) refreshTimer.restart()
    if (fetchProcess.running) {
      pendingRefresh = true
      return
    }
    startFetch()
  }

  function refresh() { requestRefresh(true) }

  function startFetch() {
    pendingRefresh = false
    lastAttemptAt = Date.now()
    fetchProcess.command = [
      "python3", scriptPath,
      "--providers", enabledProviderIds.join(","),
      "--timeout", "12"
    ]
    fetchProcess.running = true
  }

  function settle() {
    loading = false
    if (fetchProcess.outputTooLarge) {
      fetchError = "Model usage backend returned too much data"
    } else if (fetchProcess.timedOut) {
      fetchError = "Model usage backend timed out"
    } else if (!fetchProcess.exitSeen) {
      fetchError = "Could not start python3 for Model Usage"
    } else if (fetchProcess.lastExit !== 0) {
      fetchError = "Model usage backend exited with status " + fetchProcess.lastExit
    } else {
      var parsed = null
      try { parsed = JSON.parse(fetchProcess.body) } catch (e) { parsed = null }
      if (!parsed || parsed.schemaVersion !== 1 || !UsageLogic.isListLike(parsed.providers)) {
        fetchError = "Model usage backend returned unreadable data"
      } else {
        var backendError = String(parsed.backendError || "")
        if (backendError !== "") {
          fetchError = backendError
        } else {
          payload = parsed
          fetchError = ""
          var generated = new Date(String(parsed.generatedAt || "")).getTime()
          lastSuccessAt = isFinite(generated) ? generated : Date.now()
          refreshed()
        }
      }
    }
    if (pendingRefresh) Qt.callLater(function() { root.startFetch() })
  }

  onEnabledProviderIdsChanged: requestRefresh(false)

  Process {
    id: fetchProcess
    running: false
    property string body: ""
    property bool exitSeen: false
    property int lastExit: 0
    property bool timedOut: false
    property bool outputTooLarge: false
    readonly property int maxBodyChars: 2 * 1024 * 1024

    function appendBody(data) {
      if (outputTooLarge) return
      var chunk = String(data)
      if (body.length + chunk.length > maxBodyChars) {
        body = ""
        outputTooLarge = true
        running = false
        return
      }
      body += chunk
    }

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { fetchProcess.appendBody(data) }
    }
    // Drain diagnostics in arbitrary chunks without retaining them.
    stderr: SplitParser { splitMarker: "" }
    onExited: function(exitCode) {
      fetchProcess.exitSeen = true
      fetchProcess.lastExit = exitCode
    }
    onRunningChanged: {
      if (running) {
        body = ""
        exitSeen = false
        lastExit = 0
        timedOut = false
        outputTooLarge = false
        root.loading = true
        processTimeout.restart()
      } else {
        processTimeout.stop()
        root.settle()
      }
    }
  }

  Timer {
    id: processTimeout
    interval: 35000
    repeat: false
    onTriggered: {
      fetchProcess.timedOut = true
      fetchProcess.running = false
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.requestRefresh(false)
  }
}
