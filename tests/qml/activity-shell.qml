import QtQuick
import Quickshell

ShellRoot {
  id: root
  property var backend: null
  property int phase: 0
  property int ticks: 0
  QtObject {
    id: usage
    property string usageSource: "cliproxy"
    property string cliproxyUrl: "http://synthetic.invalid"
    property string cliproxyKeyFile: ""
    readonly property string connectionId: JSON.stringify([usageSource, cliproxyUrl])
    function localPath(url) { return String(url).replace("file://", "") }
  }
  Item { id: host }
  function check(condition, message) {
    if (!condition) { console.error("ACTIVITY TEST FAILED: " + message); Qt.exit(1) }
  }
  Component.onCompleted: {
    var component = Qt.createComponent(Quickshell.env("MODEL_USAGE_REPO_URL") + "/UsageActivityBackend.qml")
    check(component.status === Component.Ready, component.errorString())
    backend = component.createObject(host, { usageBackend: usage,
      settings: { costKeeperUrl: "http://synthetic.invalid/old" },
      scriptPath: Quickshell.env("MODEL_USAGE_FAKE_ACTIVITY") })
    check(backend !== null, "create activity backend")
  }
  Timer {
    interval: 40
    running: true
    repeat: true
    onTriggered: {
      root.ticks++
      root.check(root.ticks < 150, "state machine timed out at " + root.phase)
      var b = root.backend
      if (root.phase === 0 && root.ticks >= 2) {
        b.settings = { costKeeperUrl: "http://synthetic.invalid/new",
          costKeeperPasswordFile: Quickshell.env("MODEL_USAGE_ACTIVITY_MARKER") }
        root.check(b.providers.length === 0, "changing Keeper clears activity immediately")
        root.phase++
      } else if (root.phase === 1 && b.providers.length > 0) {
        root.check(b.providers[0].accountId === "new", "old process cannot overwrite changed connection")
        root.check(b.lastSuccessAt > 0, "success records freshness")
        b.refresh()
        root.phase++
      } else if (root.phase === 2 && b.fetchError !== "") {
        root.check(b.providers[0].accountId === "new", "outage preserves last-known activity")
        root.check(b.notice === "Synthetic outage", "outage is explained")
        usage.usageSource = "direct"
        root.check(!b.trackingEnabled && b.providers.length === 0, "direct mode disables and clears tracking")
        usage.usageSource = "cliproxy"
        b.settings = { costKeeperUrl: "http://synthetic.invalid/oversized" }
        root.phase++
      } else if (root.phase === 3 && b.fetchError !== "") {
        root.check(b.providers.length === 0, "oversized output cannot supply account activity")
        b.settings = {}
        root.check(!b.trackingEnabled && b.notice.indexOf("Configure") >= 0, "missing Keeper gives setup guidance")
        console.log("Activity QML contract: passed")
        Qt.quit()
      }
    }
  }
}
