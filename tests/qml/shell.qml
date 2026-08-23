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
  property var richCostBackend: null
  property var malformedCostBackend: null
  property var backendErrorCostBackend: null
  property var costView: null
  property int waitAttempts: 0
  property int lastGoodWaitAttempts: 0
  property var panelPositions: ["top", "bottom", "left", "right"]
  property int panelPositionIndex: 0

  function fail(message) { failures.push(String(message)) }
  function assertTrue(condition, message) { if (!condition) fail(message) }
  function assertEqual(actual, expected, message) {
    if (actual !== expected) fail(message + " expected=" + expected + " actual=" + actual)
  }
  function finite(value) { return isFinite(Number(value)) && Number(value) >= 0 }

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

  function setup() {
    widget = loadComponent(panelUrl, {
      moduleName: "digitalpals.model-usage",
      bar: fakeBar,
      settings: {
        enabledProviders: ["claude", "codex", "kimi"],
        refreshIntervalSec: 3600,
        barDisplayMode: "Percentages",
        warningThreshold: 25,
        criticalThreshold: 10
      }
    }, "Panel.qml")
    malformedBackend = loadComponent(backendUrl, {
      settings: { enabledProviders: ["kimi"], refreshIntervalSec: 3600 }
    }, "UsageBackend.qml malformed boundary")
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
        "account identity is available from the help tooltip")
      assertTrue(widget.accountTooltip(widget.provider).indexOf("Source: Claude OAuth usage API") >= 0,
        "account source is available from the help tooltip")
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
      widget.showCosts()
      assertEqual(widget.viewMode, "costs", "Costs IPC/view helper selects the isolated tab")
      widget.showLimits()
      assertEqual(widget.viewMode, "limits", "Limits IPC/view helper restores quota view")
      widget.close()

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
    widget.open()
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
    function updateEntryInline(moduleName, settings) { return true }
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
      if ((richReady && malformedReady && costReady && malformedCostReady && lastGoodReady)
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
      else root.writeResult()
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
