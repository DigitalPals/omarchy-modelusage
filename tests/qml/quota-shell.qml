import QtQuick
import Quickshell

ShellRoot {
  id: root
  property var backend: null
  property int responses: 0
  property int phase: 0
  function check(condition, message) {
    if (!condition) { console.error("QUOTA TEST FAILED: " + message); Qt.exit(1) }
  }
  Component.onCompleted: {
    var component = Qt.createComponent(Quickshell.env("MODEL_USAGE_REPO_URL") + "/UsageBackend.qml")
    check(component.status === Component.Ready, component.errorString())
    backend = component.createObject(root, {settings: {
      usageSource: "cliproxy", cliproxyUrl: "https://old.example", enabledProviders: ["codex"]}})
    check(backend !== null, component.errorString())
    backend.refreshed.connect(function() {
      root.responses++
      root.check(backend.payload.testRequest.cliproxy_url === "https://new.example",
        "a response must belong to the connection that launched it")
    })
    backend.refresh()
    check(backend.loading, "refresh reports loading during process startup")
    backend.settings = {usageSource: "cliproxy", cliproxyUrl: "https://new.example",
      cliproxyKeyFile: "/synthetic/new-key", enabledProviders: ["codex"]}
    backend.refresh()
    backend.refresh()
  }
  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      if (root.phase === 0 && root.responses && !root.backend.loading) {
        root.check(root.responses === 1, "discard old response and coalesce queued refreshes")
        root.check(root.backend.payload.testRequest.cliproxy_key_file === "/synthetic/new-key",
          "latest credential reaches the follow-up process")
        root.phase++
        root.backend.refresh()
        root.backend.refresh()
        root.backend.refresh()
      } else if (root.phase === 1 && root.responses >= 3 && !root.backend.loading) {
        root.check(root.responses === 3, "manual refreshes during startup produce one follow-up")
        console.log("Quota QML contract: passed")
        Qt.quit()
      }
    }
  }
  Timer { interval: 5000; running: true; onTriggered: root.check(false, "timed out") }
}
