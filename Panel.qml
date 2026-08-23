pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Ui.Panel {
  id: root
  moduleName: "digitalpals.model-usage"
  ipcTarget: "digitalpals.model-usage"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: backend.providers
  property string selectedProviderId: ""
  property bool providerCursorActive: false
  property string historyMode: "h24"
  property string viewMode: "limits"
  property double nowMs: Date.now()

  readonly property var viewOptions: [
    { value: "limits", label: "Limits" },
    { value: "costs", label: "Costs" }
  ]

  readonly property int criticalThreshold: UsageLogic.clamp(
    setting("criticalThreshold", 10), 0, 100)
  readonly property int warningThreshold: Math.max(criticalThreshold, UsageLogic.clamp(
    setting("warningThreshold", 25), 0, 100))
  readonly property string displayMode: String(setting("barDisplayMode", "Icon"))
  readonly property var percentageProviders: UsageLogic.meaningfulProviders(providers)
  readonly property bool percentageMode: displayMode === "Percentages"
    && !(bar && bar.vertical) && percentageProviders.length > 0
  readonly property bool alarming: anyProviderAlarming()
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].id === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null
  readonly property var providerOptions: {
    var result = []
    for (var i = 0; i < providers.length; i++)
      result.push({ value: String(providers[i].id), label: String(providers[i].name || providers[i].id) })
    return result
  }

  function alpha(color, opacity) {
    return Qt.rgba(color.r, color.g, color.b, opacity)
  }

  function clamp(value, low, high) { return Math.max(low, Math.min(high, value)) }

  function anyProviderAlarming() {
    for (var i = 0; i < providers.length; i++) {
      var severity = UsageLogic.severity(providers[i], warningThreshold, criticalThreshold)
      if (severity === "warning" || severity === "critical") return true
    }
    return false
  }

  function ensureSelection() {
    if (providers.length === 0) {
      selectedProviderId = ""
      return
    }
    for (var i = 0; i < providers.length; i++)
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
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].id === providerId) {
        selectProvider(i)
        return
      }
    }
  }

  function handleProviderTabHover(isHovered) {
    if (isHovered) providerCursorActive = true
  }

  function nextProvider() {
    providerCursorActive = true
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
    if (!window) return "none"
    var remaining = Number(window.remaining)
    if (!isFinite(remaining)) return "none"
    if (remaining <= criticalThreshold) return "critical"
    if (remaining <= warningThreshold) return "warning"
    return "ok"
  }

  function durationUntil(epochSeconds) {
    var seconds = Number(epochSeconds)
    if (!isFinite(seconds) || seconds <= 0) return ""
    var remaining = Math.floor(seconds - nowMs / 1000)
    if (remaining <= 0) return "now"
    var days = Math.floor(remaining / 86400)
    var hours = Math.floor((remaining % 86400) / 3600)
    var minutes = Math.floor((remaining % 3600) / 60)
    var secs = remaining % 60
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + minutes + "m"
    if (minutes > 0) return minutes + "m " + secs + "s"
    return Math.max(1, secs) + "s"
  }

  function absoluteReset(epochSeconds) {
    var seconds = Number(epochSeconds)
    if (!isFinite(seconds) || seconds <= 0) return ""
    var date = new Date(seconds * 1000)
    return seconds * 1000 - nowMs < 86400000
      ? Qt.formatTime(date, "HH:mm")
      : Qt.formatDateTime(date, "MMM d, HH:mm")
  }

  function resetText(window) {
    if (!window || !window.resetsAt) return ""
    var relative = durationUntil(window.resetsAt)
    var absolute = absoluteReset(window.resetsAt)
    if (relative === "") return ""
    return "Resets in " + relative + (absolute !== "" ? " · " + absolute : "")
  }

  function heroMeta(provider) {
    return provider && provider.plan ? String(provider.plan) : ""
  }

  function accountTooltip(provider) {
    if (!provider) return ""
    var lines = []
    if (provider.account) lines.push("Account: " + String(provider.account))
    if (provider.source) lines.push("Source: " + String(provider.source))
    return lines.join("\n")
  }

  function iconUrl(provider) {
    if (!provider) return ""
    if (provider.id === "codex") {
      return Qt.resolvedUrl(colorLuminance(surface) >= 0.5
        ? "assets/codex-light.svg" : "assets/codex.svg")
    }
    return Qt.resolvedUrl("assets/" + provider.id + ".svg")
  }

  function barIconUrl(provider) {
    if (!provider) return ""
    return Qt.resolvedUrl("assets/" + provider.id + "-bar.svg")
  }

  function colorLuminance(color) {
    function channel(value) {
      return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
  }

  function currencyPrefix(currency) {
    var value = String(currency || "").toUpperCase()
    if (value === "USD") return "$"
    if (value === "EUR") return "€"
    if (value === "GBP") return "£"
    if (value === "CNY") return "¥"
    return value === "" ? "" : value + " "
  }

  function formatAmount(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var digits = Math.abs(amount - Math.round(amount)) < 0.001 ? 0 : 2
    return currencyPrefix(currency) + amount.toFixed(digits)
  }

  function creditsPrimary(credits) {
    if (!credits) return ""
    if (credits.remaining !== null && credits.remaining !== undefined)
      return formatAmount(credits.remaining, credits.currency) + " remaining"
    if (credits.unlimited) return "Unlimited"
    if (credits.used !== null && credits.used !== undefined)
      return formatAmount(credits.used, credits.currency) + " used"
    if (credits.resetCreditsAvailable !== null && credits.resetCreditsAvailable !== undefined)
      return credits.resetCreditsAvailable + " reset credit" + (credits.resetCreditsAvailable === 1 ? "" : "s")
    return "Available"
  }

  function creditsDetail(credits) {
    if (!credits) return ""
    var parts = []
    if (credits.used !== null && credits.used !== undefined) {
      if (credits.limit !== null && credits.limit !== undefined)
        parts.push(formatAmount(credits.used, credits.currency) + " used of " + formatAmount(credits.limit, credits.currency))
      else parts.push(formatAmount(credits.used, credits.currency) + " used this month")
    }
    if (credits.unlimited && credits.remaining !== null && credits.remaining !== undefined)
      parts.push("No monthly spending cap")
    if (credits.total !== null && credits.total !== undefined)
      parts.push(formatAmount(credits.total, credits.currency) + " funded")
    if (credits.resetCreditsAvailable !== null && credits.resetCreditsAvailable !== undefined)
      parts.push(credits.resetCreditsAvailable + " rate-limit reset credit" + (credits.resetCreditsAvailable === 1 ? "" : "s"))
    return parts.join(" · ")
  }

  function errorBody(provider) {
    if (!provider) return ""
    var message = String(provider.message || "Usage data is unavailable.")
    if (provider.errorKind === "no_credentials" || provider.errorKind === "expired")
      message += " Run “" + provider.authCommand + "” in a terminal, then refresh."
    return message
  }

  function footerLeft() {
    if (viewMode === "costs") {
      if (costBackend.fetchError !== "") return costBackend.fetchError
      if (costBackend.lastSuccessAt > 0)
        return "Updated " + Qt.formatTime(new Date(costBackend.lastSuccessAt), "HH:mm:ss")
      return costBackend.loading ? "Scanning transcripts…" : "Open Costs to scan local activity"
    }
    if (backend.fetchError !== "") return backend.fetchError
    if (backend.lastSuccessAt > 0) return "Updated " + Qt.formatTime(new Date(backend.lastSuccessAt), "HH:mm:ss")
    return backend.loading ? "Refreshing…" : "Waiting for first refresh"
  }

  function footerRight() {
    if (viewMode === "costs") {
      var duration = costBackend.payload ? Number(costBackend.payload.scanDurationMs) : 0
      return duration > 0 ? "Scan " + duration + "ms" : ""
    }
    if (backend.nextRefreshAt <= 0) return ""
    var seconds = Math.max(0, Math.floor((backend.nextRefreshAt - nowMs) / 1000))
    var minutes = Math.floor(seconds / 60)
    var remainder = String(seconds % 60).padStart(2, "0")
    return "Next " + minutes + ":" + remainder
  }

  visible: true
  implicitWidth: percentageMode ? percentageGroup.implicitWidth : iconButton.implicitWidth
  implicitHeight: percentageMode ? percentageGroup.implicitHeight : iconButton.implicitHeight

  onProvidersChanged: ensureSelection()
  onOpenedChanged: if (opened) {
    providerCursorActive = false
    nowMs = Date.now()
    if (viewMode === "costs") costBackend.ensureLoaded()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onViewModeChanged: {
    if (viewMode === "costs") costBackend.ensureLoaded()
    if (panelFlick) panelFlick.contentY = 0
  }

  UsageBackend {
    id: backend
    settings: root.settings
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
    onTriggered: root.nowMs = Date.now()
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
  }

  Ui.BarIconButton {
    id: iconButton
    anchors.fill: parent
    visible: !root.percentageMode
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    tooltipText: root.provider ? "Model usage · " + root.provider.name : "Model usage"
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

          readonly property var remainingValue: UsageLogic.minRemaining(modelData)
          readonly property string remainingText: remainingValue === null
            ? "" : Math.round(remainingValue) + "%"
          readonly property string severity: UsageLogic.severity(
            modelData, root.warningThreshold, root.criticalThreshold)
          readonly property bool stressed: severity === "warning" || severity === "critical"
          readonly property color contentColor: active && useActiveColor
            ? activeColor : foreground

          bar: root.bar
          text: ""
          labelVisible: false
          hasVisualContent: true
          fixedWidth: providerChipContent.implicitWidth + Style.space(10)
          active: stressed
          horizontalMargin: 0
          tooltipText: String(modelData.name || modelData.id)
            + (remainingValue === null ? " usage unavailable"
              : " usage · " + Math.round(remainingValue) + "% remaining")
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
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.viewMode === "limits" && root.providers.length > 1) {
          root.providerCursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0) {
          var target = panelFlick.contentY + dy * Style.space(56)
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
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.spacing.xxl

          Ui.PanelHero {
            visible: root.viewMode === "limits" && !!root.provider
            width: parent.width
            title: root.provider ? root.provider.name : "Model Usage"
            meta: root.heroMeta(root.provider)
            detail: backend.loading ? "REFRESHING" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            trailingControl: Component {
              Row {
                spacing: Style.spacing.xs

                Ui.PanelActionButton {
                  visible: root.accountTooltip(root.provider) !== ""
                  iconText: "?"
                  tooltipText: root.accountTooltip(root.provider)
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  bordered: true
                }

                Ui.PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: "Refresh usage"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !backend.loading
                  onClicked: root.refreshNow()
                }
              }
            }

            iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display

                Image {
                  id: providerImage
                  anchors.fill: parent
                  source: root.iconUrl(root.provider)
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                }

                Text {
                  anchors.centerIn: parent
                  visible: providerImage.status !== Image.Ready
                  text: UsageLogic.providerMark(root.provider ? root.provider.id : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                  font.bold: true
                }
              }
            }
          }

          Ui.PanelHero {
            visible: root.viewMode === "costs"
            width: parent.width
            title: "Estimated Costs"
            meta: "API-equivalent value · local transcripts"
            detail: costBackend.loading ? "SCANNING" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            trailingControl: Component {
              Ui.PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh estimated costs"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !costBackend.loading
                onClicked: root.refreshNow()
              }
            }

            iconComponent: Component {
              Text {
                text: "$"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
              }
            }
          }

          Ui.ButtonGroup {
            id: viewSwitch
            width: parent.width
            options: root.viewOptions
            value: root.viewMode
            foreground: root.foreground
            background: root.surface
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(value) { root.viewMode = value }
          }

          Ui.ButtonGroup {
            id: providerSwitch
            visible: root.viewMode === "limits" && root.providers.length > 1
            options: root.providerOptions
            value: root.provider ? String(root.provider.id) : ""
            cursorIndex: root.providerCursorActive ? root.providerIndex : -1
            foreground: root.foreground
            background: root.surface
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(value) {
              root.providerCursorActive = true
              root.selectProviderId(value)
            }
            onHovered: function(index, isHovered) {
              root.handleProviderTabHover(isHovered)
            }
          }

          Text {
            visible: root.viewMode === "limits" && root.providers.length === 0
            width: parent.width
            topPadding: Style.spacing.huge
            bottomPadding: Style.spacing.huge
            text: backend.loading
              ? "Loading AI subscription usage…"
              : "No providers are enabled. Choose Claude, Codex, or Kimi in the widget settings."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Ui.BorderSurface {
            id: errorCard
            visible: root.viewMode === "limits" && !!root.provider && root.provider.status !== "ok"
            width: parent.width
            implicitHeight: errorColumn.implicitHeight + errorCard.contentTopInset + errorCard.contentBottomInset
            color: root.alpha(root.urgent, 0.09)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.4), Style.spacing.hairline)
            padding: Style.spacing.xxl
            radius: Style.cornerRadius

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
            visible: root.viewMode === "limits" && !!root.provider && root.provider.status === "ok"
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
            visible: root.viewMode === "limits" && !!root.provider && root.provider.status === "ok"
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
              }
            }
          }

          Column {
            id: creditsSection
            visible: root.viewMode === "limits" && !!root.provider
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
            }
          }

          Ui.PanelSeparator {
            visible: root.viewMode === "limits" && history.visible
            foreground: root.foreground
          }

          UsageHistory {
            id: history
            visible: root.viewMode === "limits" && !!root.provider && root.provider.history
              && ((UsageLogic.isListLike(root.provider.history.h24) && root.provider.history.h24.length > 0)
                || (UsageLogic.isListLike(root.provider.history.d7) && root.provider.history.d7.length > 0))
            width: parent.width
            history: root.provider ? root.provider.history : ({ h24: [], d7: [] })
            mode: root.historyMode
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModeChanged: root.historyMode = mode
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
            onPeriodRequested: function(days) { costBackend.selectPeriod(days) }
          }

          Ui.PanelSeparator { foreground: root.foreground }

          Item {
            width: parent.width
            implicitHeight: Math.max(footerLeft.implicitHeight, footerRight.implicitHeight)

            Text {
              id: footerLeft
              anchors.left: parent.left
              anchors.right: footerRight.left
              anchors.rightMargin: Style.spacing.controlGap
              text: root.footerLeft()
              color: (root.viewMode === "costs" ? costBackend.fetchError : backend.fetchError) !== ""
                ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              id: footerRight
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

  component LimitCard: Ui.BorderSurface {
    id: limitCard
    property var window: null
    readonly property string severity: root.windowSeverity(window)
    readonly property bool stressed: severity === "warning" || severity === "critical"

    implicitHeight: limitContent.implicitHeight + contentTopInset + contentBottomInset
    color: severity === "critical"
      ? root.alpha(root.urgent, 0.09)
      : Style.normalFillFor(root.foreground, Color.accent, root.urgent)
    borderSpec: stressed
      ? Border.flat(root.alpha(root.urgent, severity === "critical" ? 0.45 : 0.28), Style.spacing.hairline)
      : Border.controlSpec("normal", root.foreground, Color.accent, root.urgent)
    padding: Style.spacing.xxl
    radius: Style.cornerRadius

    Column {
      id: limitContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: limitCard.contentLeftInset
      anchors.rightMargin: limitCard.contentRightInset
      anchors.topMargin: limitCard.contentTopInset
      spacing: Style.spacing.md

      Item {
        width: parent.width
        implicitHeight: Math.max(limitLabel.implicitHeight, limitPercent.implicitHeight)

        Text {
          id: limitLabel
          anchors.left: parent.left
          anchors.right: limitPercent.left
          anchors.rightMargin: Style.spacing.controlGap
          anchors.verticalCenter: parent.verticalCenter
          text: limitCard.window ? String(limitCard.window.label || "Usage limit") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          id: limitPercent
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: limitCard.window && isFinite(Number(limitCard.window.remaining))
            ? Math.round(Number(limitCard.window.remaining)) + "% left" : "—"
          color: limitCard.stressed ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: limitCard.stressed
        }
      }

      BlockMeter {
        width: parent.width
        value: limitCard.window ? Number(limitCard.window.remaining) / 100 : 0
        fillColor: limitCard.stressed ? root.urgent : root.foreground
        trackColor: root.alpha(root.foreground, 0.14)
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: root.resetText(limitCard.window)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: limitCard.window ? String(limitCard.window.detail || "") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component CreditsCard: Ui.BorderSurface {
    id: creditsCard
    property var credits: null
    readonly property bool hasMeter: !!credits
      && credits.used !== null && credits.used !== undefined
      && credits.limit !== null && credits.limit !== undefined
      && Number(credits.limit) > 0

    implicitHeight: creditsContent.implicitHeight + contentTopInset + contentBottomInset
    color: Style.normalFillFor(root.foreground, Color.accent, root.urgent)
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent, root.urgent)
    padding: Style.spacing.xxl
    radius: Style.cornerRadius

    Column {
      id: creditsContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: creditsCard.contentLeftInset
      anchors.rightMargin: creditsCard.contentRightInset
      anchors.topMargin: creditsCard.contentTopInset
      spacing: Style.spacing.md

      Text {
        width: parent.width
        text: root.creditsPrimary(creditsCard.credits)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        visible: creditsCard.hasMeter
        width: parent.width
        text: creditsCard.hasMeter
          ? "MONTHLY ALLOWANCE · "
            + Math.round(Number(creditsCard.credits.used) / Number(creditsCard.credits.limit) * 100)
            + "% USED"
          : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.capitalization: Font.AllUppercase
        elide: Text.ElideRight
      }

      BlockMeter {
        visible: creditsCard.hasMeter
        width: parent.width
        value: creditsCard.hasMeter
          ? Number(creditsCard.credits.used) / Number(creditsCard.credits.limit) : 0
        fillColor: root.foreground
        trackColor: root.alpha(root.foreground, 0.14)
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: root.creditsDetail(creditsCard.credits)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
