pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// One line in a provider card: a name (with an optional session count at the
// edge of the name column), the remaining-quota meter, the percentage left,
// the reset countdown and, in its own trailing column, a banked-reset button.
// The name column is shared by every row in the panel, so meters line up
// across accounts and providers. Details live in the tooltip, and in a caption
// line while Details is open.
Item {
  id: root
  objectName: "usageRow"

  property string label: ""
  // A dim plan tag after the name, when accounts in one card differ.
  property string tag: ""
  // Limit names wrap once so similar limits stay distinct; account names
  // (emails) stay on one line and shorten in the middle, keeping the domain.
  property bool wrapLabel: true
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
  // Session count: -1 hides it (unknown or not tracked).
  property int sessions: -1
  // Banked-reset button: shown only with resets to apply. Every row in the
  // panel reserves the column when any account has one, so columns align.
  property int resetCount: -1
  property bool resetEnabled: false
  property bool reserveResetSlot: false
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
    + (sessionCount.visible ? Style.spacing.md + sessionCount.implicitWidth : 0)
  readonly property real labelCellWidth: Math.min(Math.max(labelWidth, Style.space(40)), Math.round(width * 0.45))
  // The session count keeps its size; the name, then the plan tag, give way.
  readonly property real countWidth: sessionCount.visible ? sessionCount.implicitWidth + Style.spacing.md : 0
  readonly property real nameRoom: Math.max(0, labelCellWidth - indent - countWidth)
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

  PlainToolTip {
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
    id: resetSlotMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: UsageLogic.RESET_ICON + " 9"
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
    height: Math.max(nameText.implicitHeight, percent.implicitHeight, resetLabel.implicitHeight)
      + Style.spacing.xs * 2

    Item {
      id: labelCell
      x: root.indent
      width: root.labelCellWidth - root.indent
      height: parent.height

      Text {
        id: nameText
        objectName: "usageRowLabel"
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, Math.min(implicitWidth,
          root.nameRoom - (root.tag !== "" ? root.tagRoom + Style.spacing.sm : 0)))
        text: (root.sub ? "↳ " : "") + root.label
        textFormat: Text.PlainText
        color: root.stressed ? root.urgent : root.sub ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.sub ? Style.font.caption : Style.font.bodySmall
        // Similar model limits differ at the end ("… · 1 day", "… · Spend"),
        // so a long limit name wraps once rather than losing its ending.
        wrapMode: root.wrapLabel ? Text.WrapAtWordBoundaryOrAnywhere : Text.NoWrap
        maximumLineCount: root.wrapLabel ? 2 : 1
        elide: root.wrapLabel ? Text.ElideRight : Text.ElideMiddle
      }

      Text {
        id: tagText
        objectName: "usageRowTag"
        anchors.left: nameText.right
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        visible: root.tag !== ""
        width: Math.max(0, Math.min(implicitWidth, root.nameRoom - nameText.width - Style.spacing.sm))
        text: root.tag
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // Recent Fusebox sessions, in the same glyph-and-number style as the
      // header icons, at the edge of the name column so counts line up.
      Text {
        id: sessionCount
        objectName: "accountSessionBadge"
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.sessions >= 0
        text: UsageLogic.SESSION_ICON + " " + Math.max(0, root.sessions)
        color: root.sessions > 0 ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Accessible.role: Accessible.StaticText
        Accessible.name: UsageLogic.plural(Math.max(0, root.sessions), "session")
      }
    }

    Item {
      id: valueCell
      anchors.left: parent.left
      anchors.leftMargin: root.labelCellWidth + Style.spacing.controlGap
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom

      // Applying a banked reset is an explicit action: a flat, square button
      // in the last column, highlighted like the panel's other icon buttons.
      Item {
        id: resetSlot
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.reserveResetSlot || root.resetCount > 0 ? Math.ceil(resetSlotMetrics.advanceWidth) + Style.spacing.sm * 2 : 0

        Rectangle {
          id: resetBadge
          objectName: "accountResetBadge"
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: resetLabel.implicitHeight + Style.spacing.xxs * 2
          visible: root.resetCount > 0
          radius: Style.cornerRadius
          color: resetClick.enabled && (resetClick.containsMouse || activeFocus)
            ? Style.hoverFillFor(root.foreground, Commons.Color.accent, root.urgent) : "transparent"
          border.width: activeFocus ? Style.spacing.hairline : 0
          border.color: Commons.Color.accent
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
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: UsageLogic.RESET_ICON + " " + Math.max(0, root.resetCount)
            color: resetClick.enabled && (resetClick.containsMouse || resetBadge.activeFocus)
              ? root.foreground : UsageLogic.alpha(root.foreground, resetClick.enabled ? 0.66 : 0.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        id: messageText
        objectName: "usageRowMessage"
        anchors.left: parent.left
        anchors.right: resetSlot.left
        anchors.rightMargin: resetSlot.width > 0 ? Style.spacing.md : 0
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
        textFormat: Text.PlainText
        anchors.right: resetSlot.left
        anchors.rightMargin: resetSlot.width > 0 ? Style.spacing.sm : 0
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
        textFormat: Text.PlainText
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
