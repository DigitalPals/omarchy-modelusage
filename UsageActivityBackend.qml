import QtQuick
import Quickshell.Io
import "UsageLogic.js" as UsageLogic

// Go/Keeper retains polling; Rust shares a persistent cached activity stream.
Item {
  id: root
  visible: false
  required property var usageBackend
  property var settings: ({})
  property bool automaticRefreshEnabled: true
  property bool stopped: false
  property var legacyProviders: []
  readonly property var providers: useLive ? (liveConnection ? liveConnection.providers : []) : legacyProviders
  property string legacyError: ""
  readonly property string fetchError: useLive ? (liveState === "live" ? "" : liveNotice) : legacyError
  property double legacySuccessAt: 0
  readonly property double lastSuccessAt: useLive ? (liveConnection ? liveConnection.lastSuccessAt : 0) : legacySuccessAt
  property bool pendingRefresh: false
  property bool launchPending: false
  property double lastAttemptAt: 0
  property string scriptPath: usageBackend.localPath(Qt.resolvedUrl("scripts/proxy-activity.py"))
  readonly property string keeperUrl: String(UsageLogic.setting(settings, "keeperUrl", ""))
  readonly property string passwordFile: String(UsageLogic.setting(settings, "keeperPasswordFile", ""))
  readonly property bool rustProxy: usageBackend.proxyImplementation === "rust"
  readonly property bool trackingEnabled: usageBackend.usageSource === "proxy" && (rustProxy || keeperUrl.trim() !== "")
  readonly property bool useLive: trackingEnabled && rustProxy && settings.liveAccountActivity !== false
  property string liveScriptPath: usageBackend.localPath(Qt.resolvedUrl("scripts/proxy-live.py"))
  property var liveConnection: null
  property string liveKey: ""
  property bool ready: false
  readonly property string liveState: useLive ? (liveConnection ? liveConnection.connectionState : "unavailable") : "off"
  readonly property var liveAccounts: useLive && liveConnection ? liveConnection.accounts : []
  readonly property string liveNotice: useLive ? (liveConnection ? liveConnection.message : "Live activity unavailable.") : ""
  readonly property string connectionId: JSON.stringify([usageBackend.connectionId, rustProxy ? "rust" : "keeper", keeperUrl, passwordFile, useLive, liveScriptPath])

  function syncLive() {
    if (!ready) return
    var key = useLive ? JSON.stringify([usageBackend.proxyUrl, usageBackend.proxyKeyFile, liveScriptPath]) : ""
    if (key === liveKey) return
    liveConnection = null
    if (liveKey !== "") UsageLogic.releaseLive(liveKey)
    liveKey = key
    if (key !== "") {
      liveConnection = UsageLogic.acquireLive(key, null, { scriptPath: liveScriptPath,
          proxyUrl: usageBackend.proxyUrl, keyFile: usageBackend.proxyKeyFile })
    }
  }
  Component.onCompleted: { ready = true; syncLive() }
  Component.onDestruction: {
    ready = false
    liveConnection = null
    if (liveKey !== "") UsageLogic.releaseLive(liveKey)
  }
  readonly property string notice: !trackingEnabled
    ? "Configure CPA Usage Keeper in settings to track the last-used account."
    : fetchError !== "" ? fetchError : lastSuccessAt <= 0 ? "Loading account activity…" : ""

  function refresh() { request(true) }
  // Every quota refresh refreshes activity; automatic ones at most once a second.
  function request(manual) {
    if (stopped || (!manual && !automaticRefreshEnabled) || !trackingEnabled || useLive) return
    // A manual request waits for the running one; automatic ones are dropped.
    if (process.running || launchPending) { pendingRefresh = pendingRefresh || !!manual; return }
    if (!manual && Date.now() - lastAttemptAt < 1000) return
    launchPending = true
    lastAttemptAt = Date.now()
    pendingRefresh = false
    var command = ["python3", scriptPath, "--timeout", "10"].concat(usageBackend.proxyArgs())
    if (!rustProxy && keeperUrl.trim() !== "") command.push("--keeper-url", keeperUrl)
    if (!rustProxy && passwordFile !== "") command.push("--keeper-password-file", passwordFile)
    process.command = command
    process.connectionId = connectionId
    process.running = true
  }

  function stop() {
    stopped = true
    ready = false
    pendingRefresh = false
    process.running = false
    liveConnection = null
    if (liveKey !== "") UsageLogic.releaseLive(liveKey)
    liveKey = ""
  }
  Connections {
    target: root.usageBackend
    ignoreUnknownSignals: true
    function onRefreshed(manual) { root.request(manual) }
  }

  function settle() {
    launchPending = false
    if (stopped) return
    if (process.connectionId !== connectionId || !trackingEnabled || useLive) {
      pendingRefresh = trackingEnabled && !useLive
    } else {
      let parsed = null
      if (process.exitSeen && process.lastExit === 0 && !process.failed) {
        try { parsed = JSON.parse(process.body) } catch (e) { parsed = null }
      }
      if (!parsed || parsed.schemaVersion !== 1 || !UsageLogic.isListLike(parsed.providers)) {
        legacyError = "Account activity refresh failed."
      } else if (String(parsed.error || "") !== "") {
        legacyError = String(parsed.error)
      } else {
        legacyProviders = parsed.providers
        legacyError = ""
        legacySuccessAt = Date.now()
      }
    }
    if (pendingRefresh) Qt.callLater(function() {
      if (root.pendingRefresh) root.request(true)
    })
  }

  onConnectionIdChanged: {
    syncLive()
    if (useLive && process.running) process.running = false
    legacyProviders = []
    legacyError = ""
    legacySuccessAt = 0
    pendingRefresh = false
    lastAttemptAt = 0
    Qt.callLater(function() { root.request(false) })
  }

  Process {
    id: process
    property string connectionId: ""
    property string body: ""
    property bool exitSeen: false
    property int lastExit: 0
    property bool failed: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) {
        if (process.failed) return
        if (process.body.length + data.length > 65536) {
          process.failed = true
          process.body = ""
          process.running = false
        } else process.body += data
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onExited: function(exitCode) { exitSeen = true; lastExit = exitCode }
    onRunningChanged: {
      if (running) {
        root.launchPending = false
        body = ""
        exitSeen = false
        failed = false
        watchdog.restart()
      } else {
        watchdog.stop()
        root.settle()
      }
    }
  }
  Timer {
    id: watchdog
    interval: 15000
    onTriggered: { process.failed = true; process.running = false }
  }
  Timer {
    interval: 15000
    running: root.automaticRefreshEnabled && !root.stopped && root.trackingEnabled && !root.useLive
    repeat: true
    triggeredOnStart: true
    onTriggered: root.request(false)
  }
}
