pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// One managed subscription account (Fusebox / CLIProxyAPI): plan, banked
// resets, live sessions, account facts and its limit windows.
Ui.BorderSurface {
  id: root
  objectName: "proxyAccountCard"

  property var account: ({})
  property string accountLabel: ""
  property bool expanded: false
  property bool liveActivity: false
  property var load: null
  property bool resetEnabled: false
  property url iconSource: ""
  property double nowMs: Date.now()
  property bool refreshing: false
  property double minuteMs: Math.floor(nowMs / 60000) * 60000
  property int warningThreshold: 25
  property int criticalThreshold: 10
  property string errorText: ""
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family
  property real cardRadius: 0
  property bool activityExpanded: false

  readonly property color dim: UsageLogic.dimColor(foreground)
  readonly property var windows: UsageLogic.accountWindows(account, expanded, warningThreshold, criticalThreshold)
  readonly property bool healthy: !!account && account.status === "ok"

  signal resetRequested()

  implicitHeight: content.implicitHeight + contentTopInset + contentBottomInset
  color: Style.normalFillFor(foreground, Commons.Color.accent, urgent)
  borderSpec: Border.flat(UsageLogic.alpha(foreground, 0.22), Style.spacing.hairline)
  padding: Style.spacing.xxl
  radius: cardRadius

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: root.contentLeftInset
    anchors.rightMargin: root.contentRightInset
    anchors.topMargin: root.contentTopInset
    spacing: Style.spacing.md

    Item {
      width: parent.width
      implicitHeight: Math.max(logo.height, plan.implicitHeight,
        resetBadge.visible ? resetBadge.implicitHeight : 0,
        sessionBadge.visible ? sessionBadge.implicitHeight : 0)

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
          text: UsageLogic.providerMark(root.account ? root.account.id : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      Text {
        id: plan
        anchors.left: logo.right
        anchors.leftMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - logo.width - Style.spacing.md
          - (resetBadge.visible ? resetBadge.width + Style.spacing.md : 0)
          - (sessionBadge.visible ? sessionBadge.width + Style.spacing.md : 0))
        text: UsageLogic.accountPlanLabel(root.account)
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.WordWrap
      }

      Ui.Button {
        id: sessionBadge
        objectName: "accountSessionBadge"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.liveActivity
        text: UsageLogic.sessionBadgeText(root.load)
        focusable: true
        bordered: true
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xs
        foreground: root.load !== null && root.load.sessions > 0 ? root.foreground : root.dim
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        tooltipText: UsageLogic.sessionDetails(root.load)
        Accessible.name: text + (root.activityExpanded ? ", hide session details" : ", show session details")
        onClicked: root.activityExpanded = !root.activityExpanded
      }

      // An available reset is a bordered button; none available is plain text.
      Rectangle {
        id: resetBadge
        objectName: "accountResetBadge"
        anchors.right: sessionBadge.visible ? sessionBadge.left : parent.right
        anchors.rightMargin: sessionBadge.visible ? Style.spacing.md : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: resetLabel.text !== ""
        implicitWidth: resetLabel.implicitWidth + (resetClick.enabled ? Style.spacing.lg * 2 : 0)
        implicitHeight: resetLabel.implicitHeight + Style.spacing.sm * 2
        radius: height / 2
        color: resetClick.enabled && (resetClick.containsMouse || activeFocus)
          ? UsageLogic.alpha(root.foreground, 0.08) : "transparent"
        border.width: resetClick.enabled ? Style.spacing.hairline : 0
        border.color: UsageLogic.alpha(root.foreground, activeFocus ? 0.6 : 0.28)
        activeFocusOnTab: resetClick.enabled
        Accessible.role: resetClick.enabled ? Accessible.Button : Accessible.StaticText
        Accessible.name: resetLabel.text + (resetClick.enabled ? ": apply a reset" : "")
        Keys.onReturnPressed: resetClick.activate()
        Keys.onSpacePressed: resetClick.activate()

        MouseArea {
          id: resetClick
          objectName: "accountResetAction"
          anchors.fill: parent
          enabled: root.resetEnabled
          hoverEnabled: true
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          function activate() {
            if (enabled) root.resetRequested()
          }
          onClicked: activate()
        }

        Ui.PanelToolTip {
          visible: resetClick.enabled && resetClick.containsMouse
          text: "Apply a banked reset to this account"
          fontFamily: root.fontFamily
        }

        Text {
          id: resetLabel
          objectName: "accountResetLabel"
          anchors.centerIn: parent
          text: UsageLogic.accountResetLabel(root.account)
          color: resetClick.enabled ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Text {
      objectName: "accountName"
      width: parent.width
      text: root.accountLabel
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }

    Repeater {
      model: UsageLogic.accountStatusItems(root.account, root.minuteMs)
      Text {
        required property var modelData
        objectName: "accountStatusItem"
        width: content.width
        text: modelData.text
        textFormat: Text.PlainText
        color: modelData.urgent ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Text {
      objectName: "accountActivityDetails"
      width: parent.width
      visible: root.liveActivity && root.activityExpanded
      text: UsageLogic.sessionDetails(root.load)
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.healthy ? root.windows : []

      Column {
        id: accountWindow
        required property var modelData
        objectName: "proxyAccountWindow"
        readonly property var remaining: UsageLogic.windowRemaining(modelData)
        readonly property string severity: UsageLogic.windowSeverity(modelData, root.warningThreshold, root.criticalThreshold)
        readonly property bool stressed: severity === "warning" || severity === "critical"
        width: content.width
        spacing: Style.spacing.sm
        Accessible.role: Accessible.StaticText
        Accessible.name: String(modelData.label || "Usage limit") + ", "
          + (remaining === null ? "unknown" : Math.round(remaining) + " percent left")

        Item {
          width: parent.width
          implicitHeight: Math.max(windowLabel.implicitHeight, percent.implicitHeight)
          // Long model-specific names wrap, so similar limits stay distinguishable.
          Text {
            id: windowLabel
            objectName: "proxyAccountWindowLabel"
            anchors.left: parent.left
            anchors.right: percent.left
            anchors.rightMargin: Style.spacing.controlGap
            text: UsageLogic.limitLabel(accountWindow.modelData.label)
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: 3
            elide: Text.ElideRight
          }
          Text {
            id: percent
            anchors.right: parent.right
            text: accountWindow.remaining === null ? "—" : Math.round(accountWindow.remaining) + "% left"
            color: accountWindow.stressed ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }
        BlockMeter {
          visible: accountWindow.remaining !== null
          width: parent.width
          value: accountWindow.remaining === null ? 0 : accountWindow.remaining / 100
          fillColor: accountWindow.stressed ? root.urgent : root.foreground
          trackColor: UsageLogic.alpha(root.foreground, 0.14)
        }
        Text {
          width: parent.width
          visible: text !== ""
          text: UsageLogic.resetText(accountWindow.modelData, root.nowMs, root.refreshing)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Text {
          objectName: "proxyAccountWindowDetail"
          width: parent.width
          visible: text !== ""
          text: String(accountWindow.modelData.detail || "")
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: root.account.status === "error" ? root.errorText
        : root.account.stale || !root.healthy ? String(root.account.notice || "Quota unavailable")
        : root.windows.length === 0 ? "No subscription limits reported." : ""
      textFormat: Text.PlainText
      color: root.account.status === "error" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
