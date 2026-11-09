import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

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
  function providerById(panel, id) {
    for (var i = 0; i < panel.providers.length; i++)
      if (panel.providers[i].id === id) return panel.providers[i]
    return null
  }
  function accountRowsOf(card) {
    var rows = []
    if (card) for (var i = 0; i < card.accountRows.count; i++) rows.push(card.accountRows.itemAt(i))
    return rows
  }

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
    assertEqual(form.refreshMinutes, "60", "refresh interval is presented in minutes")
    assertTrue(!form.alertsExpanded && !form.activityExpanded, "optional settings start collapsed")
    form.toggleProvider("barProviders", "codex")
    form.setValue("hideAccountEmails", true)
    assertTrue(!widget.hideAccountEmails, "draft privacy change waits for Save")
    assertEqual(widget.percentageProviders.length, 3, "draft edits do not change the live bar")
    form.cancelRequested()
    assertEqual(widget.viewMode, "limits", "Cancel returns to Limits")
    widget.showSettings()
    assertEqual(form.draft.barProviders.length, 3, "Cancel discards draft edits")
    assertEqual(form.draft.hideAccountEmails, false, "Cancel discards privacy edits")

    form.setValue("usageSource", "proxy")
    assertTrue(form.proxyMode, "proxy source reveals connection fields")
    form.setValue("proxyUrl", "https://user:secret@proxy.test")
    assertTrue(!form.submit(), "URL credentials cannot be saved")
    form.setValue("proxyUrl", "https://proxy.test/prefix/management.html")
    form.managementKey = "invalid\nkey"
    assertTrue(!form.submit(), "multiline management keys cannot be saved")
    form.managementKey = "synthetic-secret"
    form.setValue("refreshIntervalSec", "")
    assertTrue(!form.submit(), "empty numeric input cannot be saved")
    assertTrue(form.alertsExpanded, "invalid interval reveals the collapsed alert settings")
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
      settings: { costLocalProviders: ["claude", "codex", "kimi"] },
      periodDays: 30
    }, "CostBackend.qml rich contract")
    if (richCostBackend) richCostBackend.refresh()
    malformedCostBackend = loadComponent(costBackendUrl, {
      settings: { costLocalProviders: [] },
      periodDays: 30
    }, "CostBackend.qml malformed boundary")
    if (malformedCostBackend) {
      malformedCostBackend.settings = { costLocalProviders: [] }
      malformedCostBackend.refresh()
    }
    backendErrorCostBackend = loadComponent(costBackendUrl, {
      settings: { costLocalProviders: ["claude", "codex", "kimi"] },
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
      assertEqual(proxyWidget.providerCards.count, 4, "every provider has its own card, with no provider to select")
      var codexCard = proxyWidget.providerCard("codex")
      var cards = accountRowsOf(codexCard)
      assertEqual(cards.length, 3, "three Codex subscriptions get one row each")
      assertEqual(proxyWidget.contextText().split(" · ")[0], "7 accounts", "the account count covers every provider")
      assertEqual(proxyWidget.contextText().split(" · ")[1], "4 providers", "the provider count follows the accounts")
      assertEqual(codexCard ? codexCard.title : "", "Codex Pro · 20×", "a plan every account shares heads the card once")
      assertEqual(codexCard ? codexCard.caption : "", "weekly · resets", "the header names the column every row shows")
      assertTrue(!proxyWidget.expandedAccountLimits, "weekly limits are the default")
      assertTrue(proxyWidget.labelColumnWidth > 0, "rows report a shared name column")
      for (var i = 0; i < cards.length; i++) {
        assertEqual(cards[i].windows.length, 1, "each account initially shows only its weekly quota")
        assertEqual(cards[i].windows[0].id, "codex-secondary", "main weekly quota wins over scoped and session windows")
        assertEqual(cards[i].windows[0].remaining, [20, 55, 90][i], "account quotas are kept separate")
        assertEqual(cards[i].mainRow.window.id, "codex-secondary", "the row meter is the weekly allowance")
        assertEqual(cards[i].mainRow.labelWidth, proxyWidget.labelColumnWidth, "every row uses the shared name column")
        assertEqual(cards[i].rowWindows.extra.length, 0, "healthy shorter limits stay in the tooltip")
        assertEqual(namedChild(cards[i], "usageRowPercent").text, [20, 55, 90][i] + "%", "the row shows what is left")
        assertTrue(namedChild(cards[i], "usageRowReset").text.indexOf("d ") > 0, "the row shows the reset countdown")
        assertTrue(namedChild(cards[i], "usageRowDetail").visible === false, "details start hidden")
        var tip = cards[i].mainRow.tooltipText
        assertTrue(tip.indexOf("Account " + (i + 1) + " · Codex Pro · 20×") === 0, "the tooltip names the account and plan")
        assertTrue(tip.indexOf("Weekly limit: " + [20, 55, 90][i] + "% left") >= 0, "the tooltip lists the account's limits")
        assertTrue(tip.indexOf("5 hour limit: 99% left") >= 0, "the tooltip lists limits the row hides")
        assertTrue(tip.indexOf(i + " banked reset") >= 0, "the tooltip names the banked resets, including zero")
        assertTrue(tip.indexOf("@example.invalid") < 0, "hidden account emails stay out of tooltips")
        var badge = namedChild(cards[i], "accountResetBadge")
        var label = namedChild(cards[i], "accountResetLabel")
        assertTrue(badge !== null && badge.visible === (i > 0), "only accounts with banked resets show the reset button")
        if (i > 0) {
          assertTrue(badge.width > 0 && badge.height > 0, "reset button has a visible size")
          assertEqual(label ? label.text : "", String.fromCodePoint(0xF099B) + " " + i,
            "each account shows its own banked resets with the font's restore glyph")
          assertTrue(badge.mapToItem(cards[i], 0, 0).x > namedChild(cards[i], "usageRowReset").mapToItem(cards[i], 0, 0).x,
            "the reset button is the last column")
        }
        assertTrue(!cards[i].mainRow.wrapLabel, "account names stay on one line")
        assertEqual(namedChild(cards[i], "usageRowPercent").x, namedChild(cards[cards.length - 1], "usageRowPercent").x,
          "a row without banked resets keeps the percentage column aligned")
        assertTrue(!namedChild(cards[i], "accountSessionBadge").visible, "unknown session counts add nothing to the row")
      }
      assertTrue(cards.length > 0 && Qt.colorEqual(namedChild(cards[0], "usageRowPercent").color, proxyWidget.urgent),
        "a weekly allowance at the warning level is drawn urgent")
      assertTrue(proxyWidget.hasAdditionalLimits, "the account fixture has more limits to reveal")
      proxyWidget.expandedAccountLimits = true
      if (cards.length > 0) {
        assertEqual(cards[0].windows.length, 4, "Details reveals every limit")
        assertEqual(cards[0].rowWindows.extra.length, 3, "the other limits get indented rows")
        assertTrue(namedChild(cards[0], "usageRowDetail").visible, "Details shows the reset time inline")
      }
      proxyWidget.expandedAccountLimits = false
      var gemini = proxyWidget.providerCard("gemini")
      assertTrue(gemini !== null && gemini.provider.status === "unsupported", "unsupported quota keeps its own card")
      assertEqual(gemini ? namedChild(gemini, "providerCardNotice").text : "", "Quota lookup unavailable",
        "unsupported quota is explained, not shown as zero")
      assertEqual(proxyWidget.viewOptions.length, 2, "proxy shows Limits and Costs only")
      assertTrue(proxyWidget.hideAccountEmails, "account emails are hidden by default")
      assertEqual(proxyWidget.accountDisplayName({account: "secret@example.invalid"}, 2), "Account 2", "hidden label contains no account identity")
      assertTrue(proxyWidget.accountTooltip({account: "secret@example.invalid"}).indexOf("secret") < 0, "settings cannot reveal hidden account identity")
      proxyWidget.settings = Object.assign({}, proxyWidget.settings,
        {barDisplayMode: "Percentages", barProviders: ["codex"]})
      proxyWidget.accountActivity.legacyProviders = [{id: "codex", status: "ok", accountId: "0", lastUsedAt: 123}]
      var barLabel = namedChild(proxyWidget, "barAccountLabel")
      var barRemaining = namedChild(proxyWidget, "barAccountRemaining")
      assertTrue(barLabel === null, "bar contains no account name label")
      assertEqual(proxyWidget.lastAccount(providerById(proxyWidget, "codex")).label, "Account 1", "tooltip respects hidden account emails")
      assertEqual(barRemaining ? barRemaining.text : "", "20%", "bar quota belongs to last-used account")
      proxyWidget.accountActivity.legacyProviders = [{id: "codex", status: "ok", accountId: "1", lastUsedAt: 124}]
      assertEqual(proxyWidget.lastAccount(providerById(proxyWidget, "codex")).label, "Account 2", "tooltip follows account switches")
      assertEqual(barRemaining.text, "55%", "account switch updates quota together with label")
      proxyWidget.settings = Object.assign({}, proxyWidget.settings, {hideAccountEmails: false})
      assertEqual(proxyWidget.accountDisplayName({account: "secret@example.invalid"}, 2), "secret@example.invalid", "privacy setting can reveal account labels")
      assertEqual(proxyWidget.lastAccount(providerById(proxyWidget, "codex")).label, "codex-1@example.invalid", "tooltip reveals email only when requested")
      assertTrue(namedChild(proxyWidget, "barAccountLabel") === null, "emails stay out of the bar when privacy is disabled")
      proxyWidget.accountActivity.legacyProviders = []
      assertEqual(barRemaining.text, "9%", "missing activity still shows the known pool quota")
      assertTrue(barRemaining.parent.parent.tooltipText.indexOf("most remaining capacity") >= 0,
        "fallback tooltip identifies the pool quota rather than claiming a last-used account")
      proxyWidget.accountActivity.legacyProviders = [{id: "codex", status: "ambiguous", lastUsedAt: 125}]
      assertEqual(barRemaining.text, "9%", "ambiguous activity still shows the known pool quota")
      var freshPayload = proxyWidget.usageBackend.payload
      var stalePayload = JSON.parse(JSON.stringify(freshPayload))
      for (var p = 0; p < stalePayload.providers.length; p++) {
        if (stalePayload.providers[p].id !== "codex") continue
        stalePayload.providers[p].accounts[2].stale = true
        stalePayload.providers[p].accounts[2].notice = "Last known reading · Proxy offline"
      }
      proxyWidget.usageBackend.payload = stalePayload
      var staleRemaining = namedChild(proxyWidget, "barAccountRemaining")
      assertEqual(staleRemaining ? staleRemaining.text : "", "9%?", "a pool reading with a last-known account is marked")
      assertTrue(staleRemaining && staleRemaining.parent.parent.active, "a last-known reading activates its chip")
      assertTrue(staleRemaining && staleRemaining.parent.parent.tooltipText.indexOf("Proxy offline") >= 0,
        "the chip tooltip explains why the reading is last known")
      assertTrue(proxyWidget.alarming, "one last-known account makes the icon urgent")
      assertTrue(proxyWidget.footerLeft().indexOf("some readings are last known") >= 0, "the footer does not look fresh")
      var staleRows = accountRowsOf(proxyWidget.providerCard("codex"))
      assertEqual(staleRows.length === 3 ? namedChild(staleRows[2], "usageRowPercent").text : "", "90%?",
        "a last-known account row is marked like its chip")
      assertTrue(staleRows.length === 3 && staleRows[2].mainRow.tooltipText.indexOf("Proxy offline") >= 0,
        "the row tooltip explains the last-known reading")
      proxyWidget.usageBackend.payload = freshPayload
    }
    if (widget) {
      assertEqual(widget.moduleName, "digitalpals.model-usage", "moduleName injection")
      assertEqual(widget.ipcTarget, "digitalpals.model-usage", "IPC target")
      assertEqual(widget.setting("missing", "fallback"), "fallback", "setting fallback")
      assertTrue(finite(widget.implicitWidth), "horizontal implicitWidth is finite")
      assertTrue(finite(widget.implicitHeight), "horizontal implicitHeight is finite")
      assertEqual(widget.providers.length, 3, "all normalized providers render")
      assertEqual(widget.providerCards.count, 3, "every provider has its own card at once")
      var claude = providerById(widget, "claude")
      var claudeCard = widget.providerCard("claude")
      assertEqual(claudeCard ? claudeCard.windowRows.count : 0, 3, "arbitrary Claude windows render as rows")
      assertEqual(claudeCard ? claudeCard.title : "", "Claude Max 20x", "the card keeps the subscription type visible")
      assertEqual(claudeCard ? claudeCard.caption : "", "left · resets", "local rows label their own limits")
      assertEqual(widget.heroMeta(claude), "Claude Max 20x", "hero keeps the subscription type visible")
      assertTrue(widget.heroMeta(claude).indexOf("fixture@example.invalid") < 0, "hero hides account identity")
      assertTrue(widget.accountTooltip(claude).indexOf("Account: fixture@example.invalid") >= 0,
        "account identity is available in settings")
      assertTrue(widget.accountTooltip(claude).indexOf("Source: Claude OAuth usage API") >= 0,
        "account source is available in settings")
      assertTrue(widget.accountDiagnostics().indexOf("Claude Code\nAccount: fixture@example.invalid") === 0,
        "settings diagnostics name every provider")
      if (claudeCard) {
        var fable = claudeCard.windowRows.itemAt(2)
        assertTrue(fable.labelCellWidth <= Math.round(fable.width * 0.45), "a long limit name cannot squeeze the meter")
        assertEqual(namedChild(fable, "usageRowPercent").text, "9%", "the critical model limit shows what is left")
        assertTrue(fable.stressed, "a critical limit row uses the urgent color")
        assertTrue(fable.tooltipText.indexOf("Fable 1M — an intentionally long model label weekly: 9% left") === 0,
          "the tooltip carries the full limit name")
        assertTrue(namedChild(claudeCard, "providerCreditsRow").visible, "Claude extra usage renders")
      }
      assertEqual(widget.percentageMode, true, "percentages show with meaningful horizontal data")
      assertEqual(widget.percentageProviders.length, 3, "compact mode includes every meaningful provider")
      assertTrue(widget.alarming, "critical provider activates urgent state")
      var codexLocal = widget.providerCard("codex")
      assertEqual(codexLocal ? codexLocal.windowRows.count : 0, 4, "additional Codex windows render")
      assertTrue(codexLocal && namedChild(codexLocal, "providerCreditsRow").visible, "Codex credits render")
      if (codexLocal) {
        var dayLimit = namedChild(codexLocal.windowRows.itemAt(2), "usageRowLabel")
        var spendLimit = namedChild(codexLocal.windowRows.itemAt(3), "usageRowLabel")
        assertTrue(!dayLimit.truncated && !spendLimit.truncated && dayLimit.lineCount === 2,
          "similar long model limits wrap instead of losing the ending that tells them apart")
      }
      assertEqual(codexLocal ? namedChild(codexLocal, "providerCreditsRow").message : "", "17.50 credits remaining",
        "credits without a cap show their balance instead of a meter")
      var kimiCard = widget.providerCard("kimi")
      assertTrue(kimiCard && namedChild(kimiCard, "providerCreditsRow").visible, "Kimi extra usage renders")
      assertEqual(kimiCard ? namedChild(kimiCard, "providerCreditsRow").percentText : "", "75%",
        "a capped balance fills with what is left of the cap")
      assertEqual(widget.iconTooltip().split("\n").length, 4, "icon mode lists every provider")
      widget.handleProviderChipPress("codex", Qt.LeftButton)
      assertEqual(widget.focusedProviderId, "codex", "a provider chip jumps to its provider")
      assertTrue(widget.opened, "provider chip opens the panel")
      widget.handleProviderChipPress("codex", Qt.LeftButton)
      assertTrue(!widget.opened, "the same chip toggles the panel closed")
      widget.stepProvider(1)
      assertEqual(widget.focusedProviderId, "kimi", "→ jumps to the next provider")
      widget.stepProvider(1)
      assertEqual(widget.focusedProviderId, "claude", "→ wraps around")
      widget.viewMode = "limits"
      assertTrue(widget.historyAvailable, "the fixture has quota history")
      assertTrue(widget.historyView("claude") === null, "quota history starts collapsed")
      widget.toggleHistory("claude")
      var historyView = widget.historyView("claude")
      assertTrue(historyView !== null, "the history toggle opens the chart")
      if (historyView) {
        historyView.rangeRequested("d7")
        assertEqual(historyView.mode, "d7", "a range tab click updates the chart")
        widget.stepRange(-1)
        assertEqual(historyView.mode, "h24", "the keyboard range still drives the chart after a click")
      }
      widget.toggleHistory("claude")
      assertTrue(widget.historyView("claude") === null, "the chart collapses again")
      var limitKeys = widget.shortcutRows().map(function(row) { return row.action })
      assertTrue(limitKeys.indexOf("history range") >= 0 && limitKeys.indexOf("jump to provider") >= 0
        && limitKeys.indexOf("details") >= 0, "Limits legend lists its keys")
      widget.viewMode = "costs"
      var costKeys = widget.shortcutRows().map(function(row) { return row.action })
      assertTrue(costKeys.indexOf("jump to provider") < 0 && costKeys.indexOf("period") >= 0, "Costs legend lists only keys that work there")
      widget.viewMode = "limits"
      assertEqual(widget.windowSeverity({ remaining: 9 }), "critical", "critical quota state")
      assertEqual(widget.windowSeverity({ remaining: 20 }), "warning", "warning quota state")
      assertTrue(widget.errorBody({ message: "Expired", errorKind: "expired", authCommand: "kimi login" }).indexOf("kimi login") >= 0,
        "auth command is shown for expired credentials")
      assertEqual(widget.errorBody({ message: "Sign in through CLIProxyAPI.", errorKind: "expired", authCommand: "" }),
        "Sign in through CLIProxyAPI.", "managed credentials do not suggest local CLI login")
      widget.showCosts()
      assertEqual(widget.viewMode, "costs", "Costs IPC/view helper selects the isolated tab")
      widget.showCostSettings()
      assertEqual(widget.viewMode, "cost-settings", "navigation does not override cost settings")
      widget.leaveSettings()
      assertEqual(widget.viewMode, "costs", "leaving settings restores Costs")
      widget.showViewSettings()
      assertEqual(widget.viewMode, "cost-settings", "the settings key opens settings for the current view")
      widget.leaveSettings()
      assertEqual(widget.footerRight(), "", "Costs has no quota refresh countdown")
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

      Commons.Color.foreground = "#171717"
      Commons.Color.background = "#fafafa"
      Commons.Color.accent = "#7c3aed"
      Commons.Color.urgent = "#dc2626"
      Style.fontBaseSize = 16
      Style.spacingScale = 1.35
      assertTrue(finite(widget.implicitWidth), "light/scaled theme implicitWidth is finite")
      Commons.Color.foreground = "#f4f4f5"
      Commons.Color.background = "#09090b"
      Commons.Color.accent = "#22d3ee"
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
      assertEqual(richCostBackend.providers.length, 2, "cost backend exposes every selected provider")
      assertEqual(richCostBackend.payload.totals.costUsd, 12.34, "cost backend preserves estimated cost")
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
      assertEqual(backendErrorCostBackend.providers.length, 2,
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
    backendErrorCostBackend.settings = { costLocalProviders: ["claude", "codex"], costPriceOverrides: "synthetic-failure" }
    lastGoodWaitAttempts = 0
    waitForLastGood.running = true
  }

  function startPanelChecks() {
    if (widget) {
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
    widget.settingsForm.setValue("usageSource", "proxy")
    widget.settingsForm.managementKey = "qml-synthetic-management-key"
    widget.settingsForm.setValue("keeperUrl", "https://keeper.example/keeper")
    widget.settingsForm.keeperPassword = "qml-synthetic-keeper-password"
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
      var costReady = root.richCostBackend && root.richCostBackend.providers.length === 2
      var malformedCostReady = root.malformedCostBackend && root.malformedCostBackend.fetchError !== ""
      var lastGoodReady = root.backendErrorCostBackend && root.backendErrorCostBackend.providers.length === 2
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
        root.assertEqual(root.backendErrorCostBackend.providers.length, 2,
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
        root.assertEqual(form.keeperPassword, "", "successful save clears the Keeper password field")
        root.assertTrue(String(mockShell.savedSettings.proxyKeyFile).indexOf("/management-keys/key-") > 0,
          "GUI key save persists a generated private file path")
        root.assertTrue(mockShell.savedSettings.cliproxyKeyFile === undefined
          && mockShell.savedSettings.cliproxyUrl === undefined
          && mockShell.savedSettings.usageSource === "proxy",
          "saving migrates renamed connection settings")
        root.assertTrue(JSON.stringify(mockShell.savedSettings).indexOf("qml-synthetic-management-key") < 0,
          "management key never reaches widget settings")
        root.assertTrue(JSON.stringify(mockShell.savedSettings).indexOf("qml-synthetic-keeper-password") < 0,
          "Keeper password never reaches widget settings")
        root.assertTrue(String(mockShell.savedSettings.keeperPasswordFile).indexOf("/management-keys/key-") > 0,
          "Keeper password persists only as a private file path")
        root.widget.showSettings()
        root.assertEqual(form.managementKey, "", "saved key is never loaded into the editor")
        root.assertTrue(!form.connectionExpanded, "saved proxy connection starts collapsed")
        var savedPath = root.widget.settings.proxyKeyFile
        form.submit()
        root.assertEqual(root.widget.settings.proxyKeyFile, savedPath, "blank key preserves saved credentials")
        root.widget.showSettings()
        form.managementKey = "replacement-that-must-be-rolled-back"
        form.keeperPassword = "keeper-replacement-that-must-be-rolled-back"
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
      } else {
        root.widget.showCostSettings()
        root.widget.costSettingsForm.priceEditor.begin("{}")
        for (var i = 0; i < 16; i++) root.widget.costSettingsForm.priceEditor.addPrice()
        settingsScrollCheck.restart()
      }
    }
  }

  Timer {
    id: settingsScrollCheck
    interval: 250
    onTriggered: {
      var editor = root.widget.costSettingsForm.priceEditor
      var field = editor.findItem(editor, "costModel-15")
      var flick = field
      while (flick && flick.contentY === undefined) flick = flick.parent
      root.assertTrue(!!flick, "settings editor is in a scrollable view")
      if (flick) {
        var point = field.mapToItem(flick, 0, 0)
        root.assertTrue(flick.contentY > 0, "adding a price scrolls a long form")
        root.assertTrue(point.y >= 0 && point.y + field.height <= flick.height,
          "new price field is fully visible above the fixed settings footer")
      }
      root.widget.costSettingsForm.cancelRequested()
      root.widget.close()
      root.writeResult()
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
