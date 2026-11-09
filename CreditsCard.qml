import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// Provider credits or extra usage. The meter fills with what is left.
Ui.BorderSurface {
  id: root

  property var credits: null
  property int warningThreshold: 25
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family
  property real cardRadius: 0

  readonly property color dim: UsageLogic.dimColor(foreground)
  readonly property var meter: UsageLogic.creditsMeter(credits)
  readonly property bool stressed: meter !== null && meter.remaining <= warningThreshold

  implicitHeight: content.implicitHeight + contentTopInset + contentBottomInset
  color: Style.normalFillFor(foreground, Commons.Color.accent, urgent)
  borderSpec: Border.controlSpec("normal", foreground, Commons.Color.accent, urgent)
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

    Text {
      width: parent.width
      text: UsageLogic.creditsPrimary(root.credits)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      objectName: "creditsMeterLabel"
      visible: root.meter !== null
      width: parent.width
      text: root.meter ? root.meter.label : ""
      color: root.stressed ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.capitalization: Font.AllUppercase
      elide: Text.ElideRight
    }

    BlockMeter {
      visible: root.meter !== null
      width: parent.width
      value: root.meter ? root.meter.fraction : 0
      fillColor: root.stressed ? root.urgent : root.foreground
      trackColor: UsageLogic.alpha(root.foreground, 0.14)
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: UsageLogic.creditsDetail(root.credits)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
