import QtQuick
import Quickshell

ShellRoot {
  id: root
  property var form: null
  property var backend: null
  property var view: null
  property string pickedClient: ""
  property var saved: null
  property int responses: 0
  property int phase: 0
  readonly property string custom: '{"vendor/Example[1m]":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":8,"cacheReadCostPerMillionTokens":0}}'

  function check(condition, message) {
    if (!condition) throw new Error("COST TEST FAILED: " + message)
  }
  function create(name, values) {
    var component = Qt.createComponent(Quickshell.env("MODEL_USAGE_REPO_URL") + "/" + name)
    check(component.status === Component.Ready, component.errorString())
    var object = component.createObject(root, values || {})
    check(object !== null, component.errorString())
    return object
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
  function edit(name, text) {
    var field = find(form, name)
    check(field !== null, "price field exists: " + name)
    field.text = text
    field.textEdited()
  }

  Component.onCompleted: {
    form = create("UsageSettings.qml", { width: 420 })
    form.saveRequested.connect(function(values) { root.saved = values })
    form.begin({costPriceOverrides: custom})
    view = create("UsageCosts.qml", {width: 420, payload: {
      source: "keeper", generatedAt: "2030-01-15T12:00:00Z",
      totals: {records: 0, totalTokens: 0, costUsd: 0, historyStatus: "unavailable"},
      providers: [], models: [],
      clients: [{id: "all", name: "All apps"}, {id: "t3", name: "T3 Code"}],
      history: {firstRecordAt: 1894708800000, message: "Earlier history is unavailable."},
      periods: [{start: "2030-01-15", records: 0, costUsd: 0, totalTokens: 0,
        historyStatus: "unavailable", providers: []}]
    }})
    view.clientRequested.connect(function(value) { root.pickedClient = value })
    backend = create("CostBackend.qml", {settings: {enabledProviders: ["claude"]}})
    backend.refreshed.connect(function() {
      root.responses++
      if (root.responses === 1) root.check(!backend.payload.testRequest.force, "automatic scan respects rate TTL")
    })
    backend.ensureLoaded()
    // A refresh and settings edit while a process is running must reach the
    // follow-up invocation together; neither may be lost or overlap it.
    backend.refresh()
    backend.settings = {enabledProviders: ["claude"], costPriceOverrides: custom}
  }

  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      if (root.phase === 0) {
        root.check(root.find(root.view, "costSummaryValue").text === "—", "missing history is not a zero estimate")
        root.check(root.find(root.view, "costHistoryGap-0").visible, "missing chart history is marked")
        root.check(root.find(root.view, "proxyHistoryCoverage").text.indexOf("2030") >= 0,
          "actual first saved date is shown")
        root.find(root.view, "costClient-t3").changed("t3")
        root.check(root.pickedClient === "t3", "app control requests the selected filter")
        root.check(root.form.priceEditor.serialize() === root.custom, "saved prices round-trip through QML model roles")
        root.edit("costRate-0-outputCostPerMillionTokens", "12")
        root.check(JSON.parse(root.form.priceEditor.serialize())["vendor/Example[1m]"].outputCostPerMillionTokens === 12,
          "editing a field updates its model role")
        root.form.submit()
        root.check(JSON.parse(root.saved.costPriceOverrides)["vendor/Example[1m]"].outputCostPerMillionTokens === 12,
          "Save includes the edited custom price")
        root.form.begin({costPriceOverrides: root.custom})
        root.check(root.form.priceEditor.serialize() === root.custom, "reopening discards unsaved draft prices")
        root.form.priceEditor.addPrice()
        root.phase++
      } else if (root.phase === 1) {
        root.check(!root.form.submit(), "blank added rows block Save")
        root.edit("costModel-1", "free-model")
        root.edit("costRate-1-inputCostPerMillionTokens", "0")
        root.edit("costRate-1-outputCostPerMillionTokens", "0")
        root.check(root.form.submit(), "explicit zero prices can be saved")
        root.check(JSON.parse(root.saved.costPriceOverrides)["free-model"].outputCostPerMillionTokens === 0,
          "zero survives settings serialization")
        root.form.begin({costPriceOverrides: "invalid"})
        root.check(!root.form.submit(), "invalid existing prices cannot be silently replaced")
        root.form.priceEditor.begin("{}")
        root.check(root.form.submit() && root.saved.costPriceOverrides === "{}", "removing prices restores automatic pricing")
        root.phase++
      } else if (root.phase === 2 && root.responses >= 2 && !root.backend.loading) {
        root.check(root.responses === 2, "overlapping requests collapse to one follow-up scan")
        root.check(root.backend.payload.testRequest.force, "queued explicit refresh forces prices")
        root.check(root.backend.payload.testRequest.prices === root.custom, "custom prices reach the process as exact JSON")
        root.backend.selectPeriod(7)
        root.phase++
      } else if (root.phase === 3 && root.responses === 3 && !root.backend.loading) {
        root.check(!root.backend.payload.testRequest.force, "period changes do not force price downloads")
        var lastGood = root.backend.payload
        root.backend.settings = {enabledProviders: ["codex"]}
        root.saved = lastGood
        root.phase++
      } else if (root.phase === 4 && root.backend.fetchError !== "" && !root.backend.loading) {
        root.check(root.backend.payload === root.saved, "failed refresh preserves the last good costs")
        root.form.begin({costSource: "keeper", costKeeperUrl: "https://keeper.example/keeper",
          costKeeperPasswordFile: "/private/password", costLocalBackfill: true})
        root.check(root.form.submit(), "Keeper settings save")
        root.check(root.saved.costSource === "keeper" && root.saved.costKeeperPasswordFile === "/private/password",
          "Keeper source and private password path round trip")
        root.check(root.saved.costLocalBackfill === true, "local recovery setting round trips")
        root.backend.settings = root.saved
        root.check(root.backend.payload.generatedAt === "", "switching sources clears local totals")
        root.phase++
      } else if (root.phase === 5 && root.backend.loading) {
        root.backend.settings = {costSource: "keeper", costKeeperUrl: "https://second.example/keeper",
          costKeeperPasswordFile: "/private/second", costLocalBackfill: true}
        root.backend.selectClient("t3")
        root.phase++
      } else if (root.phase === 6 && !root.backend.loading && root.backend.payload.generatedAt) {
        root.check(root.backend.payload.source === "keeper", "archive source reaches process")
        root.check(root.backend.payload.testRequest.url === "https://second.example/keeper", "old archive response is discarded")
        root.check(root.backend.payload.testRequest.passwordFile === "/private/second", "password path reaches process")
        root.check(root.backend.payload.testRequest.client === "t3", "in-flight old app response is discarded")
        root.check(root.backend.payload.testRequest.backfill, "recovery setting reaches process")
        root.backend.selectClient("codex-cli")
        root.check(!root.backend.payload.generatedAt, "changing app clears the old total")
        root.phase++
      } else if (root.phase === 7 && !root.backend.loading && root.backend.payload.generatedAt) {
        root.check(root.backend.payload.testRequest.client === "codex-cli", "app selection changes the next total")
        root.backend.settings = {enabledProviders: ["codex"]}
        root.phase++
      } else if (root.phase === 8 && !root.backend.loading && root.backend.fetchError !== "") {
        root.check(root.backend.payload.generatedAt === "", "a failing different source cannot retain proxy totals")
        console.log("Cost QML contract: passed")
        Qt.quit()
      }
    }
  }
  Timer { interval: 8000; running: true; onTriggered: { root.check(false, "timed out at phase " + root.phase + "; responses=" + root.responses + "; error=" + root.backend.fetchError + "; loading=" + root.backend.loading + "; request=" + JSON.stringify(root.backend.payload.testRequest)); Qt.quit() } }
}
