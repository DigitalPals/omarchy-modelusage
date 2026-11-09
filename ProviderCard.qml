pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// One provider in Limits. Managed accounts (Fusebox / CLIProxyAPI) get one
// row each under a header naming their shared plan; local CLI providers get
// one row per limit window, their credits, and a collapsible quota history.
Ui.BorderSurface {
  id: root
  objectName: "providerCard"

  property var provider: null
  property bool expanded: false
  property bool liveActivity: false
  // UsageActivityBackend, for per-account session counts.
  property var activity: null
  property bool proxyMode: false
  // False while a reset confirmation is open or running.
  property bool resetAllowed: true
  property bool hideAccountEmails: true
  property bool historyOpen: false
  property string historyMode: "h24"
  property real labelWidth: 0
  property var labelColumn: null
  // Every row reserves the banked-reset column when any account has one.
  property bool reserveResetSlot: false
  property url iconSource: ""
  property double nowMs: Date.now()
  property double minuteMs: Math.floor(nowMs / 60000) * 60000
  property bool refreshing: false
  property int warningThreshold: 25
  property int criticalThreshold: 10
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family
  property real cardRadius: 0

  readonly property color dim: UsageLogic.dimColor(foreground)
  readonly property string providerId: provider ? String(provider.id) : ""
  readonly property var accounts: UsageLogic.listOrEmpty(provider && provider.accounts)
  readonly property bool accountMode: accounts.length > 0
  readonly property bool failed: !accountMode && !!provider && provider.status === "error"
  readonly property bool readable: !accountMode && !!provider && provider.status === "ok"
  readonly property var windows: readable ? UsageLogic.listOrEmpty(provider.windows) : []
  readonly property var credits: readable && provider.credits ? provider.credits : null
  readonly property var creditsMeter: UsageLogic.creditsMeter(credits)
  readonly property bool historyAvailable: UsageLogic.hasQuotaHistory(provider)
  readonly property string title: UsageLogic.providerTitle(provider, accounts)
  readonly property string caption: accountMode ? UsageLogic.accountsCaption(accounts)
    : windows.length > 0 ? "left · resets" : ""
  readonly property string noticeText: failed || !provider ? "" : String(provider.notice || "")
  property alias accountRows: accountRepeater
  property alias windowRows: windowRepeater
  readonly property var historyView: historyLoader.item

  signal resetRequested(var account, string label)
  signal historyToggled(bool open)
  signal rangeRequested(string mode)

  function accountLabel(index) {
    return UsageLogic.accountDisplayName(accounts[index], index + 1, hideAccountEmails)
  }

  implicitHeight: content.implicitHeight + contentTopInset + contentBottomInset
  color: failed ? UsageLogic.alpha(urgent, 0.09) : Style.normalFillFor(foreground, Commons.Color.accent, urgent)
  borderSpec: Border.flat(UsageLogic.alpha(failed ? urgent : foreground, failed ? 0.4 : 0.22), Style.spacing.hairline)
  padding: Style.spacing.xl
  radius: cardRadius
  Accessible.role: Accessible.Grouping
  Accessible.name: title

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: root.contentLeftInset
    anchors.rightMargin: root.contentRightInset
    anchors.topMargin: root.contentTopInset
    spacing: Style.spacing.xxs

    Item {
      id: header
      width: parent.width
      implicitHeight: Math.max(logo.height, titleText.implicitHeight, captionText.implicitHeight)
        + Style.spacing.xs

      Item {
        id: logo
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.body * 1.2
        height: width

        Image {
          id: logoImage
          anchors.fill: parent
          source: root.iconSource
          sourceSize.width: logo.width * 2
          sourceSize.height: logo.height * 2
          fillMode: Image.PreserveAspectFit
        }

        Text {
          anchors.centerIn: parent
          visible: logoImage.status !== Image.Ready
          text: UsageLogic.providerMark(root.providerId)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      Text {
        id: titleText
        objectName: "providerCardTitle"
        anchors.left: logo.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: captionText.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: root.title
        textFormat: Text.PlainText
        color: root.failed ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        id: captionText
        objectName: "providerCardCaption"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.caption
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Managed accounts: one row each.
    Repeater {
      id: accountRepeater
      model: root.accounts

      AccountRow {
        required property var modelData
        required property int index
        width: content.width
        account: modelData
        accountLabel: root.accountLabel(index)
        planTag: UsageLogic.accountPlanTag(modelData, root.title)
        expanded: root.expanded
        liveActivity: root.liveActivity
        load: UsageLogic.accountLoad(modelData, root.activity)
        resetEnabled: root.proxyMode && UsageLogic.accountResetCount(modelData) > 0 && root.resetAllowed
        reserveResetSlot: root.reserveResetSlot
        labelWidth: root.labelWidth
        labelColumn: root.labelColumn
        nowMs: root.nowMs
        minuteMs: root.minuteMs
        refreshing: root.refreshing
        warningThreshold: root.warningThreshold
        criticalThreshold: root.criticalThreshold
        foreground: root.foreground
        urgent: root.urgent
        fontFamily: root.fontFamily
        onResetRequested: root.resetRequested(modelData, accountLabel)
      }
    }

    // A provider without accounts that failed: what went wrong and how to fix it.
    Text {
      objectName: "providerCardError"
      width: parent.width
      visible: root.failed
      topPadding: Style.spacing.xxs
      text: UsageLogic.errorTitle(root.provider) + "\n" + UsageLogic.errorBody(root.provider)
      textFormat: Text.PlainText
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      objectName: "providerCardNotice"
      width: parent.width
      visible: text !== "" && !root.accountMode
      text: root.noticeText
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // Local CLI providers: one row per limit window.
    Repeater {
      id: windowRepeater
      model: root.windows

      UsageRow {
        required property var modelData
        objectName: "providerWindowRow"
        width: content.width
        label: UsageLogic.limitLabel(UsageLogic.shortLimitLabel(modelData.label))
        window: modelData
        stale: root.provider.stale === true
        tooltipText: UsageLogic.windowSummary(modelData, root.nowMs, root.refreshing)
          + (root.provider.stale === true ? "\n" + UsageLogic.staleExplanation(root.provider, root.provider) : "")
        detailText: UsageLogic.windowFacts(modelData, root.minuteMs, root.refreshing)
        showDetail: root.expanded
        reserveResetSlot: root.reserveResetSlot
        labelWidth: root.labelWidth
        labelColumn: root.labelColumn
        nowMs: root.nowMs
        refreshing: root.refreshing
        warningThreshold: root.warningThreshold
        criticalThreshold: root.criticalThreshold
        foreground: root.foreground
        urgent: root.urgent
        fontFamily: root.fontFamily
      }
    }

    UsageRow {
      objectName: "providerCreditsRow"
      visible: root.credits !== null
      width: content.width
      label: root.credits ? String(root.credits.label || "Credits") : ""
      meterValue: root.creditsMeter ? root.creditsMeter.remaining : -1
      message: root.creditsMeter ? "" : UsageLogic.creditsPrimary(root.credits)
      messageDim: false
      tooltipText: root.credits ? [root.creditsMeter ? root.creditsMeter.label : "",
        UsageLogic.creditsPrimary(root.credits), UsageLogic.creditsDetail(root.credits)]
        .filter(function(line) { return line !== "" }).join("\n") : ""
      detailText: root.credits ? [root.creditsMeter ? UsageLogic.creditsPrimary(root.credits) : "",
        UsageLogic.creditsDetail(root.credits)].filter(function(line) { return line !== "" }).join(" · ") : ""
      showDetail: root.expanded
      reserveResetSlot: root.reserveResetSlot
      labelWidth: root.labelWidth
      labelColumn: root.labelColumn
      nowMs: root.nowMs
      warningThreshold: root.warningThreshold
      criticalThreshold: root.criticalThreshold
      foreground: root.foreground
      urgent: root.urgent
      fontFamily: root.fontFamily
    }

    UsageDisclosure {
      objectName: "quotaHistoryToggle"
      visible: root.historyAvailable
      text: "Quota history"
      checked: root.historyOpen
      leftPadding: 0
      foreground: root.dim
      fontFamily: root.fontFamily
      onToggled: root.historyToggled(checked)
    }

    Loader {
      id: historyLoader
      width: parent.width
      active: root.historyAvailable && root.historyOpen
      visible: active

      sourceComponent: UsageHistory {
        objectName: "quotaHistory"
        width: historyLoader.width
        history: root.provider.history
        mode: root.historyMode
        foreground: root.foreground
        fontFamily: root.fontFamily
        onRangeRequested: function(mode) { root.rangeRequested(mode) }
      }
    }
  }
}
