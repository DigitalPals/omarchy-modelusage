import QtQuick
import "UsageLogic.js" as UsageLogic

// A bar's handle on the one account-activity worker (UsageActivityBackend.qml)
// per quota worker and Keeper/live settings; see UsageSharedBackend.qml.
Item {
  id: root
  visible: false
  required property var usageBackend
  property var settings: ({})
  property string scriptPath: usageBackend.localPath(Qt.resolvedUrl("scripts/proxy-activity.py"))
  property string liveScriptPath: usageBackend.localPath(Qt.resolvedUrl("scripts/proxy-live.py"))
  property var connection: null
  property string acquiredKey: ""
  property bool acquiredActive: false
  property bool ready: false
  readonly property string key: usageBackend.connection ? JSON.stringify([
    usageBackend.key, String(UsageLogic.setting(settings, "keeperUrl", "")),
    String(UsageLogic.setting(settings, "keeperPasswordFile", "")),
    settings.liveAccountActivity !== false, scriptPath, liveScriptPath
  ]) : ""
  readonly property var providers: connection ? connection.providers : []
  readonly property string fetchError: connection ? connection.fetchError : ""
  readonly property double lastSuccessAt: connection ? connection.lastSuccessAt : 0
  readonly property bool rustProxy: connection ? connection.rustProxy : false
  readonly property bool trackingEnabled: connection ? connection.trackingEnabled : false
  readonly property bool useLive: connection ? connection.useLive : false
  readonly property string liveState: connection ? connection.liveState : "off"
  readonly property string liveNotice: connection ? connection.liveNotice : ""
  readonly property var liveAccounts: connection ? connection.liveAccounts : []
  readonly property string notice: connection ? connection.notice : ""

  function refresh() { if (connection) connection.refresh() }
  function sync() {
    if (!ready || key === acquiredKey) return
    connection = null
    if (acquiredKey !== "") UsageLogic.releaseBackend("UsageActivityBackend", acquiredKey, acquiredActive)
    acquiredKey = key
    acquiredActive = usageBackend.automaticRefreshEnabled
    if (key !== "") connection = UsageLogic.acquireBackend("UsageActivityBackend", key, {
      usageBackend: usageBackend.connection, settings: settings,
      automaticRefreshEnabled: acquiredActive, scriptPath: scriptPath, liveScriptPath: liveScriptPath
    })
  }
  onKeyChanged: if (ready) sync()
  Component.onCompleted: { ready = true; sync() }
  Component.onDestruction: {
    ready = false
    connection = null
    if (acquiredKey !== "") UsageLogic.releaseBackend("UsageActivityBackend", acquiredKey, acquiredActive)
  }
  Connections {
    target: root.usageBackend
    function onAutomaticRefreshEnabledChanged() {
      if (!root.connection) return
      UsageLogic.updateBackendActivity("UsageActivityBackend", root.acquiredKey, root.acquiredActive,
        root.usageBackend.automaticRefreshEnabled)
      root.acquiredActive = root.usageBackend.automaticRefreshEnabled
    }
  }
}
