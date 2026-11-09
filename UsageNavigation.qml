pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Commons as Commons
import "UsageLogic.js" as UsageLogic

// Limits / Costs tabs. Limits shows every provider at once, so there is no
// provider menu.
Item {
  id: root

  property string viewMode: "limits"
  property var viewOptions: []
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  signal viewRequested(string value)

  implicitHeight: Style.spacing.controlHeight + Style.spacing.sm

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.spacing.hairline
    color: UsageLogic.alpha(root.foreground, 0.14)
  }

  UsageTabs {
    id: tabs
    objectName: "usageViewTabs"
    anchors.left: parent.left
    height: parent.height
    width: Math.min(implicitWidth, root.width)
    options: root.viewOptions
    value: root.viewMode
    foreground: root.foreground
    fontFamily: root.fontFamily
    onChanged: function(value) { root.viewRequested(value) }
  }
}
