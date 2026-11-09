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
  property string selectedProviderId: ""
  property bool expandedAccountLimits: false
  property bool shortcutsVisible: false
  // Reset time already refreshed for, so a passed reset triggers one refresh.
  property double refreshedForResetAt: 0
  property string historyMode: "h24"
  property string viewMode: "limits"
  property string settingsReturnView: "limits"
  readonly property bool configuring: viewMode === "settings" || viewMode === "cost-settings"
  readonly property var activeSettingsForm: viewMode === "cost-settings" ? costConfigForm : configForm
  property alias costSettingsForm: costConfigForm
  property alias settingsForm: configForm
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
    return hideAccountEmails ? "Account " + index : String(account.account || "Account " + index)
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
  readonly property int providerIndex: {
    for (let i = 0; i < providers.length; i++)
      if (providers[i].id === selectedProviderId) return i
    return 0
  }
  readonly property var providerSummary: providers.length > 0 ? providers[providerIndex] : null
  readonly property var provider: providerSummary
  readonly property var proxyAccounts: UsageLogic.listOrEmpty(providerSummary && providerSummary.accounts)
  readonly property bool accountOverview: proxyMode && proxyAccounts.length > 0
  readonly property bool historyAvailable: !accountOverview && !!provider && !!provider.history
    && ((UsageLogic.isListLike(provider.history.h24) && provider.history.h24.length > 0)
      || (UsageLogic.isListLike(provider.history.d7) && provider.history.d7.length > 0))
  readonly property bool hasAdditionalLimits: accountOverview
    && UsageLogic.hasAdditionalWindows(proxyAccounts, warningThreshold, criticalThreshold)
  property alias accountCards: accountRepeater
  property alias quotaHistory: history
  property alias usageBackend: backend
  readonly property var providerOptions: {
    var result = []
    for (let i = 0; i < providers.length; i++)
      result.push({ value: String(providers[i].id), label: String(providers[i].name || providers[i].id) })
    return result
  }

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

  function ensureSelection() {
    if (providers.length === 0) {
      selectedProviderId = ""
      return
    }
    for (let i = 0; i < providers.length; i++)
      if (providers[i].id === selectedProviderId) return
    selectedProviderId = providers[0].id
  }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = String(providers[wrapped].id)
    if (panelFlick) panelFlick.contentY = 0
  }

  function selectProviderId(providerId) {
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].id === providerId) {
        selectProvider(i)
        return
      }
    }
  }

  function nextProvider() {
    selectProvider(providerIndex + 1)
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

  // Settings for the current view, like the gear button.
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
      rows.push({ key: "←/→ h/l", action: "provider" }, { key: "p", action: "provider menu" })
    if (viewMode === "costs") rows.push({ key: "[ ]", action: "period" })
    else if (historyAvailable) rows.push({ key: "[ ]", action: "history range" })
    if (viewMode === "limits" && (hasAdditionalLimits || expandedAccountLimits))
      rows.push({ key: "a", action: "additional limits" })
    if (viewMode === "costs")
      rows.push({ key: "m", action: "metric" }, { key: "d", action: "token details" }, { key: "b", action: "models" })
    rows.push({ key: "r", action: "refresh" }, { key: "s", action: "settings" }, { key: "↑/↓ j/k", action: "scroll" },
      { key: "Tab", action: "next panel" }, { key: "Esc", action: "close" }, { key: "?", action: "hide keys" })
    return rows
  }

  function showSettings() {
    if (!configuring) settingsReturnView = viewMode
    configForm.begin(settings)
    viewMode = "settings"
    open()
    Qt.callLater(function() { configForm.focusFirst() })
  }

  function showCostSettings() {
    settingsReturnView = "costs"
    costConfigForm.begin(settings)
    viewMode = "cost-settings"
    open()
    Qt.callLater(function() { costConfigForm.focusFirst() })
  }

  function leaveSettings() {
    activeSettingsForm.discardKey()
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
        activeSettingsForm.errorText = "Could not save settings. Make sure Model Usage is enabled in the bar, then try again."
        activeSettingsForm.finishSave(false)
        return false
      }
      settings = entry
    }
    activeSettingsForm.finishSave(true)
    leaveSettings()
    return true
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.MiddleButton) nextProvider()
    else if (buttonCode === Qt.LeftButton) toggle()
  }

  function handleProviderChipPress(providerId, buttonCode) {
    if (buttonCode === Qt.MiddleButton) {
      nextProvider()
      return
    }
    if (buttonCode !== Qt.LeftButton) return
    var sameProvider = viewMode === "limits" && selectedProviderId === providerId
    viewMode = "limits"
    selectProviderId(providerId)
    if (opened && sameProvider) close()
    else open()
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
    if (!UsageLogic.contains(["claude", "codex", "kimi"], provider.id)) return ""
    if (provider.id === "codex") {
      return Qt.resolvedUrl(colorLuminance(surface) >= 0.5
        ? "assets/codex-light.svg" : "assets/codex.svg")
    }
    return Qt.resolvedUrl("assets/" + provider.id + ".svg")
  }

  function barIconUrl(provider) {
    if (!provider) return ""
    if (!UsageLogic.contains(["claude", "codex", "kimi"], provider.id)) return ""
    return Qt.resolvedUrl("assets/" + provider.id + "-bar.svg")
  }

  function colorLuminance(color) {
    function channel(value) {
      return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
  }

  function errorBody(provider) {
    if (!provider) return ""
    var message = String(provider.message || "Usage data is unavailable.")
    if (provider.authCommand && (provider.errorKind === "no_credentials" || provider.errorKind === "expired"))
      message += " Run “" + provider.authCommand + "” in a terminal, then refresh."
    return message
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
    let context = accountOverview
      ? UsageLogic.plural(proxyAccounts.length, "connected account") : heroMeta(provider)
    if (providers.length === 1 && provider)
      context = provider.name + (context ? " · " + context : "")
    return context + (backend.loading ? (context ? " · " : "") + "Refreshing…" : "")
  }

  visible: true
  implicitWidth: percentageMode ? percentageGroup.implicitWidth : iconButton.implicitWidth
  implicitHeight: percentageMode ? percentageGroup.implicitHeight : iconButton.implicitHeight

  onProvidersChanged: {
    ensureSelection()
    resetRefreshTimer.schedule()
  }
  onSelectedProviderIdChanged: expandedAccountLimits = false
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    if (viewMode === "costs") costBackend.ensureLoaded()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() {
      if (resetBackend.active) resetForm.focusFirst()
      else if (root.configuring) activeSettingsForm.focusFirst()
      else keyCatcher.forceActiveFocus()
    })
  } else {
    navigation.closeProviderMenu()
    if (costsView) costsView.closeMenu()
    if (configuring) viewMode = settingsReturnView
  }

  onViewModeChanged: {
    navigation.closeProviderMenu()
    if (costsView) costsView.closeMenu()
    if (viewMode !== "settings") configForm.discardKey()
    if (viewMode !== "cost-settings") costConfigForm.discardKey()
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
    tooltipText: root.provider ? "Model usage · " + root.provider.name
      + (root.proxyMode ? "\n" + root.lastAccountTooltip(root.lastAccount(root.provider)) : "") : "Model usage"
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
    focusTarget: resetBackend.active ? resetForm : root.configuring ? root.activeSettingsForm : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(resetBackend.active ? resetForm.implicitHeight
      : contentColumn.implicitHeight + (root.configuring ? settingsActions.implicitHeight + Style.spacing.lg : 0))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.configuring || resetBackend.active || navigation.menuOpen || costsView.menuOpen

      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.viewMode === "limits" && root.providers.length > 1) {
          root.selectProvider(root.providerIndex + dx)
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
        else if (text === "p" || text === "P") navigation.openProviderMenu()
        else if (root.viewMode === "costs" && (text === "m" || text === "M")) costsView.openMetricMenu()
        else if (root.viewMode === "costs" && (text === "d" || text === "D")) costsView.tokenDetailsExpanded = !costsView.tokenDetailsExpanded
        else if (root.viewMode === "costs" && (text === "b" || text === "B")) costsView.modelsExpanded = !costsView.modelsExpanded
        else if (text === "s" || text === "S") root.showViewSettings()
        else if (text === "[") root.stepRange(-1)
        else if (text === "]") root.stepRange(1)
        else if (text === "?") root.shortcutsVisible = !root.shortcutsVisible
        else if ((text === "a" || text === "A") && root.viewMode === "limits"
            && (root.hasAdditionalLimits || root.expandedAccountLimits))
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
        errorText: root.configuring ? root.activeSettingsForm.errorText : ""
        saving: root.configuring && root.activeSettingsForm.saving
        onSaveRequested: root.activeSettingsForm.submit()
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
                  tooltipText: root.viewMode === "costs" ? "Cost sources and prices" : "Model Usage settings"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.viewMode === "costs" ? root.showCostSettings() : root.showSettings()
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
              providerOptions: root.providerOptions
              providerId: root.selectedProviderId
              foreground: root.foreground
              surface: root.surface
              fontFamily: root.fontFamily
              onViewRequested: function(value) { root.viewMode = value }
              onProviderRequested: function(value) { root.selectProviderId(value) }
              onMenuClosed: Qt.callLater(function() {
                if (root.opened && !root.configuring && !resetBackend.active)
                  keyCatcher.forceActiveFocus()
              })
            }

            Text {
              objectName: "panelContext"
              width: parent.width
              text: root.contextText()
              visible: text !== ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
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

          UsageSettings {
            id: configForm
            visible: root.viewMode === "settings"
            width: parent.width
            foreground: root.foreground
            urgent: root.urgent
            surface: root.surface
            fontFamily: root.fontFamily
            accountDetails: root.accountTooltip(root.provider)
            proxyProviders: root.proxyMode ? backend.providers : []
            proxyImplementation: backend.proxyImplementation
            onSaveRequested: function(values) { root.saveSettings(values) }
            onCancelRequested: root.leaveSettings()
            onRevealRequested: function(item) {
              settingsRevealTimer.item = item
              settingsRevealTimer.restart()
            }
          }
          CostSettings {
            id: costConfigForm
            sources: costBackend.payload ? UsageLogic.listOrEmpty(costBackend.payload.sources) : []
            visible: root.viewMode === "cost-settings"
            width: parent.width
            foreground: root.foreground
            urgent: root.urgent
            surface: root.surface
            fontFamily: root.fontFamily
            onSaveRequested: function(values) { root.saveSettings(values) }
            onCancelRequested: root.leaveSettings()
            onRevealRequested: function(item) {
              settingsRevealTimer.item = item
              settingsRevealTimer.restart()
            }
          }

          Column {
            id: accountOverviewSection
            visible: root.viewMode === "limits" && root.accountOverview
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              objectName: "liveActivityStatus"
              width: parent.width
              visible: activityBackend.useLive
              text: activityBackend.liveNotice
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Ui.Button {
              objectName: "additionalLimitsToggle"
              visible: root.expandedAccountLimits
                || root.hasAdditionalLimits
              text: "Additional limits " + (root.expandedAccountLimits ? "▴" : "▾")
              focusable: true
              horizontalPadding: Style.spacing.sm
              tooltipText: "Show every limit on each account (a)"
              Accessible.name: root.expandedAccountLimits ? "Hide additional limits" : "Show additional limits"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.expandedAccountLimits = !root.expandedAccountLimits
            }

            Repeater {
              id: accountRepeater
              model: root.proxyAccounts
              AccountCard {
                required property var modelData
                required property int index
                width: accountOverviewSection.width
                account: modelData
                accountLabel: root.accountDisplayName(modelData, index + 1)
                expanded: root.expandedAccountLimits
                liveActivity: activityBackend.useLive
                load: UsageLogic.accountLoad(modelData, activityBackend)
                resetEnabled: root.proxyMode && UsageLogic.supportsAccountReset(modelData)
                  && Number(modelData.credits && modelData.credits.resetCreditsAvailable) > 0
                  && !resetBackend.active && !resetBackend.busy
                iconSource: root.iconUrl(modelData)
                nowMs: root.nowMs
                refreshing: backend.loading
                minuteMs: root.minuteMs
                warningThreshold: root.warningThreshold
                criticalThreshold: root.criticalThreshold
                errorText: root.errorBody(modelData)
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
                cardRadius: root.usageCardRadius
                onResetRequested: resetBackend.begin(modelData, accountLabel)
              }
            }

          }

          Text {
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

          Ui.BorderSurface {
            id: errorCard
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider && root.provider.status === "error"
            width: parent.width
            implicitHeight: errorColumn.implicitHeight + errorCard.contentTopInset + errorCard.contentBottomInset
            color: root.alpha(root.urgent, 0.09)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.4), Style.spacing.hairline)
            padding: Style.spacing.xxl
            radius: root.usageCardRadius

            Column {
              id: errorColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: errorCard.contentLeftInset
              anchors.rightMargin: errorCard.contentRightInset
              anchors.topMargin: errorCard.contentTopInset
              spacing: Style.spacing.labelGap

              Text {
                width: parent.width
                text: UsageLogic.errorTitle(root.provider)
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: root.errorBody(root.provider)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
              }
            }
          }

          Text {
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider && root.provider.status !== "error"
              && String(root.provider.notice || "") !== ""
            width: parent.width
            text: root.provider ? String(root.provider.notice || "") : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Ui.PanelSeparator {
            visible: root.viewMode === "limits" && (limitsSection.visible || creditsSection.visible)
            foreground: root.foreground
          }

          Column {
            id: limitsSection
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider && root.provider.status === "ok"
              && UsageLogic.isListLike(root.provider.windows) && root.provider.windows.length > 0
            width: parent.width
            spacing: Style.spacing.lg

            Ui.PanelSectionHeader {
              text: "USAGE LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.provider ? UsageLogic.listOrEmpty(root.provider.windows) : []

              LimitCard {
                required property var modelData
                width: limitsSection.width
                window: modelData
                nowMs: root.nowMs
                refreshing: backend.loading
                warningThreshold: root.warningThreshold
                criticalThreshold: root.criticalThreshold
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
                cardRadius: root.usageCardRadius
              }
            }
          }

          Column {
            id: creditsSection
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider
              && root.provider.status === "ok" && !!root.provider.credits
            width: parent.width
            spacing: Style.spacing.lg

            Ui.PanelSectionHeader {
              text: root.provider && root.provider.credits
                ? String(root.provider.credits.label || "CREDITS").toUpperCase() : "CREDITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CreditsCard {
              width: parent.width
              credits: root.provider ? root.provider.credits : null
              warningThreshold: root.warningThreshold
              foreground: root.foreground
              urgent: root.urgent
              fontFamily: root.fontFamily
              cardRadius: root.usageCardRadius
            }
          }

          Ui.PanelSeparator {
            visible: root.viewMode === "limits" && history.visible
            foreground: root.foreground
          }

          UsageHistory {
            id: history
            objectName: "quotaHistory"
            visible: root.viewMode === "limits" && root.historyAvailable
            width: parent.width
            history: root.provider ? root.provider.history : ({ h24: [], d7: [] })
            mode: root.historyMode
            foreground: root.foreground
            fontFamily: root.fontFamily
            onRangeRequested: function(mode) { root.historyMode = mode }
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
            onPeriodRequested: function(days) { costBackend.selectPeriod(days) }
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
              HoverHandler { id: footerHover }
              Ui.PanelToolTip {
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
