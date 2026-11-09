pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Commons as Commons
import "UsageLogic.js" as UsageLogic

// One managed subscription account (Fusebox / CLIProxyAPI) in its provider
// card: a row for its main allowance, indented rows for tighter or (with
// Details open) all other limits, and urgent account facts such as cooldowns.
Column {
  id: root
  objectName: "accountRow"

  property var account: ({})
  property string accountLabel: ""
  property string planTag: ""
  property bool expanded: false
  property bool liveActivity: false
  property var load: null
  property bool resetEnabled: false
  property real labelWidth: 0
  property var labelColumn: null
  property double nowMs: Date.now()
  property double minuteMs: Math.floor(nowMs / 60000) * 60000
  property bool refreshing: false
  property int warningThreshold: 25
  property int criticalThreshold: 10
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family

  readonly property bool healthy: !!account && account.status === "ok"
  // The limits this account shows; the first main allowance is the row meter.
  readonly property var windows: UsageLogic.accountWindows(account, expanded, warningThreshold, criticalThreshold)
  readonly property var rowWindows: UsageLogic.accountRowWindows(account, expanded, warningThreshold, criticalThreshold)
  readonly property var urgentFacts: UsageLogic.urgentAccountFacts(account, minuteMs)
  readonly property int resetCount: {
    if (UsageLogic.accountResetLabel(account) === "") return -1
    return Number(account.credits.resetCreditsAvailable)
  }
  property alias mainRow: mainRow

  signal resetRequested()

  spacing: 0

  UsageRow {
    id: mainRow
    objectName: "accountMainRow"
    width: root.width
    label: root.accountLabel
    tag: root.planTag
    window: root.healthy ? root.rowWindows.main : null
    stale: root.account.stale === true
    message: !root.healthy ? UsageLogic.accountIssue(root.account)
      : root.rowWindows.main === null ? "No limits reported" : ""
    messageUrgent: root.account.status === "error"
    tooltipText: UsageLogic.accountDetails(root.account, {
      label: root.accountLabel, nowMs: root.nowMs, minuteMs: root.minuteMs, refreshing: root.refreshing,
      liveActivity: root.liveActivity, load: root.load, resetEnabled: root.resetEnabled })
    detailText: UsageLogic.accountFacts(root.account, root.healthy ? root.rowWindows.main : null,
      root.minuteMs, root.refreshing)
    showDetail: root.expanded
    sessions: root.liveActivity && root.load !== null ? Number(root.load.sessions) : -1
    resetCount: root.resetCount
    resetEnabled: root.resetEnabled
    labelWidth: root.labelWidth
    labelColumn: root.labelColumn
    nowMs: root.nowMs
    refreshing: root.refreshing
    warningThreshold: root.warningThreshold
    criticalThreshold: root.criticalThreshold
    foreground: root.foreground
    urgent: root.urgent
    fontFamily: root.fontFamily
    onResetRequested: root.resetRequested()
  }

  Repeater {
    model: root.healthy ? root.rowWindows.extra : []

    UsageRow {
      required property var modelData
      objectName: "accountWindowRow"
      width: root.width
      sub: true
      label: UsageLogic.limitLabel(UsageLogic.shortLimitLabel(modelData.label))
      window: modelData
      stale: root.account.stale === true
      tooltipText: UsageLogic.windowSummary(modelData, root.nowMs, root.refreshing)
      detailText: UsageLogic.windowFacts(modelData, root.minuteMs, root.refreshing)
      showDetail: root.expanded
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

  Repeater {
    model: root.urgentFacts

    Text {
      required property var modelData
      objectName: "accountUrgentFact"
      x: Style.spacing.xl
      width: root.width - x
      bottomPadding: Style.spacing.xxs
      text: modelData
      textFormat: Text.PlainText
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
