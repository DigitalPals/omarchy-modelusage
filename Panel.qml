pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Ui.Panel {
  id: root
  moduleName: "digitalpals.model-usage"
  ipcTarget: "digitalpals.model-usage"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: UsageLogic.dimColor(foreground)
  readonly property color surface: Commons.Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool proxyMode: backend.usageSource === "proxy"
  readonly property var providers: UsageLogic.availableProviders(proxyMode
    ? backend.providers : UsageLogic.selectedProviders(backend.providers, backend.enabledProviderIds))
  // The provider card the bar chip or ←/→ last jumped to; Limits shows all.
  property string focusedProviderId: ""
  // Details: every limit and account fact inline, not only in tooltips.
  property bool expandedAccountLimits: false
  // Quota history chart per local provider, collapsed by default.
  property var historyOpen: ({})
  property bool shortcutsVisible: false
  // Reset time already refreshed for, so a passed reset triggers one refresh.
  property double refreshedForResetAt: 0
  property string historyMode: "h24"
  property string viewMode: "limits"
  property string settingsReturnView: "limits"
  readonly property bool configuring: viewMode === "settings"
  property alias settingsView: settingsViewItem
  readonly property var settingsForm: settingsViewItem.limitsForm
  readonly property var costSettingsForm: settingsViewItem.costForm
  property alias resetAction: resetBackend
  property double nowMs: Date.now()
  // Account facts show minutes; change once a minute rather than every tick.
  readonly property double minuteMs: Math.floor(nowMs / 60000) * 60000

  readonly property var viewOptions: [
    { value: "limits", label: "Limits" },
    { value: "costs", label: "Costs" }
  ]
  readonly property bool hideAccountEmails: setting("hideAccountEmails", true) !== false
  readonly property real usageCardRadius: setting("squareUsageCards", true) === true ? 0 : Style.cornerRadius

  function accountDisplayName(account, index) {
    return UsageLogic.accountDisplayName(account, index, hideAccountEmails)
  }

  readonly property int criticalThreshold: UsageLogic.clamp(
    setting("criticalThreshold", 10), 0, 100)
  readonly property int warningThreshold: Math.max(criticalThreshold, UsageLogic.clamp(
    setting("warningThreshold", 25), 0, 100))
  readonly property string displayMode: String(setting("barDisplayMode", "Percentages"))
  readonly property var percentageProviders: UsageLogic.barProviders(
    UsageLogic.selectedProviders(providers, setting("barProviders", ["claude", "codex", "kimi"])))
  property alias accountActivity: activityBackend
  readonly property bool percentageMode: displayMode === "Percentages"
    && !(bar && bar.vertical) && percentageProviders.length > 0
  readonly property bool alarming: anyProviderAlarming()
  readonly property int focusedIndex: {
    for (let i = 0; i < providers.length; i++)
      if (providers[i].id === focusedProviderId) return i
    return -1
  }
  readonly property bool historyAvailable: {
    for (let i = 0; i < providers.length; i++)
      if (UsageLogic.hasQuotaHistory(providers[i])) return true
    return false
  }
  readonly property bool hasAdditionalLimits: {
    for (let i = 0; i < providers.length; i++)
      if (UsageLogic.hasAdditionalWindows(providers[i].accounts, warningThreshold, criticalThreshold)) return true
    return false
  }
  // Details adds reset times, account facts and every other limit inline.
  readonly property bool detailsAvailable: providers.length > 0
  // Every card's name column is as wide as the widest name, so meters line up.
  readonly property real labelColumnWidth: Math.ceil(labelRegistry.widest)
  readonly property bool bankedResetColumn: UsageLogic.hasBankedResets(providers)
  property alias providerCards: providerRepeater
  property alias usageBackend: backend

  function alpha(color, opacity) {
    return UsageLogic.alpha(color, opacity)
  }

  function clamp(value, low, high) { return UsageLogic.clamp(value, low, high) }

  function anyProviderAlarming() {
    for (let i = 0; i < providers.length; i++) {
      let severity = UsageLogic.severity(providers[i], warningThreshold, criticalThreshold)
      if (severity === "warning" || severity === "critical" || severity === "error") return true
      // A last-known reading, for the provider or any account, is not current.
      if (UsageLogic.hasStaleReading(providers[i])) return true
    }
    return false
  }

  function providerCard(providerId) {
    for (let i = 0; i < providerRepeater.count; i++) {
      const card = providerRepeater.itemAt(i)
      if (card && card.providerId === providerId) return card
    }
    return null
  }

  // Scroll so the provider's card starts at the top of the panel.
  function scrollToProvider(providerId) {
    const card = providerCard(providerId)
    if (!card || !panelFlick) return false
    const point = card.mapToItem(panelFlick.contentItem, 0, 0)
    panelFlick.contentY = clamp(point.y - Style.spacing.sm, 0,
      Math.max(0, panelFlick.contentHeight - panelFlick.height))
    return true
  }

  // A bar chip or ←/→ jumps to a provider. The panel lays out its cards after
  // opening, so the scroll waits for them.
  function focusProvider(providerId) {
    focusedProviderId = String(providerId)
    if (viewMode === "limits") scrollTimer.begin()
  }

  function stepProvider(direction) {
    if (providers.length === 0) return
    const start = focusedIndex < 0 ? (direction > 0 ? -1 : 0) : focusedIndex
    const wrapped = ((start + direction) % providers.length + providers.length) % providers.length
    focusProvider(providers[wrapped].id)
  }

  // Middle click and IPC `next`: open Limits at the next provider's card.
  function nextProvider() {
    if (!opened || viewMode !== "limits") {
      viewMode = "limits"
      open()
    }
    stepProvider(1)
  }

  function toggleHistory(providerId) {
    const next = Object.assign({}, historyOpen)
    next[providerId] = !next[providerId]
    historyOpen = next
  }

  function historyView(providerId) {
    const card = providerCard(providerId)
    return card ? card.historyView : null
  }

  function refreshNow() {
    if (viewMode === "costs") costBackend.refresh()
    else backend.refresh()
  }

  function showLimits() {
    viewMode = "limits"
    open()
  }

  function showCosts() {
    viewMode = "costs"
    costBackend.ensureLoaded()
    open()
  }

  // Settings at the current view's tab, like the gear button.
  function showViewSettings() {
    if (viewMode === "costs") showCostSettings()
    else showSettings()
  }

  // Step the period in Costs or the history range in Limits.
  function stepRange(direction) {
    if (viewMode === "costs") {
      const periods = [1, 7, 30]
      const index = Math.max(0, periods.indexOf(costBackend.periodDays))
      costBackend.selectPeriod(periods[clamp(index + direction, 0, periods.length - 1)])
    } else if (viewMode === "limits" && historyAvailable) {
      historyMode = direction > 0 ? "d7" : "h24"
    }
  }

  // A reset that passed since the last reading refreshes once, instead of
  // leaving an old meter under "Reset due".
  function refreshPassedReset() {
    if (backend.loading || backend.lastSuccessAt <= 0) return
    const passed = UsageLogic.passedResetAt(providers, backend.lastSuccessAt, nowMs)
    if (passed > refreshedForResetAt) {
      refreshedForResetAt = passed
      backend.refresh()
    }
  }

  // Only keys that do something in the current view.
  function shortcutRows() {
    const rows = [{ key: viewMode === "costs" ? "u" : "c", action: viewMode === "costs" ? "Limits" : "Costs" }]
    if (viewMode === "limits" && providers.length > 1)
      rows.push({ key: "←/→ h/l", action: "jump to provider" })
    if (viewMode === "costs") rows.push({ key: "[ ]", action: "period" })
    else if (historyAvailable) rows.push({ key: "[ ]", action: "history range" })
    if (viewMode === "limits" && (detailsAvailable || expandedAccountLimits))
      rows.push({ key: "a", action: "details" })
    if (viewMode === "costs")
      rows.push({ key: "m", action: "metric" }, { key: "d", action: "token details" }, { key: "b", action: "models" })
    rows.push({ key: "r", action: "refresh" }, { key: "s", action: "settings" }, { key: "↑/↓ j/k", action: "scroll" },
      { key: "Tab", action: "next panel" }, { key: "Esc", action: "close" }, { key: "?", action: "hide keys" })
    return rows
  }

  // One settings page with a Limits and a Costs tab.
  function showSettings(tab) {
    if (!configuring) settingsReturnView = viewMode
    settingsViewItem.begin(settings, tab === "costs" ? "costs" : "limits")
    viewMode = "settings"
    if (panelFlick) panelFlick.contentY = 0
    open()
    Qt.callLater(function() { settingsViewItem.focusFirst() })
  }

  function showCostSettings() {
    showSettings("costs")
    settingsReturnView = "costs"
  }

  function leaveSettings() {
    settingsViewItem.discardKey()
    viewMode = settingsReturnView
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function saveSettings(values) {
    // Saving also moves renamed connection settings to their current keys.
    var entry = UsageLogic.migrateSettings(Object.assign({}, settings, values))
    var changed = false
    var keys = Object.keys(entry).concat(Object.keys(settings || {}))
    for (let i = 0; i < keys.length; i++) {
      if (JSON.stringify(settings[keys[i]]) !== JSON.stringify(entry[keys[i]])) changed = true
    }
    if (changed) {
      if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function"
          || !bar.shell.updateEntryInline(moduleName, entry)) {
        settingsViewItem.transactionError = "Could not save settings. Make sure Model Usage is enabled in the bar, then try again."
        settingsViewItem.finishSave(false)
        return false
      }
      settings = entry
    }
    settingsViewItem.finishSave(true)
    leaveSettings()
    return true
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.MiddleButton) nextProvider()
    else if (buttonCode === Qt.LeftButton) toggle()
  }

  // A chip opens Limits at its provider's card; clicking it again closes.
  function handleProviderChipPress(providerId, buttonCode) {
    if (buttonCode === Qt.MiddleButton) {
      nextProvider()
      return
    }
    if (buttonCode !== Qt.LeftButton) return
    var sameProvider = opened && viewMode === "limits" && focusedProviderId === String(providerId)
    if (sameProvider) {
      close()
      return
    }
    viewMode = "limits"
    open()
    focusProvider(providerId)
  }

  function windowSeverity(window) {
    return UsageLogic.windowSeverity(window, warningThreshold, criticalThreshold)
  }

  function heroMeta(provider) {
    return provider && provider.plan ? String(provider.plan) : ""
  }

  function accountTooltip(provider) {
    if (!provider) return ""
    var lines = []
    if (!hideAccountEmails && provider.account) lines.push("Account: " + String(provider.account))
    if (provider.source) lines.push("Source: " + String(provider.source))
    return lines.join("\n")
  }

  // Settings diagnostics: the account and source of every provider shown.
  function accountDiagnostics() {
    var blocks = []
    for (let i = 0; i < providers.length; i++) {
      const details = accountTooltip(providers[i])
      if (details !== "") blocks.push(String(providers[i].name || providers[i].id) + "\n" + details)
    }
    return blocks.join("\n")
  }

  // Icon mode: one line per provider, as the chips would show it.
  function iconTooltip() {
    if (providers.length === 0) return "Model usage"
    var lines = ["Model usage"]
    for (let i = 0; i < providers.length; i++) {
      const provider = providers[i]
      const last = proxyMode ? lastAccount(provider) : null
      const reading = last && last.reading ? last.reading : provider
      const remaining = UsageLogic.minRemaining(reading)
      lines.push(String(provider.name || provider.id) + " · "
        + (remaining !== null ? Math.round(remaining) + "% left"
          : provider.status === "error" ? "unavailable" : "no reading")
        + (last ? " · last used " + last.label : ""))
    }
    return lines.join("\n")
  }

  function lastAccount(provider) {
    return UsageLogic.lastUsedAccount(provider, activityBackend.providers, hideAccountEmails)
  }

  function lastAccountTooltip(account) {
    var text = "Last used: " + account.label
    if (account.lastUsedAt > 0)
      text += " · " + Qt.formatDateTime(new Date(account.lastUsedAt * 1000), "MMM d, HH:mm:ss")
    if (activityBackend.notice !== "") text += "\n" + activityBackend.notice
    else if (!account.reading) text += "\nNo unique last-used account is available in recorded requests."
    if (account.reading && account.reading.status === "disabled") text += "\nThis account is now paused."
    if (account.reading && account.reading.stale) text += "\nQuota is a last-known reading."
    if (activityBackend.fetchError !== "" && account.reading) text += "\nShowing last-known account activity."
    if (activityBackend.rustProxy) text += "\nLatest completed request, including failures; activity resets when the proxy restarts."
    return text
  }

  function iconUrl(provider) {
    if (!provider) return ""
    if (!UsageLogic.contains(["claude", "codex", "kimi", "meta"], provider.id)) return ""
    if (provider.id === "codex") {
      return Qt.resolvedUrl(colorLuminance(surface) >= 0.5
        ? "assets/codex-light.svg" : "assets/codex.svg")
    }
    return Qt.resolvedUrl("assets/" + provider.id + ".svg")
  }

  function barIconUrl(provider) {
    if (!provider) return ""
    if (!UsageLogic.contains(["claude", "codex", "kimi", "meta"], provider.id)) return ""
    return Qt.resolvedUrl("assets/" + provider.id + "-bar.svg")
  }

  function colorLuminance(color) {
    function channel(value) {
      return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
  }

  function errorBody(provider) {
    return UsageLogic.errorBody(provider)
  }

  function footerLeft() {
    if (viewMode === "costs") {
      if (costBackend.fetchError !== "") return costBackend.fetchError
      if (costBackend.lastSuccessAt > 0)
        return "Updated " + Qt.formatTime(new Date(costBackend.lastSuccessAt), "HH:mm")
      // The body shows the first load.
      return costBackend.loading ? "" : "Open Costs to load session history"
    }
    if (backend.fetchError !== "") return backend.fetchError
    // During an outage the backend keeps last-known readings; say so rather
    // than presenting them under a fresh "Updated" time.
    const stale = UsageLogic.anyStaleReading(providers) ? " · some readings are last known" : ""
    if (backend.lastSuccessAt > 0) return "Updated " + Qt.formatTime(new Date(backend.lastSuccessAt), "HH:mm:ss") + stale
    if (stale !== "") return "Some readings are last known"
    return backend.loading ? "" : "Waiting for first refresh"
  }

  function footerTooltip() {
    const error = viewMode === "costs" ? costBackend.fetchError : backend.fetchError
    if (error !== "") return error
    if (viewMode === "costs" && costBackend.lastSuccessAt > 0)
      return "Updated " + Qt.formatDateTime(new Date(costBackend.lastSuccessAt), "MMM d, HH:mm:ss")
        + (costBackend.payload && Number(costBackend.payload.scanDurationMs) > 0
          ? " · Scan " + costBackend.payload.scanDurationMs + "ms" : "")
    if (viewMode === "limits" && backend.lastSuccessAt > 0)
      return "Updated " + Qt.formatDateTime(new Date(backend.lastSuccessAt), "MMM d, HH:mm:ss")
    return ""
  }

  function footerRight() {
    if (viewMode !== "limits") return ""
    return UsageLogic.nextRefreshText(backend.nextRefreshAt, nowMs)
  }

  function contextText() {
    if (viewMode === "costs")
      return costBackend.loading && costsView.hasResult ? "Refreshing…" : ""
    // Before the first reading the body shows the loading state.
    if (providers.length === 0) return ""
    const context = UsageLogic.limitsContext(providers, proxyMode)
    return context + (backend.loading ? (context ? " · " : "") + "Refreshing…" : "")
  }

  visible: true
  implicitWidth: percentageMode ? percentageGroup.implicitWidth : iconButton.implicitWidth
  implicitHeight: percentageMode ? percentageGroup.implicitHeight : iconButton.implicitHeight

  onProvidersChanged: resetRefreshTimer.schedule()
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    if (viewMode === "costs") costBackend.ensureLoaded()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() {
      if (resetBackend.active) resetForm.focusFirst()
      else if (root.configuring) settingsViewItem.focusFirst()
      else keyCatcher.forceActiveFocus()
    })
  } else {
    scrollTimer.stop()
    if (costsView) costsView.closeMenu()
    if (configuring) viewMode = settingsReturnView
  }

  onViewModeChanged: {
    if (costsView) costsView.closeMenu()
    if (viewMode !== "settings") settingsViewItem.discardKey()
    if (viewMode === "costs") costBackend.ensureLoaded()
    if (panelFlick) panelFlick.contentY = 0
  }

  UsageBackend {
    id: backend
    settings: root.settings
    onRefreshed: activityBackend.refresh()
  }

  UsageActivityBackend {
    id: activityBackend
    usageBackend: backend
    settings: root.settings
  }

  ResetBackend {
    id: resetBackend
    usageBackend: backend
    onFinished: backend.refresh()
    onStateChanged: {
      if (panelFlick) panelFlick.contentY = 0
      Qt.callLater(function() {
        if (resetBackend.active) resetForm.focusFirst()
        else keyCatcher.forceActiveFocus()
      })
    }
  }

  CostBackend {
    id: costBackend
    settings: root.settings
    proxyImplementation: backend.proxyImplementation
  }

  // Every row reports its natural name width here; every card then uses the
  // widest (capped per row), so the meters of all providers start at the same x.
  QtObject {
    id: labelRegistry
    property var rows: []
    property real widest: 0
    property bool pending: false
    function add(row) {
      rows.push(row)
      schedule()
    }
    function remove(row) {
      const index = rows.indexOf(row)
      if (index >= 0) rows.splice(index, 1)
      schedule()
    }
    function schedule() {
      if (pending) return
      pending = true
      Qt.callLater(measure)
    }
    function measure() {
      pending = false
      let widest = 0
      for (let i = 0; i < rows.length; i++)
        widest = Math.max(widest, Number(rows[i].naturalLabelWidth) || 0)
      labelRegistry.widest = widest
    }
  }

  // Jumping to a provider waits until the panel is open and laid out.
  Timer {
    id: scrollTimer
    property int attempts: 0
    interval: 30
    repeat: true
    function begin() {
      attempts = 0
      restart()
    }
    onTriggered: {
      attempts++
      const card = root.providerCard(root.focusedProviderId)
      if (root.opened && root.viewMode === "limits" && card && card.height > 0) {
        root.scrollToProvider(root.focusedProviderId)
        stop()
      } else if (attempts >= 20) {
        stop()
      }
    }
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.nowMs = Date.now()
      root.refreshPassedReset()
    }
  }

  // The menu bar is visible while the panel is closed, so a reset refreshes the
  // reading when it happens, not only when the panel is next opened.
  Timer {
    id: resetRefreshTimer
    repeat: false
    function schedule() {
      const now = Date.now()
      const next = UsageLogic.nextResetAt(root.providers, now)
      if (next <= 0) {
        stop()
        return
      }
      // A little after the reset, so the provider reports the new window; long
      // waits are re-checked every few hours instead of one huge interval.
      interval = Math.max(1000, Math.min(next - now + 5000, 4 * 3600 * 1000))
      restart()
    }
    onTriggered: {
      root.nowMs = Date.now()
      root.refreshPassedReset()
      schedule()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.nextProvider(); return "ok" }
    function limits(): string { root.showLimits(); return "ok" }
    function costs(): string { root.showCosts(); return "ok" }
    function configureCosts(): string { root.showCostSettings(); return "ok" }
    function configure(): string { root.showSettings(); return "ok" }
  }

  Ui.BarIconButton {
    id: iconButton
    anchors.fill: parent
    visible: !root.percentageMode
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    tooltipText: root.iconTooltip()
    onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
  }

  Item {
    id: percentageGroup
    anchors.fill: parent
    visible: root.percentageMode
    implicitWidth: percentageRow.implicitWidth
    implicitHeight: percentageRow.implicitHeight

    Row {
      id: percentageRow
      anchors.centerIn: parent
      spacing: 0

      Repeater {
        model: root.percentageProviders

        delegate: Ui.WidgetButton {
          id: providerChip
          required property var modelData

          readonly property var lastAccount: root.lastAccount(modelData)
          readonly property bool usingPoolQuota: root.proxyMode && !lastAccount.reading
          readonly property var reading: root.proxyMode && lastAccount.reading ? lastAccount.reading : modelData
          readonly property var remainingValue: UsageLogic.minRemaining(reading)
          readonly property bool failed: remainingValue === null && modelData.status === "error"
          // A last-known reading kept through an outage must not look current.
          readonly property bool stale: !failed && UsageLogic.chipReadingStale(reading, modelData, usingPoolQuota)
          readonly property string remainingText: failed ? "!"
            : remainingValue === null ? (root.proxyMode ? "—" : "") : Math.round(remainingValue) + "%" + (stale ? "?" : "")
          readonly property string severity: failed ? "error" : UsageLogic.severity(
            reading, root.warningThreshold, root.criticalThreshold)
          readonly property bool stressed: severity === "warning" || severity === "critical" || severity === "error"
          readonly property color contentColor: active && useActiveColor
            ? activeColor : foreground

          bar: root.bar
          text: ""
          labelVisible: false
          hasVisualContent: true
          fixedWidth: providerChipContent.implicitWidth + Style.space(10)
          active: stressed || stale
          horizontalMargin: 0
          tooltipText: (failed ? UsageLogic.errorTitle(modelData)
              : String(modelData.name || modelData.id) + (remainingValue === null ? " usage unavailable"
                : " usage · " + Math.round(remainingValue) + "% remaining"))
            + (root.proxyMode ? "\n" + root.lastAccountTooltip(lastAccount) : "")
            + (usingPoolQuota ? "\nQuota shown: account with the most remaining capacity." : "")
            + (stale ? "\n" + UsageLogic.staleExplanation(reading, modelData) : "")
          onPressed: function(buttonCode) {
            root.handleProviderChipPress(String(providerChip.modelData.id), buttonCode)
          }

          Row {
            id: providerChipContent
            anchors.centerIn: parent
            spacing: Style.spacing.sm

            Item {
              id: providerMark
              y: Math.round((parent.height - height) / 2)
              width: Style.space(providerChip.modelData.id === "codex" ? 13 : 12)
              height: width

              Image {
                id: providerMarkImage
                anchors.fill: parent
                source: root.barIconUrl(providerChip.modelData)
                sourceSize.width: providerMark.width * 2
                sourceSize.height: providerMark.height * 2
                fillMode: Image.PreserveAspectFit
                visible: false
                layer.enabled: true
              }

              MultiEffect {
                anchors.fill: providerMarkImage
                source: providerMarkImage
                visible: providerMarkImage.status === Image.Ready
                colorization: 1.0
                colorizationColor: providerChip.contentColor
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                visible: providerMarkImage.status !== Image.Ready
                text: UsageLogic.providerMark(String(providerChip.modelData.id))
                color: providerChip.contentColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Text {
              objectName: "barAccountRemaining"
              textFormat: Text.PlainText
              y: Math.round((parent.height - height) / 2)
              text: providerChip.remainingText
              color: providerChip.contentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.Medium
            }

          }
        }
      }
    }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.percentageMode ? percentageGroup : iconButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: resetBackend.active ? resetForm : root.configuring ? settingsViewItem : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(resetBackend.active ? resetForm.implicitHeight
      : contentColumn.implicitHeight + (root.configuring ? settingsActions.implicitHeight + Style.spacing.lg : 0))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.configuring || resetBackend.active || costsView.menuOpen

      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.viewMode === "limits" && root.providers.length > 1) {
          root.stepProvider(dx)
        }
        if (dy !== 0) {
          let target = panelFlick.contentY + dy * Style.space(56)
          panelFlick.contentY = root.clamp(target, 0,
            Math.max(0, panelFlick.contentHeight - panelFlick.height))
        }
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshNow()
        else if (text === "c" || text === "C") root.showCosts()
        else if (text === "u" || text === "U") root.showLimits()
        else if (root.viewMode === "costs" && (text === "m" || text === "M")) costsView.openMetricMenu()
        else if (root.viewMode === "costs" && (text === "d" || text === "D")) costsView.tokenDetailsExpanded = !costsView.tokenDetailsExpanded
        else if (root.viewMode === "costs" && (text === "b" || text === "B")) costsView.modelsExpanded = !costsView.modelsExpanded
        else if (text === "s" || text === "S") root.showViewSettings()
        else if (text === "[") root.stepRange(-1)
        else if (text === "]") root.stepRange(1)
        else if (text === "?") root.shortcutsVisible = !root.shortcutsVisible
        else if ((text === "a" || text === "A") && root.viewMode === "limits"
            && (root.detailsAvailable || root.expandedAccountLimits))
          root.expandedAccountLimits = !root.expandedAccountLimits
      }

      SettingsActions {
        id: settingsActions
        objectName: "settingsActions"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.configuring && !resetBackend.active
        foreground: root.foreground
        urgent: root.urgent
        fontFamily: root.fontFamily
        errorText: root.configuring ? settingsViewItem.errorText : ""
        saving: root.configuring && settingsViewItem.saving
        onSaveRequested: settingsViewItem.submit()
        onCancelRequested: root.leaveSettings()
      }

      // Expanded sections and new delegates must be laid out before their
      // coordinates can be used to scroll the focused field into view.
      Timer {
        id: settingsRevealTimer
        property var item: null
        interval: 0
        onTriggered: {
          if (!root.configuring || !root.opened || !item || !item.visible) return
          for (let ancestor = item.parent; ancestor && ancestor !== panelFlick; ancestor = ancestor.parent)
            if (ancestor.forceLayout) ancestor.forceLayout()
          var point = item.mapToItem(panelFlick.contentItem, 0, 0)
          var bottom = point.y + item.height + Style.spacing.md
          var target = panelFlick.contentY
          if (point.y < target) target = point.y
          else if (bottom > target + panelFlick.height) target = bottom - panelFlick.height
          panelFlick.contentY = root.clamp(target, 0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        anchors.bottomMargin: settingsActions.visible ? settingsActions.implicitHeight + Style.spacing.lg : 0
        contentWidth: width
        contentHeight: resetBackend.active ? resetForm.implicitHeight : contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ResetConfirmation {
          id: resetForm
          width: panelFlick.width
          visible: resetBackend.active
          backend: resetBackend
          foreground: root.foreground
          background: root.surface
          fontFamily: root.fontFamily
          onCloseRequested: {
            if (resetBackend.state === "sending" || resetBackend.state === "uncertain") root.close()
            else resetBackend.cancel()
          }
        }

        Column {
          id: contentColumn
          visible: !resetBackend.active
          width: panelFlick.width
          spacing: Style.spacing.xxl

          Column {
            visible: !root.configuring
            width: parent.width
            spacing: Style.spacing.md

            Item {
              width: parent.width
              implicitHeight: Math.max(panelTitle.implicitHeight, headerActions.implicitHeight)

              Text {
                id: panelTitle
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: headerActions.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                text: "Model Usage"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Row {
                id: headerActions
                anchors.right: parent.right
                spacing: Style.spacing.xs

                Ui.PanelActionButton {
                  objectName: root.viewMode === "costs" ? "costSettingsButton" : "usageSettingsButton"
                  iconText: "󰒓"
                  tooltipText: "Settings (s)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.showViewSettings()
                }

                Ui.PanelActionButton {
                  objectName: "shortcutsButton"
                  iconText: "?"
                  tooltipText: root.shortcutsVisible ? "Hide keyboard shortcuts (?)" : "Keyboard shortcuts (?)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.shortcutsVisible = !root.shortcutsVisible
                }

                Ui.PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: root.viewMode === "costs" ? "Refresh estimated costs" : "Refresh usage"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  enabled: !(root.viewMode === "costs" ? costBackend.loading : backend.loading)
                  onClicked: root.refreshNow()
                }
              }
            }

            UsageNavigation {
              id: navigation
              width: parent.width
              viewMode: root.viewMode
              viewOptions: root.viewOptions
              foreground: root.foreground
              fontFamily: root.fontFamily
              onViewRequested: function(value) { root.viewMode = value }
            }

            // "7 accounts · 3 providers", with the Details toggle beside it.
            Item {
              width: parent.width
              visible: panelContext.text !== "" || detailsToggle.visible
              implicitHeight: Math.max(panelContext.implicitHeight, detailsToggle.visible ? detailsToggle.implicitHeight : 0)

              Text {
                id: panelContext
                objectName: "panelContext"
                anchors.left: parent.left
                anchors.right: detailsToggle.visible ? detailsToggle.left : parent.right
                anchors.rightMargin: detailsToggle.visible ? Style.spacing.md : 0
                anchors.verticalCenter: parent.verticalCenter
                text: root.contextText()
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Ui.Button {
                id: detailsToggle
                objectName: "additionalLimitsToggle"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.viewMode === "limits" && (root.detailsAvailable || root.expandedAccountLimits)
                text: "Details " + (root.expandedAccountLimits ? "▴" : "▾")
                focusable: true
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.xxs
                tooltipText: root.expandedAccountLimits ? "Hide details (a)"
                  : "Show every limit, reset time and account fact (a)"
                Accessible.name: root.expandedAccountLimits ? "Hide details" : "Show details"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.expandedAccountLimits = !root.expandedAccountLimits
              }
            }
          }

          Grid {
            objectName: "shortcutLegend"
            visible: root.shortcutsVisible && !root.configuring
            width: parent.width
            columns: 4
            columnSpacing: Style.spacing.md
            rowSpacing: Style.spacing.xs
            Accessible.role: Accessible.StaticText
            Accessible.name: "Keyboard shortcuts"

            Repeater {
              // Key and action cells, two shortcuts per line.
              model: root.shortcutRows().reduce(function(cells, row) {
                return cells.concat([{ text: row.key, key: true }, { text: row.action, key: false }])
              }, [])
              delegate: Text {
                required property var modelData
                width: modelData.key ? Style.space(64)
                  : Math.max(0, (parent.width - Style.space(64) * 2 - Style.spacing.md * 3) / 2)
                text: modelData.text
                textFormat: Text.PlainText
                color: modelData.key ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: modelData.key
                elide: Text.ElideRight
              }
            }
          }

          SettingsView {
            id: settingsViewItem
            objectName: "settingsView"
            visible: root.configuring
            width: parent.width
            foreground: root.foreground
            urgent: root.urgent
            surface: root.surface
            fontFamily: root.fontFamily
            accountDetails: root.accountDiagnostics()
            proxyProviders: root.proxyMode ? backend.providers : []
            proxyImplementation: backend.proxyImplementation
            sources: costBackend.payload ? UsageLogic.listOrEmpty(costBackend.payload.sources) : []
            onSaveRequested: function(values) { root.saveSettings(values) }
            onCancelRequested: root.leaveSettings()
            onRevealRequested: function(item) {
              settingsRevealTimer.item = item
              settingsRevealTimer.restart()
            }
          }

          // Session counts need Fusebox's live feed; while it is down, one line
          // says so instead of every account row.
          Text {
            objectName: "liveActivityStatus"
            width: parent.width
            visible: root.viewMode === "limits" && activityBackend.useLive
              && activityBackend.liveState !== "live" && root.providers.length > 0
            text: activityBackend.liveNotice + " Session counts are hidden until it reconnects."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.viewMode === "limits" && root.providers.length === 0
            width: parent.width
            topPadding: Style.spacing.huge
            bottomPadding: Style.spacing.huge
            text: backend.loading
              ? "Loading AI subscription usage…"
              : root.proxyMode ? "No enabled managed accounts found. Check the accounts configured in " + UsageLogic.proxyName(backend.proxyImplementation) + "."
              : "No connected providers found. Enable a provider in the widget settings and sign in to its CLI."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // Every provider at once, one card each.
          Column {
            id: providerSection
            visible: root.viewMode === "limits" && root.providers.length > 0
            width: parent.width
            spacing: Style.spacing.lg

            Repeater {
              id: providerRepeater
              model: root.providers

              ProviderCard {
                required property var modelData
                width: providerSection.width
                provider: modelData
                expanded: root.expandedAccountLimits
                liveActivity: activityBackend.useLive
                activity: activityBackend
                proxyMode: root.proxyMode
                resetAllowed: !resetBackend.active && !resetBackend.busy
                hideAccountEmails: root.hideAccountEmails
                historyOpen: root.historyOpen[String(modelData.id)] === true
                historyMode: root.historyMode
                labelWidth: root.labelColumnWidth
                labelColumn: labelRegistry
                reserveResetSlot: root.bankedResetColumn
                iconSource: root.iconUrl(modelData)
                nowMs: root.nowMs
                minuteMs: root.minuteMs
                refreshing: backend.loading
                warningThreshold: root.warningThreshold
                criticalThreshold: root.criticalThreshold
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
                cardRadius: root.usageCardRadius
                onResetRequested: function(account, label) { resetBackend.begin(account, label) }
                onHistoryToggled: function(open) {
                  if (open !== (root.historyOpen[String(modelData.id)] === true)) root.toggleHistory(String(modelData.id))
                }
                onRangeRequested: function(mode) { root.historyMode = mode }
              }
            }
          }

          UsageCosts {
            id: costsView
            visible: root.viewMode === "costs"
            width: parent.width
            payload: costBackend.payload
            loading: costBackend.loading
            errorText: costBackend.fetchError
            periodDays: costBackend.periodDays
            foreground: root.foreground
            urgent: root.urgent
            surface: root.surface
            fontFamily: root.fontFamily
            cardRadius: root.usageCardRadius
            fuseboxHost: costBackend.fuseboxHost
            onPeriodRequested: function(days) { costBackend.selectPeriod(days) }
            onSourceSettingsRequested: root.showCostSettings()
            onMenuClosed: Qt.callLater(function() {
              if (root.opened && !root.configuring && !resetBackend.active)
                keyCatcher.forceActiveFocus()
            })
          }

          Ui.PanelSeparator { visible: !root.configuring; foreground: root.foreground }

          Item {
            visible: !root.configuring
            width: parent.width
            implicitHeight: Math.max(footerLeft.implicitHeight, footerRight.implicitHeight)

            Text {
              id: footerLeft
              textFormat: Text.PlainText
              HoverHandler { id: footerHover }
              PlainToolTip {
                visible: footerHover.hovered && text !== ""
                text: root.footerTooltip()
                fontFamily: root.fontFamily
              }
              anchors.left: parent.left
              anchors.right: footerRight.left
              anchors.rightMargin: Style.spacing.controlGap
              objectName: "footerStatus"
              text: root.footerLeft()
              Accessible.name: root.footerTooltip() || text
              color: (root.viewMode === "costs" ? costBackend.fetchError !== ""
                  : backend.fetchError !== "" || UsageLogic.anyStaleReading(root.providers))
                ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              id: footerRight
              objectName: "footerRefresh"
              textFormat: Text.PlainText
              anchors.right: parent.right
              text: root.footerRight()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
