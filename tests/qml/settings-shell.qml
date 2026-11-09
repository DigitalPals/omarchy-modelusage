import QtQuick
import Quickshell

// The Limits tab against a synthetic local Fusebox: renamed settings, the
// real connection test process, settings gated by the detected server, and
// one Save across both tabs.
ShellRoot {
  id: root
  property var view: null
  property var form: null
  property var saved: null
  property var connectionTest: null
  property int phase: 0
  readonly property string serverUrl: Quickshell.env("MODEL_USAGE_FUSEBOX_URL")

  function check(condition, message) {
    if (!condition) { console.error("SETTINGS TEST FAILED: " + message); Qt.exit(1) }
  }
  function find(item, name) {
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var child = find(children[i], name)
      if (child) return child
    }
    return null
  }
  function shown(name) {
    var item = find(form, name)
    check(item !== null, "item exists: " + name)
    for (var node = item; node && node !== view; node = node.parent)
      if (!node.visible) return false
    return true
  }

  Component.onCompleted: {
    check(serverUrl !== "", "synthetic Fusebox URL is set")
    var component = Qt.createComponent(Quickshell.env("MODEL_USAGE_REPO_URL") + "/SettingsView.qml")
    check(component.status === Component.Ready, component.errorString())
    view = component.createObject(root, { width: 420 })
    check(view !== null, component.errorString())
    form = view.limitsForm
    view.saveRequested.connect(function(values) { root.saved = values })
    view.begin({ usageSource: "cliproxy", cliproxyUrl: serverUrl, cliproxyKeyFile: "",
      costKeeperUrl: "https://keeper.example", costKeeperPasswordFile: "/private/keeper" }, "limits")
    check(view.tab === "limits" && form.visible && !view.costForm.visible, "the Limits tab opens")
    check(form.draft.usageSource === "proxy" && form.proxyMode, "renamed proxy source is read")
    check(form.draft.proxyUrl === serverUrl && form.draft.keeperUrl === "https://keeper.example"
      && form.draft.keeperPasswordFile === "/private/keeper", "renamed connection settings are read")
    check(form.connectionExpanded, "an unconfigured connection starts expanded")
    form.activityExpanded = true
    check(form.knownImplementation === "" && form.proxyName === "Fusebox / CLIProxyAPI", "nothing is detected yet")
    check(shown("keeperUrlField") && shown("liveAccountActivityToggle"), "an unknown server shows every activity setting")
    connectionTest = find(form, "proxyConnectionTest")
    check(connectionTest !== null, "connection test exists")
    form.managementKey = "synthetic-fusebox-key"
    connectionTest.test()
    check(connectionTest.testing, "the test starts")
  }

  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      if (root.connectionTest.testing) return
      if (root.phase === 0) {
        root.check(root.connectionTest.status === "ok", "draft key connects: " + root.connectionTest.message)
        root.check(root.connectionTest.message.indexOf("Connected to Fusebox · 4 accounts") === 0, root.connectionTest.message)
        root.check(root.form.knownImplementation === "rust" && root.form.proxyName === "Fusebox", "the test detects Fusebox")
        root.check(!root.shown("keeperUrlField") && root.shown("liveAccountActivityToggle"), "Fusebox hides Keeper settings")
        root.check(root.connectionTest.usageOk && root.connectionTest.usageMessage === "Usage history available for Costs."
          && root.find(root.form, "connectionTestUsage").visible, "the test reports Fusebox usage history for Costs")
        root.check(root.view.costForm.usesFusebox && root.view.costForm.limitsUrl === root.serverUrl,
          "the Costs tab follows the tested, unsaved Fusebox connection")
        root.form.managementKey = "synthetic-wrong-key"
        root.check(root.connectionTest.status === "idle" && root.form.knownImplementation === "",
          "editing the key discards the earlier result")
        root.connectionTest.test()
        root.phase++
      } else if (root.phase === 1) {
        root.check(root.connectionTest.status === "failed"
          && root.connectionTest.message.indexOf("rejected the management key") >= 0, root.connectionTest.message)
        root.check(root.connectionTest.message.indexOf("synthetic-wrong-key") < 0, "the key is never displayed")
        root.form.managementKey = ""
        // The last refresh detected Go for this saved connection.
        root.form.proxyImplementation = "go"
        root.check(root.form.knownImplementation === "go", "the saved connection's detection applies")
        root.check(root.shown("keeperUrlField") && !root.shown("liveAccountActivityToggle"), "CLIProxyAPI hides live activity")
        root.form.setValue("proxyUrl", root.serverUrl + "/other")
        root.check(root.form.knownImplementation === "", "a different draft URL is not assumed to be the same server")
        root.form.setValue("proxyUrl", root.serverUrl)
        root.form.proxyImplementation = "rust"
        // Hidden Keeper fields keep their saved values and are not validated.
        root.form.setValue("keeperUrl", "not a URL")
        // Edits on one tab survive switching to the other; Save writes both.
        root.view.selectTab("costs")
        root.view.costForm.chooseHistory("local")
        root.view.selectTab("limits")
        root.check(root.view.costForm.historySource === "local" && root.view.costForm.touched, "Costs edits survive tab switches")
        root.check(root.view.submit() && root.saved !== null, "save succeeds: " + root.view.errorText)
        root.check(root.saved.costHistorySource === "local" && root.saved.costPriceOverrides === "{}",
          "one Save includes the Costs tab")
        root.check(root.saved.usageSource === "proxy" && root.saved.proxyUrl === root.serverUrl
          && root.saved.keeperPasswordFile === "/private/keeper"
          && root.saved.cliproxyUrl === undefined && root.saved.costKeeperUrl === undefined,
          "settings save under their current names")
        root.form.proxyImplementation = "go"
        root.view.selectTab("costs")
        root.check(!root.view.submit() && root.view.errorText.indexOf("Keeper") >= 0 && root.view.tab === "limits",
          "visible Keeper settings are validated, and their tab opens")
        console.log("Settings QML contract: passed")
        Qt.quit()
      }
    }
  }
  Timer { interval: 12000; running: true; onTriggered: root.check(false, "timed out at phase " + root.phase) }
}
