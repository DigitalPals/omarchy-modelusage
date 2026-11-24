import QtQuick
import "UsageLogic.js" as UsageLogic

// A bar's handle on the one quota worker (UsageBackend.qml) per connection.
// Every bar showing the widget, on every output, shares that worker, so one
// fetch serves them all and unplugging a monitor cannot stop another bar's
// readings. The worker polls while any bar wants automatic refreshes.
Item {
  id: root
  visible: false
  property var settings: ({})
  property bool automaticRefreshEnabled: true
  property string scriptPath: localPath(Qt.resolvedUrl("scripts/usage-fetch.py"))
  property var connection: null
  property string acquiredKey: ""
  property bool acquiredActive: false
  property bool ready: false

  readonly property string usageSource: UsageLogic.usageSource(settings)
  readonly property var proxyConnection: UsageLogic.proxyConnection(settings)
  readonly property string proxyUrl: proxyConnection.url
  readonly property string proxyKeyFile: proxyConnection.keyFile
  readonly property string connectionId: JSON.stringify([usageSource, proxyUrl, proxyKeyFile])
  readonly property var enabledProviderIds: ["claude", "codex", "kimi"].filter(function(id) {
    var requested = UsageLogic.setting(root.settings, "enabledProviders", null)
    return !UsageLogic.isListLike(requested) || UsageLogic.contains(requested, id)
  })
  readonly property int refreshIntervalSec: Math.max(60, Math.min(3600,
    Math.round(Number(UsageLogic.setting(settings, "refreshIntervalSec", 900)) || 900)))
  // Everything the worker reads from settings; any change means another worker.
  readonly property string key: JSON.stringify([connectionId, enabledProviderIds, refreshIntervalSec, scriptPath])

  readonly property var payload: connection ? connection.payload : ({ schemaVersion: 1, generatedAt: "", providers: [] })
  readonly property var providers: connection ? connection.providers : []
  readonly property string proxyImplementation: connection ? connection.proxyImplementation : ""
  readonly property bool loading: connection ? connection.loading : false
  readonly property string fetchError: connection ? connection.fetchError : ""
  readonly property double lastSuccessAt: connection ? connection.lastSuccessAt : 0
  readonly property double nextRefreshAt: connection ? connection.nextRefreshAt : 0
  signal refreshed(bool manual)

  function setting(name, fallback) { return UsageLogic.setting(settings, name, fallback) }
  function proxyArgs() { return UsageLogic.proxyArgs(proxyUrl, proxyKeyFile, proxyImplementation) }
  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (e) { return value }
  }
  function refresh() { if (connection) connection.refresh() }

  function sync() {
    if (!ready || key === acquiredKey) return
    connection = null
    if (acquiredKey !== "") UsageLogic.releaseBackend("UsageBackend", acquiredKey, acquiredActive)
    acquiredKey = key
    acquiredActive = automaticRefreshEnabled
    connection = UsageLogic.acquireBackend("UsageBackend", key, {
      settings: settings, automaticRefreshEnabled: acquiredActive, scriptPath: scriptPath
    })
  }
  onKeyChanged: if (ready) sync()
  onAutomaticRefreshEnabledChanged: if (connection) {
    UsageLogic.updateBackendActivity("UsageBackend", acquiredKey, acquiredActive, automaticRefreshEnabled)
    acquiredActive = automaticRefreshEnabled
  }
  Component.onCompleted: { ready = true; sync() }
  Component.onDestruction: {
    ready = false
    connection = null
    if (acquiredKey !== "") UsageLogic.releaseBackend("UsageBackend", acquiredKey, acquiredActive)
  }
  Connections {
    target: root.connection
    function onRefreshed(manual) { root.refreshed(manual) }
  }
}
