import QtQuick
import Quickshell

ShellRoot {
  id: root
  property var form: null
  property var backend: null
  property var openingBackend: null
  property int openingResponses: 0
  property var view: null
  property var overview: null
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
    form = create("CostSettings.qml", { width: 420 })
    form.saveRequested.connect(function(values) { root.saved = values })
    form.begin({costPriceOverrides: custom})
    view = create("UsageCosts.qml", {width: 420, payload: {
      source: "transcripts", generatedAt: "2030-01-15T12:00:00Z",
      totals: {records: 0, totalTokens: 0, costUsd: 0, historyStatus: "unavailable"},
      providers: [], models: [],
      sources: [{id: "remote", name: "T3 server", status: "unavailable", included: false}],
      periods: [{start: "2030-01-15", records: 0, costUsd: 0, totalTokens: 0,
        historyStatus: "unavailable", providers: []}]
    }})
    var models = []
    for (var i = 0; i < 10; i++)
      models.push({model: "model-" + i, providerName: "Example", costUsd: 10, totalTokens: 1000})
    overview = create("UsageCosts.qml", {width: 420, payload: {
      generatedAt: "2030-01-15T12:00:00Z", period: {days: 30},
      totals: {records: 1000, pricedRecords: 999, unpricedRecords: 1, costUsd: 1234.56,
        totalTokens: 1000000, sessions: 6},
      providers: [{id: "example", name: "Example", records: 1000, pricedRecords: 999,
        unpricedRecords: 1, costUsd: 1234.56, totalTokens: 1000000}],
      models: models, periods: [{start: "2030-01-15", costUsd: 1234.56, totalTokens: 1000000}]
    }})
    overview.periodRequested.connect(function(days) { root.overview.periodDays = days })
    backend = create("CostBackend.qml", {settings: {costLocalProviders: ["claude"]}})
    openingBackend = create("CostBackend.qml", {settings: {costLocalProviders: ["claude"]}})
    openingBackend.refreshed.connect(function() { root.openingResponses++ })
    openingBackend.ensureLoaded()
    openingBackend.ensureLoaded()
    openingBackend.ensureLoaded()
    backend.refreshed.connect(function() {
      root.responses++
      if (root.responses === 1) root.check(!backend.payload.testRequest.force, "automatic scan respects rate TTL")
    })
    backend.ensureLoaded()
    // A refresh and settings edit while a process is running must reach the
    // follow-up invocation together; neither may be lost or overlap it.
    backend.refresh()
    backend.settings = {costLocalProviders: ["claude"], costPriceOverrides: custom}
  }

  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      if (root.phase === 0) {
        root.check(!root.form.remoteExpanded && !root.form.pricesExpanded && !root.form.diagnosticsExpanded,
          "cost settings start with advanced sections collapsed")
        root.check(!root.find(root.overview, "costModelDetails").visible, "model breakdown starts collapsed")
        root.check(!root.find(root.overview, "costTokenDetails").visible, "cost overview starts without token details")
        root.check(root.find(root.overview, "costModel-0") === null, "collapsed models are not instantiated")
        root.check(root.find(root.overview, "costSummaryValue").text === "$1,234.56", "currency has readable thousands separators")
        root.check(!root.find(root.overview, "costPricingNotice").visible, "high pricing coverage does not warn")
        root.check(root.overview.providerMetaText(root.overview.providers[0]).indexOf("99%") >= 0,
          "small gaps remain available in details without rounding up to complete coverage")
        var originalOverview = root.overview.payload
        var boundaryOverview = JSON.parse(JSON.stringify(originalOverview))
        boundaryOverview.totals.pricedRecords = 900
        boundaryOverview.totals.unpricedRecords = 100
        root.overview.payload = boundaryOverview
        root.check(!root.find(root.overview, "costPricingNotice").visible, "exactly 90 percent does not warn")
        boundaryOverview = JSON.parse(JSON.stringify(boundaryOverview))
        boundaryOverview.totals.pricedRecords = 899
        boundaryOverview.totals.unpricedRecords = 101
        root.overview.payload = boundaryOverview
        root.check(root.find(root.overview, "costPricingNotice").visible, "coverage below 90 percent warns")
        boundaryOverview = JSON.parse(JSON.stringify(boundaryOverview))
        boundaryOverview.totals.pricedRecords = 0
        boundaryOverview.totals.unpricedRecords = 1000
        root.overview.payload = boundaryOverview
        root.check(root.overview.pricingNotice().indexOf("Pricing unavailable") === 0, "unavailable pricing still warns")
        root.overview.payload = originalOverview
        root.find(root.overview, "costMetricMenu").changed("tokens")
        root.check(root.find(root.overview, "costTokenDetails").visible, "Tokens automatically opens token details")
        root.check(root.find(root.overview, "costSummaryValue").text === "1M", "metric selection updates the total")
        root.check(!root.find(root.overview, "costPricingNotice").visible, "unpriced costs do not qualify measured tokens")
        root.find(root.overview, "costMetricMenu").changed("cost")
        root.check(!root.find(root.overview, "costTokenDetails").visible, "returning to estimates restores the compact view")
        root.find(root.overview, "costPeriodTabs").setCurrentIndex(0)
        root.check(root.overview.periodDays === 1, "period tab requests 24 hours")
        root.check(root.overview.summaryDetail().indexOf("30 days") === 0, "old totals retain their actual period during a new scan")
        root.overview.modelsExpanded = true
        root.check(root.find(root.view, "costSummaryValue").text === "—", "missing history is not a zero estimate")
        root.check(root.find(root.view, "costHistoryGap-0").visible, "missing chart history is marked")
        root.check(root.find(root.view, "costSource-remote") === null, "source diagnostics are absent from Costs")
        root.form.sources = root.view.payload.sources
        root.check(root.find(root.view, "costClient-t3") === null, "app filters are removed")
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
        root.check(root.form.pricesExpanded, "adding a price opens its editor")
        root.check(root.find(root.overview, "costModel-9") !== null, "expanded breakdown includes models beyond the former top eight")
        root.check(root.find(root.overview, "costModelDetails").visible, "expanded models render")
        root.overview.modelsExpanded = false
        root.check(root.find(root.overview, "costModel-9") === null, "collapsing releases model rows")
        root.check(root.find(root.form, "costSource-remote").text.indexOf("Unavailable") >= 0, "source diagnostics are available in Costs settings")
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
        root.check(root.openingResponses === 1 && !root.openingBackend.loading,
          "opening Costs through multiple view notifications starts only one scan")
        root.check(root.responses === 2, "overlapping requests collapse to one follow-up scan")
        root.check(root.backend.payload.testRequest.force, "queued explicit refresh forces prices")
        root.check(root.backend.payload.testRequest.prices === root.custom, "custom prices reach the process as exact JSON")
        root.backend.selectPeriod(7)
        root.phase++
      } else if (root.phase === 3 && root.responses === 3 && !root.backend.loading) {
        root.check(!root.backend.payload.testRequest.force, "period changes do not force price downloads")
        var lastGood = root.backend.payload
        root.backend.settings = {costLocalProviders: ["codex"]}
        root.saved = lastGood
        root.phase++
      } else if (root.phase === 4 && root.backend.fetchError !== "" && !root.backend.loading) {
        root.check(!root.backend.payload.generatedAt, "source change clears old totals even on failure")
        root.form.begin({costLocalProviders: [], costT3Servers: '[{"id":"first","name":"Remote","url":"https://first.example","tokenFile":"","enabled":true}]'})
        root.check(root.form.submit(), "T3 settings save")
        root.check(root.saved.costLocalProviders.length === 0 && JSON.parse(root.saved.costT3Servers)[0].enabled, "remote-only setting round trips and is included")
        root.backend.settings = root.saved
        root.phase++
      } else if (root.phase === 5 && root.backend.loading) {
        root.backend.settings = {costLocalProviders: [], costT3Servers: '[{"id":"second","name":"Second","url":"https://second.example","tokenFile":"","enabled":true}]'}
        root.phase++
      } else if (root.phase === 6 && !root.backend.loading && root.backend.payload.generatedAt) {
        root.check(JSON.parse(root.backend.payload.testRequest.servers)[0].url === "https://second.example", "in-flight old server response is discarded")
        root.form.begin({})
        root.form.addServer()
        root.phase++
      } else if (root.phase === 7) {
        root.check(root.form.remoteExpanded && root.find(root.form, "t3Details-0").expanded,
          "adding a server opens the section and its connection editor")
        root.form.remoteExpanded = false
        root.check(!root.form.submit(), "new server needs a valid URL")
        root.check(root.form.remoteExpanded, "invalid server expands the hidden section")
        root.edit("t3Url-0", "https://t3.example")
        root.edit("t3Token-0", "synthetic-t3-token")
        root.saved = null
        root.form.saveRequested.connect(function(values) { root.form.finishSave(true) })
        root.check(root.form.submit(), "private token staging starts")
        root.phase++
      } else if (root.phase === 8 && root.saved && !root.form.saving) {
        var remote = JSON.parse(root.saved.costT3Servers)[0]
        root.check(remote.enabled && remote.tokenFile.indexOf("/management-keys/key-") >= 0, "token stored as private file reference")
        root.check(JSON.stringify(root.saved).indexOf("synthetic-t3-token") < 0, "raw token never enters widget settings")
        root.form.begin(root.saved)
        root.check(!root.form.remoteExpanded, "saved server starts summarized")
        root.check(root.find(root.form, "t3Credential-0").saved, "saved token has an explicit configured state")
        root.check(!root.find(root.form, "t3Token-0").visible, "saved token does not show an empty editor")
        root.check(root.form.submit(), "blank token preserves saved credential")
        root.check(JSON.parse(root.saved.costT3Servers)[0].tokenFile === remote.tokenFile, "saved token path round trips")
        console.log("Cost QML contract: passed")
        Qt.quit()
      }
    }
  }
  Timer { interval: 8000; running: true; onTriggered: { root.check(false, "timed out at phase " + root.phase + "; responses=" + root.responses + "; error=" + root.backend.fetchError + "; loading=" + root.backend.loading + "; request=" + JSON.stringify(root.backend.payload.testRequest)); Qt.quit() } }
}
