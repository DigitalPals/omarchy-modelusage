import QtQuick
import Quickshell

ShellRoot {
  id: root
  // SettingsView with its Costs tab: Save collects both tabs.
  property var settings: null
  property var form: null
  property var backend: null
  property var openingBackend: null
  property var fuseboxBackend: null
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
  function begin(values) { settings.begin(values, "costs") }
  function shown(name) {
    var item = find(form, name)
    check(item !== null, "item exists: " + name)
    for (var node = item; node && node !== settings; node = node.parent)
      if (!node.visible) return false
    return true
  }
  function edit(name, text) {
    var field = find(form, name)
    check(field !== null, "price field exists: " + name)
    field.text = text
    field.textEdited()
  }

  Component.onCompleted: {
    settings = create("SettingsView.qml", { width: 420 })
    form = settings.costForm
    settings.saveRequested.connect(function(values) { root.saved = values })
    begin({costPriceOverrides: custom})
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
    // Limits on an undetected proxy: Costs try it as Fusebox, quietly.
    fuseboxBackend = create("CostBackend.qml", {settings: {costLocalProviders: ["claude"], usageSource: "proxy",
      proxyUrl: "https://fusebox.example", proxyKeyFile: "/private/fusebox.key"}})
    fuseboxBackend.ensureLoaded()
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
        root.check(!root.overview.lowPricingCoverage
          && root.overview.pricingNotice().indexOf("Partial estimate · 99%") === 0,
          "high pricing coverage is noted neutrally, not as a warning")
        root.check(root.overview.providerMetaText(root.overview.providers[0]).indexOf("99%") >= 0,
          "small gaps remain available in details without rounding up to complete coverage")
        var originalOverview = root.overview.payload
        var boundaryOverview = JSON.parse(JSON.stringify(originalOverview))
        boundaryOverview.totals.pricedRecords = 900
        boundaryOverview.totals.unpricedRecords = 100
        root.overview.payload = boundaryOverview
        root.check(!root.overview.lowPricingCoverage
          && root.overview.pricingNotice().indexOf("Partial estimate") === 0, "exactly 90 percent does not warn")
        boundaryOverview = JSON.parse(JSON.stringify(boundaryOverview))
        boundaryOverview.totals.pricedRecords = 899
        boundaryOverview.totals.unpricedRecords = 101
        root.overview.payload = boundaryOverview
        root.check(root.overview.lowPricingCoverage
          && root.overview.pricingNotice().indexOf("Incomplete estimate") === 0, "coverage below 90 percent warns")
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
        var originalView = root.view.payload
        var fallback = JSON.parse(JSON.stringify(originalView))
        fallback.sources = [
          {id: "fusebox", name: "Fusebox", kind: "fusebox", status: "unavailable", included: false,
            message: "Fusebox usage request timed out."},
          {id: "local-claude", name: "Local Claude", kind: "local", status: "ok", included: true}]
        root.view.payload = fallback
        root.check(root.find(root.view, "costFuseboxFailure").visible
          && root.view.fuseboxFailure.title.indexOf("showing this computer's history instead") > 0
          && root.view.fuseboxFailure.detail === "Fusebox usage request timed out.",
          "a failed Fusebox read says why and what is shown instead")
        root.check(root.view.sourceNotice().indexOf("Fusebox") < 0, "the failure is not repeated in the source notice")
        root.check(root.find(root.view, "costSourceLink").text === "From this computer ›", "the source line names this computer")
        fallback = JSON.parse(JSON.stringify(fallback))
        fallback.sources = [{id: "fusebox-claude", name: "Fusebox · Claude Code", kind: "fusebox", status: "ok", included: true},
          {id: "local-claude", name: "Local Claude", kind: "local", status: "replaced", included: false}]
        root.view.fuseboxHost = "fusebox.home.lan"
        root.view.payload = fallback
        root.check(!root.find(root.view, "costFuseboxFailure").visible
          && root.find(root.view, "costSourceLink").text === "From Fusebox · fusebox.home.lan ›", "the source line names the server")
        var opened = false
        root.view.sourceSettingsRequested.connect(function() { opened = true })
        root.find(root.view, "costSourceLink").clicked()
        root.check(opened, "the source line opens the Costs settings")
        root.view.fuseboxHost = ""
        root.view.payload = originalView
        root.form.sources = root.view.payload.sources
        root.check(root.find(root.view, "costClient-t3") === null, "app filters are removed")
        root.check(root.form.priceEditor.serialize() === root.custom, "saved prices round-trip through QML model roles")
        root.edit("costRate-0-outputCostPerMillionTokens", "12")
        root.check(JSON.parse(root.form.priceEditor.serialize())["vendor/Example[1m]"].outputCostPerMillionTokens === 12,
          "editing a field updates its model role")
        root.settings.submit()
        root.check(JSON.parse(root.saved.costPriceOverrides)["vendor/Example[1m]"].outputCostPerMillionTokens === 12,
          "Save includes the edited custom price")
        root.begin({costPriceOverrides: root.custom})
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
        root.check(!root.settings.submit(), "blank added rows block Save")
        root.edit("costModel-1", "free-model")
        root.edit("costRate-1-inputCostPerMillionTokens", "0")
        root.edit("costRate-1-outputCostPerMillionTokens", "0")
        root.check(root.settings.submit(), "explicit zero prices can be saved")
        root.check(JSON.parse(root.saved.costPriceOverrides)["free-model"].outputCostPerMillionTokens === 0,
          "zero survives settings serialization")
        root.begin({costPriceOverrides: "invalid"})
        root.check(!root.settings.submit(), "invalid existing prices cannot be silently replaced")
        root.form.priceEditor.begin("{}")
        root.check(root.settings.submit() && root.saved.costPriceOverrides === "{}", "removing prices restores automatic pricing")
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
        root.begin({costLocalProviders: [], costT3Servers: '[{"id":"first","name":"Remote","url":"https://first.example","tokenFile":"","enabled":true}]'})
        root.check(root.settings.submit(), "T3 settings save")
        root.check(root.saved.costLocalProviders.length === 0 && JSON.parse(root.saved.costT3Servers)[0].enabled, "remote-only setting round trips and is included")
        root.backend.settings = root.saved
        root.phase++
      } else if (root.phase === 5 && root.backend.loading) {
        root.backend.settings = {costLocalProviders: [], costT3Servers: '[{"id":"second","name":"Second","url":"https://second.example","tokenFile":"","enabled":true}]'}
        root.phase++
      } else if (root.phase === 6 && !root.backend.loading && root.backend.payload.generatedAt) {
        root.check(JSON.parse(root.backend.payload.testRequest.servers)[0].url === "https://second.example", "in-flight old server response is discarded")
        root.begin({})
        root.form.addServer()
        root.phase++
      } else if (root.phase === 7) {
        root.check(root.form.remoteExpanded && root.find(root.form, "t3Details-0").expanded,
          "adding a server opens the section and its connection editor")
        root.form.remoteExpanded = false
        root.check(!root.settings.submit(), "new server needs a valid URL")
        root.check(root.form.remoteExpanded, "invalid server expands the hidden section")
        root.edit("t3Url-0", "https://t3.example")
        root.edit("t3Token-0", "synthetic-t3-token")
        root.saved = null
        root.settings.saveRequested.connect(function(values) { root.settings.finishSave(true) })
        root.check(root.settings.submit(), "private token staging starts")
        root.phase++
      } else if (root.phase === 8 && root.saved && !root.settings.saving) {
        var remote = JSON.parse(root.saved.costT3Servers)[0]
        root.check(remote.enabled && remote.tokenFile.indexOf("/management-keys/key-") >= 0, "token stored as private file reference")
        root.check(JSON.stringify(root.saved).indexOf("synthetic-t3-token") < 0, "raw token never enters widget settings")
        root.begin(root.saved)
        root.check(!root.form.remoteExpanded, "saved server starts summarized")
        root.check(root.find(root.form, "t3Credential-0").saved, "saved token has an explicit configured state")
        root.check(!root.find(root.form, "t3Token-0").visible, "saved token does not show an empty editor")
        root.check(root.settings.submit(), "blank token preserves saved credential")
        root.check(JSON.parse(root.saved.costT3Servers)[0].tokenFile === remote.tokenFile, "saved token path round trips")
        var request = root.fuseboxBackend.payload.testRequest
        root.check(request && JSON.stringify(request.fusebox) === '["https://fusebox.example","/private/fusebox.key","fusebox"]'
          && request.fuseboxOptional === true && root.fuseboxBackend.fuseboxHost === "fusebox.example",
          "Costs read the Limits Fusebox with its key, quietly when it has no usage history")
        root.fuseboxBackend.proxyImplementation = "go"
        root.check(!root.fuseboxBackend.fuseboxEnabled, "a detected CLIProxyAPI is not asked for usage history")
        root.fuseboxBackend.settings = {costLocalProviders: ["claude"], usageSource: "proxy", costHistorySource: "local"}
        root.fuseboxBackend.proxyImplementation = "rust"
        root.check(!root.fuseboxBackend.fuseboxEnabled, "choosing this computer leaves Fusebox out")
        // A different Fusebox server for Costs needs its own key.
        root.begin({costFuseboxConnection: "custom", costFuseboxUrl: "https://fusebox.example"})
        root.settings.selectTab("limits")
        root.check(!root.settings.submit() && root.form.fuseboxExpanded && root.settings.tab === "costs",
          "a problem on the Costs tab opens it, with the server section expanded")
        // Settings saved with the old Fusebox switch keep their server and overlap choice.
        root.begin({costFuseboxEnabled: true, costFuseboxUrl: "https://fusebox.example",
          costFuseboxKeyFile: "/private/fusebox.key", costFuseboxOverlap: "transcripts"})
        root.check(root.find(root.form, "costFuseboxCredential").saved, "saved Fusebox key has a configured state")
        root.check(root.form.customFusebox && root.form.historySource === "mixed" && root.form.fuseboxAvailable,
          "the old switch and overlap carry over")
        root.check(root.shown("costHistoryControl") && root.shown("costFuseboxOtherProviders"),
          "a different server offers the choice even with local Limits")
        root.check(root.settings.submit() && root.saved.costHistorySource === "mixed"
          && root.saved.costFuseboxKeyFile === "/private/fusebox.key"
          && root.saved.costFuseboxConnection === "custom"
          && root.saved.costFuseboxEnabled === undefined && root.saved.costFuseboxOverlap === undefined,
          "Fusebox settings round trip under their new names; blank key keeps the saved file")
        // The old switch left off (also the old default) follows Limits.
        root.begin({costFuseboxEnabled: false, usageSource: "proxy", proxyUrl: "https://limits.example",
          proxyKeyFile: "/private/limits.key"})
        root.check(!root.form.customFusebox && root.form.limitsFusebox && root.form.usesFusebox,
          "a Fusebox Limits connection supplies costs without a switch")
        root.check(root.find(root.form, "costHistoryDescription").text.indexOf("limits.example") >= 0,
          "the description names the server")
        root.check(root.shown("costInactiveNotice") && !root.shown("costFuseboxOtherProviders"),
          "this computer's settings are marked unused while Fusebox supplies costs")
        root.check(root.settings.submit() && root.saved.costHistorySource === "auto"
          && root.saved.costFuseboxConnection === "limits", "following Limits saves as auto")
        root.find(root.form, "costHistoryControl").changed("local")
        root.check(root.form.historySource === "local" && !root.shown("costInactiveNotice")
          && root.shown("costFuseboxOtherProviders"), "choosing this computer offers Fusebox's other providers")
        root.find(root.form, "costFuseboxOtherProviders").toggled()
        root.check(root.form.historySource === "mixed" && root.settings.submit()
          && root.saved.costHistorySource === "mixed", "the extra providers save as mixed")
        root.find(root.form, "costHistoryControl").changed("fusebox")
        root.check(root.form.historySource === "auto", "choosing Fusebox returns to following Limits")
        // The Costs tab reads the unsaved Limits draft.
        root.settings.limitsForm.setValue("usageSource", "direct")
        root.check(!root.form.fuseboxAvailable && !root.shown("costHistoryControl")
          && root.find(root.form, "costHistoryDescription").text.indexOf("no Fusebox server") >= 0,
          "local Limits leave nothing to choose")
        root.check(root.settings.limitsForm.touched
          && root.find(root.settings, "settingsTabs").marked.indexOf("limits") >= 0, "a tab with unsaved edits is marked")
        root.settings.limitsForm.setValue("usageSource", "proxy")
        root.settings.limitsForm.proxyImplementation = "go"
        root.check(!root.form.fuseboxAvailable
          && root.find(root.form, "costHistoryDescription").text.indexOf("CLIProxyAPI keeps no usage history") === 0,
          "CLIProxyAPI Limits explain why costs are local")
        root.settings.limitsForm.proxyImplementation = ""
        root.begin({usageSource: "cliproxy", cliproxyUrl: "https://legacy.example", cliproxyKeyFile: "/private/legacy.key"})
        root.check(root.form.limitsUrl === "https://legacy.example" && root.form.usesFusebox && root.settings.submit(),
          "renamed Limits settings are still read")
        root.form.setFuseboxConnection("custom")
        root.check(root.form.fuseboxUrl === "https://legacy.example", "a different server starts from the Limits URL")
        root.begin({costFuseboxUrl: "https://user:secret@fusebox.example"})
        root.check(!root.settings.submit(), "Fusebox URL credentials cannot be saved")
        console.log("Cost QML contract: passed")
        Qt.quit()
      }
    }
  }
  Timer { interval: 8000; running: true; onTriggered: { root.check(false, "timed out at phase " + root.phase + "; responses=" + root.responses + "; error=" + root.backend.fetchError + "; loading=" + root.backend.loading + "; request=" + JSON.stringify(root.backend.payload.testRequest)); Qt.quit() } }
}
