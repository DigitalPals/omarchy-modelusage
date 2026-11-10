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
  property var keyField: null
  property int pasteEdits: 0
  property double pasteStarted: 0
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
        var earlierGeneration = root.connectionTest.generation
        var earlierRequest = root.connectionTest.requestId
        root.check(earlierRequest !== "", "each test carries a request ID")
        root.form.managementKey = "synthetic-wrong-key"
        root.check(root.connectionTest.status === "idle" && root.form.knownImplementation === "",
          "editing the key discards the earlier result")
        root.connectionTest.test()
        root.check(root.connectionTest.testing && root.connectionTest.requestId !== earlierRequest,
          "a new test is a new request")
        // A late answer from the earlier run, even one naming its own request,
        // never settles the test of the changed key.
        root.connectionTest.settle(JSON.stringify({ schemaVersion: 1, ok: true, implementation: "rust",
          message: "Connected to Fusebox · stale", requestId: earlierRequest }), earlierGeneration, earlierRequest)
        root.check(root.connectionTest.testing && root.connectionTest.message === ""
          && root.form.knownImplementation === "", "a stale result is ignored")
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
        // Paste goes through a separate, bounded wl-paste process (a fake on
        // PATH): a newer request retires an older one that never finishes.
        root.keyField = root.find(root.form, "managementKeyField")
        root.check(root.keyField !== null && root.keyField.pasteMenuItem !== undefined, "the key field pastes boundedly")
        root.keyField.textEdited.connect(function() { root.pasteEdits++ })
        root.form.managementKey = ""
        // The key is saved now: open its editor, as "Change" does.
        root.keyField.parent.changing = true
        root.phase++
      } else if (root.phase === 2) {
        // A tick later: the failed Save above focuses its invalid field late.
        root.keyField.forceActiveFocus()
        root.check(root.keyField.visible && root.keyField.focus, "the key field takes focus")
        root.keyField.pasteFromClipboard(true)
        root.check(root.keyField.pasting, "a primary-selection paste starts")
        root.keyField.pasteFromClipboard(false)
        root.check(root.keyField.pasting && root.keyField.text === "", "a newer paste replaces it")
        root.phase++
      } else if (root.phase === 3) {
        if (root.keyField.pasting) return
        root.check(root.keyField.text === "synthetic-pasted-key" && root.pasteEdits === 1,
          "the clipboard line is pasted once, without its line break: " + root.keyField.text + " " + root.pasteEdits)
        root.check(root.form.managementKey === "synthetic-pasted-key", "a paste edits the draft")
        root.form.managementKey = ""
        root.keyField.pasteCharLimit = 8
        root.keyField.pasteFromClipboard(false)
        root.phase++
      } else if (root.phase === 4) {
        if (root.keyField.pasting) return
        root.check(root.keyField.text === "", "a clipboard over the limit is not pasted")
        root.keyField.pasteCharLimit = 16384
        root.keyField.pasteTimeoutMs = 300
        root.pasteStarted = Date.now()
        root.keyField.pasteFromClipboard(true)
        root.phase++
      } else if (root.phase === 5) {
        if (root.keyField.pasting) return
        root.check(Date.now() - root.pasteStarted < 2000 && root.keyField.text === "",
          "a clipboard owner that never finishes is abandoned at the deadline")
        root.keyField.pasteFromClipboard(false)
        var urlField = root.find(root.form, "proxyUrlField")
        var urlText = urlField.text
        urlField.forceActiveFocus()
        root.check(!root.keyField.pasting, "moving to another field retires the paste")
        root.pasteStarted = Date.now()
        root.phase++
        root.check(urlField.text === urlText, "nothing is pasted into the newly focused field")
      } else if (root.phase === 6) {
        if (Date.now() - root.pasteStarted < 400) return
        root.check(root.keyField.text === "", "a retired paste never arrives")
        root.keyField.forceActiveFocus()
        root.keyField.pasteMenuItem.triggered()
        root.check(root.keyField.pasting, "the context menu's Paste uses the bounded read")
        root.phase++
      } else if (root.phase === 7) {
        if (root.keyField.pasting) return
        root.check(root.keyField.text === "synthetic-pasted-key", "the context menu pastes: " + root.keyField.text)
        console.log("Settings QML contract: passed")
        Qt.quit()
      }
    }
  }
  Timer { interval: 12000; running: true; onTriggered: root.check(false, "timed out at phase " + root.phase) }
}
