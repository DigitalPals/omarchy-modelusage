pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// One line in a provider card: a name (with optional session and banked-reset
// pills), the remaining-quota meter, the percentage left and the reset
// countdown. The name column is shared by every row in the panel, so meters
// line up across accounts and providers. Details live in the tooltip, and in
// a caption line while Details is open.
Item {
  id: root
  objectName: "usageRow"

  property string label: ""
  // A dim plan tag after the name, when accounts in one card differ.
  property string tag: ""
  // An indented row for another limit of the account above.
  property bool sub: false
  property var window: null
  // Credits have a meter but no window: 0–100, or -1 for none.
  property real meterValue: -1
  property bool stale: false
  // Shown instead of the meter, e.g. "Sign-in expired" or a credit balance.
  property string message: ""
  property bool messageUrgent: false
  property bool messageDim: true
  property string tooltipText: ""
  property string detailText: ""
  property bool showDetail: false
  // Sessions pill: -1 hides it (unknown or not tracked).
  property int sessions: -1
  // Banked-reset pill: shown only with resets to apply.
  property int resetCount: -1
  property bool resetEnabled: false
  property real labelWidth: 0
  // Shared label column (Panel.qml): every row reports its natural width.
  property var labelColumn: null
  property double nowMs: Date.now()
  property bool refreshing: false
  property int warningThreshold: 25
  property int criticalThreshold: 10
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family

  readonly property color dim: UsageLogic.dimColor(foreground)
  readonly property var remaining: window ? UsageLogic.windowRemaining(window)
    : meterValue >= 0 ? meterValue : null
  readonly property string severity: UsageLogic.windowSeverity(window || { remaining: remaining },
    warningThreshold, criticalThreshold)
  readonly property bool stressed: severity === "warning" || severity === "critical"
  readonly property string percentText: window ? UsageLogic.remainingText(window, stale)
    : remaining === null ? "" : Math.round(remaining) + "%"
  readonly property string resetText: UsageLogic.resetShort(window, nowMs)
  readonly property real indent: sub ? Style.spacing.xl : 0
  // Independent of labelWidth, so measuring it cannot loop.
  readonly property real naturalLabelWidth: indent + nameText.implicitWidth
    + (tagText.visible ? Style.spacing.sm + tagText.implicitWidth : 0)
    + (sessionPill.visible ? Style.spacing.sm + sessionPill.implicitWidth : 0)
    + (resetBadge.visible ? Style.spacing.sm + resetBadge.implicitWidth : 0)
  readonly property real labelCellWidth: Math.min(Math.max(labelWidth, Style.space(40)), Math.round(width * 0.45))
  // Pills keep their size; the name, then the plan tag, give way.
  readonly property real pillsWidth: (sessionPill.visible ? sessionPill.implicitWidth + Style.spacing.sm : 0)
    + (resetBadge.visible ? resetBadge.implicitWidth + Style.spacing.sm : 0)
  readonly property real nameRoom: Math.max(0, labelCellWidth - indent - pillsWidth)
  readonly property real tagRoom: tag === "" ? 0 : Math.min(tagText.implicitWidth, nameRoom * 0.4)
  readonly property bool hovered: hover.hovered

  signal resetRequested()

  implicitHeight: line.height + (detail.visible ? Style.spacing.xxs + detail.implicitHeight : 0)
  Accessible.role: Accessible.StaticText
  Accessible.name: tooltipText !== "" ? tooltipText.replace(/\n/g, "; ")
    : label + ", " + (message !== "" ? message : percentText + " left")

  onNaturalLabelWidthChanged: if (labelColumn) labelColumn.schedule()
  Component.onCompleted: if (labelColumn) labelColumn.add(root)
  Component.onDestruction: if (labelColumn) labelColumn.remove(root)

  HoverHandler { id: hover }

  Ui.PanelToolTip {
    visible: hover.hovered && root.tooltipText !== ""
    text: root.tooltipText
    fontFamily: root.fontFamily
  }

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: -Style.spacing.sm
    anchors.rightMargin: -Style.spacing.sm
    color: hover.hovered && root.tooltipText !== "" ? UsageLogic.alpha(root.foreground, 0.07) : "transparent"
  }

  TextMetrics {
    id: percentMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
    text: "100%?"
  }

  TextMetrics {
    id: resetMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: "23h 59m"
  }

  Item {
    id: line
    width: parent.width
    height: Math.max(nameText.implicitHeight, percent.implicitHeight, sessionPill.implicitHeight,
      resetBadge.implicitHeight) + Style.spacing.xs * 2

    Row {
      id: labelCell
      x: root.indent
      width: root.labelCellWidth - root.indent
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.sm

      Text {
        id: nameText
        objectName: "usageRowLabel"
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, Math.min(implicitWidth,
          root.nameRoom - (root.tag !== "" ? root.tagRoom + labelCell.spacing : 0)))
        text: (root.sub ? "↳ " : "") + root.label
        textFormat: Text.PlainText
        color: root.stressed ? root.urgent : root.sub ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.sub ? Style.font.caption : Style.font.bodySmall
        // Similar model limits differ at the end ("… · 1 day", "… · Spend"),
        // so a long name wraps once rather than losing its ending.
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        id: tagText
        objectName: "usageRowTag"
        anchors.verticalCenter: parent.verticalCenter
        visible: root.tag !== ""
        width: Math.max(0, Math.min(implicitWidth, root.nameRoom - nameText.width - labelCell.spacing))
        text: root.tag
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Rectangle {
        id: sessionPill
        objectName: "accountSessionBadge"
        anchors.verticalCenter: parent.verticalCenter
        visible: root.sessions >= 0
        implicitWidth: Math.max(implicitHeight, sessionText.implicitWidth + Style.spacing.sm * 2)
        implicitHeight: sessionText.implicitHeight + Style.spacing.xxs * 2
        width: implicitWidth
        height: implicitHeight
        radius: height / 2
        color: "transparent"
        border.width: Style.spacing.hairline
        border.color: UsageLogic.alpha(root.foreground, root.sessions > 0 ? 0.45 : 0.22)
        Accessible.role: Accessible.StaticText
        Accessible.name: UsageLogic.plural(Math.max(0, root.sessions), "session")

        Text {
          id: sessionText
          anchors.centerIn: parent
          text: String(Math.max(0, root.sessions))
          color: root.sessions > 0 ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Applying a banked reset is an explicit action, so it is a button.
      Rectangle {
        id: resetBadge
        objectName: "accountResetBadge"
        anchors.verticalCenter: parent.verticalCenter
        visible: root.resetCount > 0
        implicitWidth: resetLabel.implicitWidth + Style.spacing.sm * 2
        implicitHeight: resetLabel.implicitHeight + Style.spacing.xxs * 2
        width: implicitWidth
        height: implicitHeight
        radius: height / 2
        color: resetClick.enabled && (resetClick.containsMouse || activeFocus)
          ? UsageLogic.alpha(root.foreground, 0.1) : "transparent"
        border.width: Style.spacing.hairline
        border.color: UsageLogic.alpha(root.foreground, activeFocus ? 0.7 : resetClick.enabled ? 0.5 : 0.22)
        activeFocusOnTab: resetClick.enabled
        Accessible.role: resetClick.enabled ? Accessible.Button : Accessible.StaticText
        Accessible.name: UsageLogic.plural(Math.max(0, root.resetCount), "banked reset")
          + (resetClick.enabled ? ": apply a reset" : "")
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

        Text {
          id: resetLabel
          objectName: "accountResetLabel"
          anchors.centerIn: parent
          text: "↺ " + Math.max(0, root.resetCount)
          color: resetClick.enabled ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Item {
      id: valueCell
      anchors.left: parent.left
      anchors.leftMargin: root.labelCellWidth + Style.spacing.controlGap
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom

      Text {
        id: messageText
        objectName: "usageRowMessage"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.message !== ""
        text: root.message
        textFormat: Text.PlainText
        color: root.messageUrgent ? root.urgent : root.messageDim ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        id: reset
        objectName: "usageRowReset"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.message === ""
        width: Math.ceil(resetMetrics.advanceWidth)
        horizontalAlignment: Text.AlignRight
        text: root.resetText
        color: root.stressed && root.resetText !== "" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: percent
        objectName: "usageRowPercent"
        anchors.right: reset.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        visible: root.message === ""
        width: Math.ceil(percentMetrics.advanceWidth)
        horizontalAlignment: Text.AlignRight
        text: root.percentText
        color: root.stressed ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: !root.sub
      }

      BlockMeter {
        anchors.left: parent.left
        anchors.right: percent.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        visible: root.message === "" && root.remaining !== null
        implicitHeight: root.sub ? Math.max(Style.space(5), Math.round(Style.spacing.controlHeight * 0.22))
          : Math.max(Style.space(7), Math.round(Style.spacing.controlHeight * 0.28))
        value: root.remaining === null ? 0 : root.remaining / 100
        fillColor: root.stressed ? root.urgent : root.foreground
        trackColor: UsageLogic.alpha(root.foreground, 0.14)
      }
    }
  }

  Text {
    id: detail
    objectName: "usageRowDetail"
    anchors.top: line.bottom
    anchors.topMargin: Style.spacing.xxs
    x: root.indent + (root.sub ? Style.spacing.lg : 0)
    width: parent.width - x
    visible: root.showDetail && root.detailText !== ""
    text: root.detailText
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
