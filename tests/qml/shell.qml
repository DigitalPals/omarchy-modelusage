import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("MODEL_USAGE_TEST_RESULT")
  readonly property string panelUrl: Quickshell.env("MODEL_USAGE_PANEL_URL")
  readonly property string meterUrl: Quickshell.env("MODEL_USAGE_METER_URL")
  readonly property string backendUrl: Quickshell.env("MODEL_USAGE_BACKEND_URL")
  readonly property string costBackendUrl: Quickshell.env("MODEL_USAGE_COST_BACKEND_URL")
  readonly property string costViewUrl: Quickshell.env("MODEL_USAGE_COST_VIEW_URL")
  readonly property bool screenshotMode: Quickshell.env("MODEL_USAGE_SCREENSHOT_MODE") === "1"
  property var failures: []
  property var objects: []
  property var widget: null
  property var malformedBackend: null
  property var proxyBackend: null
  property var proxyWidget: null
  property var richCostBackend: null
  property var malformedCostBackend: null
  property var backendErrorCostBackend: null
  property var costView: null
  property int waitAttempts: 0
  property int lastGoodWaitAttempts: 0
  readonly property var panelPositions: Quickshell.env("MODEL_USAGE_TEST_ALL_EDGES") === "1"
    ? ["top", "bottom", "left", "right"] : ["top"]
  property int panelPositionIndex: 0
  property bool settingsPanelChecks: false

  function fail(message) { failures.push(String(message)) }
  function assertTrue(condition, message) { if (!condition) fail(message) }
  function assertEqual(actual, expected, message) {
    if (actual !== expected) fail(message + " expected=" + expected + " actual=" + actual)
  }
  function finite(value) { return isFinite(Number(value)) && Number(value) >= 0 }

  function namedChild(item, name) {
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = namedChild(children[i], name)
      if (found) return found
    }
    return null
  }

  function positiveChartSegments(item) {
    if (!item) return 0
    var count = 0
    try {
      if (Number(item.amount) > 0 && Number(item.height) > 0) count++
    } catch (error) {}
    var descendants = item.children || []
    for (var index = 0; index < descendants.length; index++)
      count += positiveChartSegments(descendants[index])
    return count
  }

  function loadComponent(url, properties, label) {
    var component = Qt.createComponent(url, Component.PreferSynchronous)
    if (component.status !== Component.Ready) {
      fail(label + " failed to load: " + component.errorString())
      return null
    }
    var object = component.createObject(host, properties || {})
    if (!object) {
      fail(label + " failed to instantiate: " + component.errorString())
      return null
    }
    objects.push(object)
    return object
  }

  function checkSettings() {
    var original = JSON.parse(JSON.stringify(widget.settings))
    widget.settings = Object.assign({}, original, { unrelatedPreference: "keep" })
    widget.showSettings()
    assertTrue(widget.configuring, "settings opens from the panel")
    var form = widget.settingsForm
    form.toggleProvider("barProviders", "codex")
    form.setValue("hideAccountEmails", true)
    assertTrue(!widget.hideAccountEmails, "draft privacy change waits for Save")
    assertEqual(widget.percentageProviders.length, 3, "draft edits do not change the live bar")
    form.cancelRequested()
    assertEqual(widget.viewMode, "limits", "Cancel returns to Limits")
    widget.showSettings()
    assertEqual(form.draft.barProviders.length, 3, "Cancel discards draft edits")
    assertEqual(form.draft.hideAccountEmails, false, "Cancel discards privacy edits")

    form.setValue("usageSource", "cliproxy")
    assertTrue(form.proxyMode, "proxy source reveals connection fields")
    form.setValue("cliproxyUrl", "https://user:secret@proxy.test")
    assertTrue(!form.submit(), "URL credentials cannot be saved")
    form.setValue("cliproxyUrl", "https://proxy.test/prefix/management.html")
    form.managementKey = "invalid\nkey"
    assertTrue(!form.submit(), "multiline management keys cannot be saved")
    form.managementKey = "synthetic-secret"
    form.setValue("refreshIntervalSec", "")
    assertTrue(!form.submit(), "empty numeric input cannot be saved")
    form.setValue("refreshIntervalSec", "900")
    form.setValue("criticalThreshold", "80")
    assertTrue(!form.submit(), "inverted thresholds cannot be saved")
    assertEqual(mockShell.saveCount, 0, "invalid and cancelled edits never reach persistence")
    form.cancelRequested()
    assertEqual(form.managementKey, "", "Cancel clears the entered key")

    widget.showSettings()
    form.toggleProvider("barProviders", "codex")
    mockShell.rejectSave = true
    form.setValue("hideAccountEmails", true)
    form.submit()
    assertTrue(widget.configuring, "failed persistence keeps the form open")
    assertTrue(form.errorText !== "", "failed persistence is explained")
    assertEqual(widget.percentageProviders.length, 3, "failed persistence does not change live settings")
    mockShell.rejectSave = false
    form.submit()
    assertTrue(!widget.configuring, "Save returns to the previous view")
    assertTrue(widget.hideAccountEmails, "saving privacy setting updates the view")
    assertEqual(mockShell.savedSettings.hideAccountEmails, true, "privacy preference is persisted")
    assertEqual(mockShell.savedId, widget.moduleName, "settings are saved to this widget only")
    assertEqual(mockShell.savedSettings.unrelatedPreference, "keep", "Save preserves unrelated settings")
    assertEqual(mockShell.savedSettings.barProviders.join(","), "claude,kimi", "bar selection is persisted")
    assertEqual(widget.percentageProviders.length, 2, "hidden provider leaves the bar immediately")
    assertEqual(widget.providers.length, 3, "hiding from the bar retains all popup providers")
    widget.settings = JSON.parse(JSON.stringify(mockShell.savedSettings))
    widget.showSettings()
    assertEqual(form.draft.barProviders.join(","), "claude,kimi", "reopening reads persisted selection")
    form.setValue("barProviders", [])
    form.submit()
    assertTrue(!widget.percentageMode, "hiding every chip retains the widget icon")

    widget.showSettings()
    form.setValue("enabledProviders", [])
    form.submit()
    assertEqual(widget.providers.length, 0, "disabling monitoring removes popup providers immediately")
    widget.showSettings()
    assertTrue(widget.configuring, "settings remains accessible with no providers")
    form.cancelRequested()
    widget.settings = original
    widget.showCosts()
    widget.showSettings()
    form.cancelRequested()
    assertEqual(widget.viewMode, "costs", "Cancel restores the Costs view")
    widget.showLimits()
    widget.close()
  }

  function setup() {
    widget = loadComponent(panelUrl, {
      moduleName: "digitalpals.model-usage",
      bar: fakeBar,
      settings: {
        enabledProviders: ["claude", "codex", "kimi"],
        hideAccountEmails: false,
        refreshIntervalSec: 3600,
        barDisplayMode: "Percentages",
        warningThreshold: 25,
        criticalThreshold: 10
      }
    }, "Panel.qml")
    malformedBackend = loadComponent(backendUrl, {
      settings: { enabledProviders: ["kimi"], refreshIntervalSec: 3600 }
    }, "UsageBackend.qml malformed boundary")
    proxyBackend = loadComponent(backendUrl, {
      settings: { enabledProviders: ["claude", "codex"], usageSource: "cliproxy",
        cliproxyUrl: "https://proxy.test/prefix", cliproxyKeyFile: "/private/proxy key" }
    }, "UsageBackend.qml CLIProxyAPI settings")
    proxyWidget = loadComponent(panelUrl, {
      moduleName: "test.proxy-widget", ipcTarget: "test.proxy-widget", bar: fakeBar,
      settings: { enabledProviders: [], usageSource: "cliproxy",
        cliproxyUrl: "https://proxy.test/prefix", cliproxyKeyFile: "/private/proxy key" }
    }, "Panel.qml proxy discovery")
    if (malformedBackend) {
      malformedBackend.settings = { enabledProviders: ["kimi"], refreshIntervalSec: 3600 }
      malformedBackend.refresh()
    }
    richCostBackend = loadComponent(costBackendUrl, {
      settings: { enabledProviders: ["claude", "codex", "kimi"] },
      periodDays: 30
    }, "CostBackend.qml rich contract")
    if (richCostBackend) richCostBackend.refresh()
    malformedCostBackend = loadComponent(costBackendUrl, {
      settings: { enabledProviders: ["kimi"] },
      periodDays: 30
    }, "CostBackend.qml malformed boundary")
    if (malformedCostBackend) {
      malformedCostBackend.settings = { enabledProviders: ["kimi"] }
      malformedCostBackend.refresh()
    }
    backendErrorCostBackend = loadComponent(costBackendUrl, {
      settings: { enabledProviders: ["claude", "codex", "kimi"] },
      periodDays: 30
    }, "CostBackend.qml last-known-good boundary")
    if (backendErrorCostBackend) backendErrorCostBackend.refresh()
    waitForBackend.running = true
  }

  function runChecks() {
    if (proxyBackend) {
      assertEqual(proxyBackend.fetchError, "", "CLIProxyAPI settings reach the backend")
      assertEqual(proxyBackend.providers.length, 4, "CLIProxyAPI discovers all providers independent of local filters")
      if (proxyBackend.providers.length > 0) {
        assertEqual(proxyBackend.providers[0].source, "CLIProxyAPI management API", "proxy source is retained")
        assertEqual(proxyBackend.providers[0].availableCount, 2, "proxy account coverage is retained")
      }
    }
    if (proxyWidget) {
      assertEqual(proxyWidget.providers.length, 4, "proxy popup includes newly discovered providers with no local selection")
      proxyWidget.selectProviderId("codex")
      assertEqual(proxyWidget.proxyAccounts.length, 3, "all three Codex subscriptions are available together")
      assertEqual(proxyWidget.accountCards.count, 3, "three separate Codex account cards are rendered")
      assertTrue(proxyWidget.accountOverview, "proxy defaults to account overview")
      assertTrue(!proxyWidget.expandedAccountLimits, "weekly limits are the default")
      var cards = []
      for (var i = 0; i < proxyWidget.accountCards.count; i++)
        cards.push(proxyWidget.accountCards.itemAt(i))
      assertEqual(cards.length, 3, "three account delegates exist in the panel")
      for (var i = 0; i < cards.length; i++) {
        assertEqual(cards[i].windows.length, 1, "each account initially shows only its weekly quota")
        assertEqual(cards[i].windows[0].id, "codex-secondary", "main weekly quota wins over scoped and session windows")
        assertEqual(cards[i].windows[0].remaining, [20, 55, 90][i], "account quotas are kept separate")
        var badge = namedChild(cards[i], "accountResetBadge")
        var label = namedChild(cards[i], "accountResetLabel")
        assertTrue(badge !== null && badge.width > 0 && badge.height > 0, "reset badge has a visible size")
        assertEqual(label ? label.text : "", i + " banked reset" + (i === 1 ? "" : "s"), "each account shows its own banked resets including zero")
      }
      proxyWidget.expandedAccountLimits = true
      if (cards.length > 0) assertEqual(cards[0].windows.length, 4, "additional limits can be expanded")
      proxyWidget.selectProviderId("gemini")
      assertTrue(!proxyWidget.expandedAccountLimits, "provider navigation restores the compact view")
      assertEqual(proxyWidget.provider.status, "unsupported", "unsupported quota is not shown as zero")
      assertEqual(proxyWidget.viewOptions.length, 2, "proxy shows Limits and Costs only")
      assertTrue(proxyWidget.hideAccountEmails, "account emails are hidden by default")
      assertEqual(proxyWidget.accountDisplayName({account: "secret@example.invalid"}, 2), "Account 2", "hidden label contains no account identity")
      assertTrue(proxyWidget.accountTooltip({account: "secret@example.invalid"}).indexOf("secret") < 0, "settings cannot reveal hidden account identity")
      proxyWidget.settings = Object.assign({}, proxyWidget.settings, {hideAccountEmails: false})
      assertEqual(proxyWidget.accountDisplayName({account: "secret@example.invalid"}, 2), "secret@example.invalid", "privacy setting can reveal account labels")
    }
    if (widget) {
      assertEqual(widget.moduleName, "digitalpals.model-usage", "moduleName injection")
      assertEqual(widget.ipcTarget, "digitalpals.model-usage", "IPC target")
      assertEqual(widget.setting("missing", "fallback"), "fallback", "setting fallback")
      assertTrue(finite(widget.implicitWidth), "horizontal implicitWidth is finite")
      assertTrue(finite(widget.implicitHeight), "horizontal implicitHeight is finite")
      assertEqual(widget.providers.length, 3, "all normalized providers render")
      assertEqual(widget.provider.id, "claude", "first provider is selected")
      assertEqual(widget.provider.windows.length, 3, "arbitrary Claude windows render")
      assertEqual(widget.heroMeta(widget.provider), "Claude Max 20x",
        "hero keeps the subscription type visible")
      assertTrue(widget.heroMeta(widget.provider).indexOf("fixture@example.invalid") < 0,
        "hero hides account identity")
      assertTrue(widget.accountTooltip(widget.provider).indexOf("Account: fixture@example.invalid") >= 0,
        "account identity is available in settings")
      assertTrue(widget.accountTooltip(widget.provider).indexOf("Source: Claude OAuth usage API") >= 0,
        "account source is available in settings")
      assertEqual(widget.percentageMode, true, "percentages show with meaningful horizontal data")
      assertEqual(widget.percentageProviders.length, 3, "compact mode includes every meaningful provider")
      assertTrue(widget.alarming, "critical provider activates urgent state")
      widget.nextProvider()
      assertEqual(widget.provider.id, "codex", "next selects Codex")
      assertEqual(widget.provider.windows.length, 4, "additional Codex windows render")
      assertTrue(widget.provider.credits !== null, "Codex credits render")
      widget.nextProvider()
      assertEqual(widget.provider.id, "kimi", "next selects Kimi")
      assertTrue(widget.provider.credits !== null, "Kimi extra usage renders")
      widget.handleProviderChipPress("codex", Qt.LeftButton)
      assertEqual(widget.provider.id, "codex", "provider chip opens its provider directly")
      assertTrue(widget.opened, "provider chip opens the panel")
      widget.handleProviderTabHover(true)
      assertEqual(widget.provider.id, "codex", "popup hover cannot replace the provider selected by the bar chip")
      widget.handleProviderChipPress("codex", Qt.LeftButton)
      assertTrue(!widget.opened, "selected provider chip toggles the panel closed")
      assertEqual(widget.windowSeverity({ remaining: 9 }), "critical", "critical quota state")
      assertEqual(widget.windowSeverity({ remaining: 20 }), "warning", "warning quota state")
      assertTrue(widget.errorBody({ message: "Expired", errorKind: "expired", authCommand: "kimi login" }).indexOf("kimi login") >= 0,
        "auth command is shown for expired credentials")
      assertEqual(widget.errorBody({ message: "Sign in through CLIProxyAPI.", errorKind: "expired", authCommand: "" }),
        "Sign in through CLIProxyAPI.", "managed credentials do not suggest local CLI login")
      widget.showCosts()
      assertEqual(widget.viewMode, "costs", "Costs IPC/view helper selects the isolated tab")
      widget.showLimits()
      assertEqual(widget.viewMode, "limits", "Limits IPC/view helper restores quota view")
      widget.close()

      checkSettings()

      var positions = ["top", "bottom", "left", "right"]
      for (var i = 0; i < positions.length; i++) {
        fakeBar.position = positions[i]
        fakeBar.vertical = positions[i] === "left" || positions[i] === "right"
        assertTrue(finite(widget.implicitWidth), positions[i] + " implicitWidth is finite")
        assertTrue(finite(widget.implicitHeight), positions[i] + " implicitHeight is finite")
        if (fakeBar.vertical) assertEqual(widget.percentageMode, false, positions[i] + " falls back to icon mode")
      }

      Color.foreground = "#171717"
      Color.background = "#fafafa"
      Color.accent = "#7c3aed"
      Color.urgent = "#dc2626"
      Style.fontBaseSize = 16
      Style.spacingScale = 1.35
      assertTrue(finite(widget.implicitWidth), "light/scaled theme implicitWidth is finite")
      Color.foreground = "#f4f4f5"
      Color.background = "#09090b"
      Color.accent = "#22d3ee"
      Style.fontBaseSize = 11
      Style.spacingScale = 0.85
      assertTrue(finite(widget.implicitHeight), "dark/compact theme implicitHeight is finite")
    }

    if (malformedBackend) {
      assertEqual(malformedBackend.providers.length, 0,
        "malformed backend data cannot replace the initial safe payload")
      assertTrue(malformedBackend.fetchError.indexOf("unreadable") >= 0,
        "malformed backend data gets a clean error")
    }

    if (richCostBackend) {
      assertEqual(richCostBackend.providers.length, 3, "cost backend exposes every selected provider")
      assertEqual(richCostBackend.payload.totals.costUsd, 12.34, "cost backend preserves estimated cost")
      assertEqual(richCostBackend.payload.providers[2].costUsd, null,
        "unpriced Kimi activity remains unknown rather than zero")
      assertTrue(richCostBackend.payload.periods.length > 0, "cost chart periods are available")
      costView = loadComponent(costViewUrl, {
        width: 420,
        periodDays: 30,
        metric: "cost"
      }, "UsageCosts.qml chart")
      if (costView)
        costView.payload = JSON.parse(JSON.stringify(richCostBackend.payload))
    }

    if (malformedCostBackend) {
      assertEqual(malformedCostBackend.providers.length, 0,
        "malformed cost data cannot replace the initial safe payload")
      assertTrue(malformedCostBackend.fetchError.indexOf("unreadable") >= 0,
        "malformed cost data gets a clean error")
    }

    if (backendErrorCostBackend) {
      assertEqual(backendErrorCostBackend.providers.length, 3,
        "last-known-good backend starts with a rich payload")
    }

    var meter = loadComponent(meterUrl, { width: 243, height: 10, value: 0.635 }, "BlockMeter.qml")
    if (meter) {
      assertTrue(meter.blockCount > 8, "meter renders fixed blocks")
      assertTrue(meter.completeBlocks > 0, "meter fills complete blocks")
      assertTrue(meter.boundaryFraction > 0 && meter.boundaryFraction < 1,
        "meter keeps a partially filled boundary block")
    }

    if (costView) costChartSettle.restart()
    else startLastGoodCheck()
  }

  function startLastGoodCheck() {
    if (!backendErrorCostBackend) {
      startPanelChecks()
      return
    }
    backendErrorCostBackend.settings = { enabledProviders: ["codex"] }
    lastGoodWaitAttempts = 0
    waitForLastGood.running = true
  }

  function startPanelChecks() {
    if (widget) {
      if (screenshotMode) widget.selectProviderId("claude")
      panelPositionIndex = 0
      mapPanelAtCurrentEdge()
    } else {
      writeResult()
    }
  }

  property var beforeKeySettings: ({})
  property int keySavePhase: 0
  function startKeySaveCheck() {
    beforeKeySettings = JSON.parse(JSON.stringify(widget.settings))
    widget.showSettings()
    widget.settingsForm.setValue("usageSource", "cliproxy")
    widget.settingsForm.managementKey = "qml-synthetic-management-key"
    widget.settingsForm.submit()
    keySavePhase = 0
    waitForKeySave.restart()
  }

  function writeResult() {
    writer.command = ["python3", "-c",
      "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2], encoding='utf-8')",
      resultPath, JSON.stringify({ ok: failures.length === 0, failures: failures })]
    writer.running = true
  }

  function mapPanelAtCurrentEdge() {
    var position = panelPositions[panelPositionIndex]
    fakeBar.position = position
    fakeBar.vertical = position === "left" || position === "right"
    if (settingsPanelChecks) widget.showSettings()
    else widget.open()
    assertTrue(widget.opened, position + " panel opens through the native controller")
    panelCloseTimer.restart()
  }

  PanelWindow {
    id: testBarWindow
    visible: true
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: fakeBar.vertical ? fakeBar.barSize : 1
    implicitHeight: fakeBar.vertical ? 1 : fakeBar.barSize
    anchors.top: fakeBar.position !== "bottom"
    anchors.bottom: fakeBar.position !== "top"
    anchors.left: fakeBar.position !== "right"
    anchors.right: fakeBar.position !== "left"
    mask: Region { width: 0; height: 0 }

    Item {
      id: host
      anchors.fill: parent
    }
  }

  QtObject {
    id: mockShell
    property var bar: fakeBar
    property var barConfig: ({ position: fakeBar.position })
    property var shellConfig: ({ version: 1, plugins: [], bar: { layout: { left: [], center: [], right: [] } } })
    function firstPartyServiceFor(id) { return null }
    function serviceFor(id) { return null }
    property bool rejectSave: false
    property int saveCount: 0
    property string savedId: ""
    property var savedSettings: ({})
    function updateEntryInline(moduleName, settings) {
      if (rejectSave) return false
      saveCount++
      savedId = moduleName
      savedSettings = JSON.parse(JSON.stringify(settings))
      return true
    }
  }

  QtObject {
    id: fakeBar
    property bool vertical: false
    property int barSize: 26
    property string position: "top"
    property string fontFamily: "monospace"
    property color foreground: "#f4f4f5"
    property color barForeground: foreground
    property color background: "#09090b"
    property color urgent: "#ef4444"
    property bool foregroundAnimationEnabled: false
    property var activePopout: null
    property var clickTargets: []
    property var shell: mockShell
    function run(command) {}
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { if (activePopout === owner) activePopout = null }
    function registerClickTarget(target) { clickTargets.push(target) }
    function unregisterClickTarget(target) {}
    function switchPanelFrom(owner, direction) { return false }
  }

  Process {
    id: writer
    running: false
    onExited: Qt.quit()
  }

  Timer {
    interval: 1
    running: true
    repeat: false
    onTriggered: root.setup()
  }

  Timer {
    id: waitForBackend
    interval: 25
    running: false
    repeat: true
    onTriggered: {
      root.waitAttempts++
      var richReady = root.widget && root.widget.providers.length === 3
      var malformedReady = root.malformedBackend && root.malformedBackend.fetchError !== ""
      var costReady = root.richCostBackend && root.richCostBackend.providers.length === 3
      var malformedCostReady = root.malformedCostBackend && root.malformedCostBackend.fetchError !== ""
      var lastGoodReady = root.backendErrorCostBackend && root.backendErrorCostBackend.providers.length === 3
      var proxyReady = root.proxyBackend && root.proxyBackend.providers.length === 4
        && root.proxyWidget && root.proxyWidget.providers.length === 4
      if ((richReady && malformedReady && costReady && malformedCostReady && lastGoodReady && proxyReady)
          || root.waitAttempts >= 120) {
        stop()
        root.runChecks()
      }
    }
  }

  Timer {
    id: costChartSettle
    interval: 25
    repeat: false
    onTriggered: {
      root.assertTrue(root.costView.chartMaximum > 0,
        "cost chart computes a positive scale from the fixture")
      root.assertTrue(root.positiveChartSegments(root.costView) > 0,
        "cost chart renders positive-height provider segments from nested period data")
      root.startLastGoodCheck()
    }
  }

  Timer {
    id: waitForLastGood
    interval: 25
    running: false
    repeat: true
    onTriggered: {
      root.lastGoodWaitAttempts++
      if ((root.backendErrorCostBackend
          && root.backendErrorCostBackend.fetchError === "Synthetic estimated-cost failure")
          || root.lastGoodWaitAttempts >= 120) {
        stop()
        root.assertEqual(root.backendErrorCostBackend.providers.length, 3,
          "backendError preserves the last-known-good cost payload")
        root.startKeySaveCheck()
      }
    }
  }

  Timer {
    id: waitForKeySave
    interval: 25
    repeat: true
    property int attempts: 0
    onTriggered: {
      attempts++
      if (root.widget.settingsForm.saving && attempts < 300) return
      stop()
      var form = root.widget.settingsForm
      if (root.keySavePhase === 0) {
        root.assertTrue(!root.widget.configuring, "key save completes and returns to usage: " + form.errorText)
        root.assertEqual(form.managementKey, "", "successful save clears the key field")
        root.assertTrue(String(mockShell.savedSettings.cliproxyKeyFile).indexOf("/management-keys/key-") > 0,
          "GUI key save persists a generated private file path")
        root.assertTrue(JSON.stringify(mockShell.savedSettings).indexOf("qml-synthetic-management-key") < 0,
          "management key never reaches widget settings")
        root.widget.showSettings()
        root.assertEqual(form.managementKey, "", "saved key is never loaded into the editor")
        var savedPath = root.widget.settings.cliproxyKeyFile
        form.submit()
        root.assertEqual(root.widget.settings.cliproxyKeyFile, savedPath, "blank key preserves saved credentials")
        root.widget.showSettings()
        form.managementKey = "replacement-that-must-be-rolled-back"
        mockShell.rejectSave = true
        form.submit()
        root.keySavePhase = 1
        attempts = 0
        restart()
      } else {
        root.assertTrue(root.widget.configuring && form.errorText !== "", "failed config save retains an error")
        mockShell.rejectSave = false
        form.cancelRequested()
        root.widget.settings = root.beforeKeySettings
        root.startPanelChecks()
      }
    }
  }

  Timer {
    id: panelCloseTimer
    interval: root.screenshotMode ? 600000 : 120
    repeat: false
    onTriggered: {
      root.widget.close()
      root.assertTrue(!root.widget.opened,
        root.panelPositions[root.panelPositionIndex] + " panel closes through the native controller")
      root.panelPositionIndex++
      if (root.panelPositionIndex < root.panelPositions.length) panelNextTimer.restart()
      else if (!root.settingsPanelChecks) {
        root.settingsPanelChecks = true
        root.panelPositionIndex = 0
        panelNextTimer.restart()
      } else root.writeResult()
    }
  }

  Timer {
    id: panelNextTimer
    interval: 180
    repeat: false
    onTriggered: root.mapPanelAtCurrentEdge()
  }

  Timer {
    interval: 250
    running: root.screenshotMode
    repeat: true
    onTriggered: {
      if (root.widget && !root.widget.opened) root.widget.open()
    }
  }

  Component.onDestruction: {
    for (var i = 0; i < objects.length; i++) {
      if (objects[i] && typeof objects[i].destroy === "function") objects[i].destroy()
    }
  }
}
