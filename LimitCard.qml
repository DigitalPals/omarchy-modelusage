import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// One provider limit window: label, remaining percentage, meter and reset.
Ui.BorderSurface {
  id: root

  property var window: null
  property int warningThreshold: 25
  property int criticalThreshold: 10
  property double nowMs: Date.now()
  property bool refreshing: false
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family
  property real cardRadius: 0

  readonly property color dim: UsageLogic.dimColor(foreground)
  readonly property var remaining: UsageLogic.windowRemaining(window)
  readonly property string severity: UsageLogic.windowSeverity(window, warningThreshold, criticalThreshold)
  readonly property bool stressed: severity === "warning" || severity === "critical"

  implicitHeight: content.implicitHeight + contentTopInset + contentBottomInset
  color: severity === "critical"
    ? UsageLogic.alpha(urgent, 0.09)
    : Style.normalFillFor(foreground, Commons.Color.accent, urgent)
  borderSpec: stressed
    ? Border.flat(UsageLogic.alpha(urgent, severity === "critical" ? 0.45 : 0.28), Style.spacing.hairline)
    : Border.controlSpec("normal", foreground, Commons.Color.accent, urgent)
  padding: Style.spacing.xxl
  radius: cardRadius
  Accessible.role: Accessible.StaticText
  Accessible.name: (window ? String(window.label || "Usage limit") : "")
    + ", " + (remaining === null ? "unknown" : Math.round(remaining) + " percent left")

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
      implicitHeight: Math.max(label.implicitHeight, percent.implicitHeight)

      // Long model-specific names wrap, so similar limits stay distinguishable.
      Text {
        id: label
        objectName: "limitLabel"
        anchors.left: parent.left
        anchors.right: percent.left
        anchors.rightMargin: Style.spacing.controlGap
        anchors.top: parent.top
        text: root.window ? UsageLogic.limitLabel(root.window.label) : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        maximumLineCount: 3
        elide: Text.ElideRight
      }

      Text {
        id: percent
        anchors.right: parent.right
        anchors.top: parent.top
        text: root.remaining === null ? "—" : Math.round(root.remaining) + "% left"
        color: root.stressed ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: root.stressed
      }
    }

    BlockMeter {
      visible: root.remaining !== null
      width: parent.width
      value: root.remaining === null ? 0 : root.remaining / 100
      fillColor: root.stressed ? root.urgent : root.foreground
      trackColor: UsageLogic.alpha(root.foreground, 0.14)
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: UsageLogic.resetText(root.window, root.nowMs, root.refreshing)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: root.window ? String(root.window.detail || "") : ""
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
