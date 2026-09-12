pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

Item {
  id: root

  property string viewMode: "limits"
  property var viewOptions: []
  property var providerOptions: []
  property string providerId: ""
  property color foreground: Color.foreground
  property color surface: Color.popups.background
  property string fontFamily: Style.font.family
  readonly property bool menuOpen: providerMenu.popup.visible
  readonly property bool providerVisible: viewMode === "limits" && providerOptions.length > 1

  signal viewRequested(string value)
  signal providerRequested(string value)
  signal menuClosed()

  function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity) }

  function openProviderMenu() {
    if (providerVisible) providerMenu.popup.open()
  }
  function closeProviderMenu() { providerMenu.popup.close() }

  onProviderVisibleChanged: if (!providerVisible) closeProviderMenu()
  onVisibleChanged: if (!visible) closeProviderMenu()

  implicitHeight: Style.spacing.controlHeight + Style.spacing.sm

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.spacing.hairline
    color: root.alpha(root.foreground, 0.14)
  }

  Controls.TabBar {
    id: tabs
    objectName: "usageViewTabs"
    anchors.left: parent.left
    height: parent.height
    width: Math.min(implicitWidth, root.width * 0.55)
    spacing: Style.spacing.md
    currentIndex: root.viewMode === "costs" ? 1 : 0
    background: Item {}
    onCurrentIndexChanged: {
      if ((root.viewMode === "limits" || root.viewMode === "costs")
          && currentIndex >= 0 && currentIndex < root.viewOptions.length)
        root.viewRequested(root.viewOptions[currentIndex].value)
    }

    Repeater {
      model: root.viewOptions

      Controls.TabButton {
        id: viewTab
        required property var modelData
        text: modelData.label
        width: implicitWidth
        height: tabs.height
        leftPadding: Style.spacing.md
        rightPadding: Style.spacing.md
        topPadding: Style.spacing.sm
        bottomPadding: Style.spacing.md
        Accessible.name: text

        contentItem: Text {
          text: viewTab.text
          color: viewTab.checked ? Color.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          // Reserve bold label widths so changing tabs doesn't move controls.
          font.weight: Font.DemiBold
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
          color: viewTab.hovered || viewTab.visualFocus
            ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
          border.width: viewTab.visualFocus ? Style.spacing.hairline : 0
          border.color: Color.accent

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(2)
            visible: viewTab.checked
            color: Color.accent
          }
        }
      }
    }
  }

  Controls.ComboBox {
    id: providerMenu
    objectName: "usageProviderMenu"
    visible: root.providerVisible
    anchors.right: parent.right
    height: Style.spacing.controlHeight
    width: Math.min(implicitWidth, Math.max(0, root.width - tabs.width - Style.spacing.md))
    implicitWidth: providerLabel.implicitWidth + leftPadding + rightPadding
    leftPadding: Style.spacing.md
    rightPadding: chevron.width + Style.spacing.lg
    model: root.providerOptions
    textRole: "label"
    valueRole: "value"
    currentIndex: {
      for (var i = 0; i < root.providerOptions.length; i++)
        if (root.providerOptions[i].value === root.providerId) return i
      return -1
    }
    displayText: root.providerId === "codex" ? "Codex"
      : root.providerId === "claude" ? "Claude" : currentText
    Accessible.name: "Provider: " + currentText
    onActivated: root.providerRequested(String(currentValue))

    contentItem: Text {
      id: providerLabel
      text: providerMenu.displayText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }

    indicator: Text {
      id: chevron
      x: providerMenu.width - width - Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: providerMenu.popup.visible ? "▴" : "▾"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    background: Rectangle {
      radius: Style.space(4)
      color: providerMenu.hovered || providerMenu.visualFocus || root.menuOpen
        ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
      border.width: providerMenu.visualFocus ? Style.spacing.hairline : 0
      border.color: Color.accent
    }

    popup: Controls.Popup {
      x: providerMenu.width - width
      y: providerMenu.height + Style.spacing.sm
      width: Math.min(root.width, Math.max(providerMenu.width, Style.space(200)))
      implicitHeight: Math.min(contentItem.implicitHeight + padding * 2,
        Style.spacing.popupRowHeight * 6 + padding * 2)
      padding: Style.spacing.sm
      focus: true
      closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutsideParent
      onOpened: {
        providerList.currentIndex = Math.max(0, providerMenu.currentIndex)
        providerList.forceActiveFocus()
      }
      onClosed: root.menuClosed()

      background: Ui.BorderSurface {
        color: root.surface
        borderSpec: Border.flat(root.alpha(root.foreground, 0.25), Style.spacing.hairline)
        radius: Style.space(6)
      }

      contentItem: ListView {
        id: providerList
        clip: true
        implicitHeight: contentHeight
        model: providerMenu.popup.visible ? providerMenu.delegateModel : null
        boundsBehavior: Flickable.StopAtBounds
        Controls.ScrollBar.vertical: Controls.ScrollBar {}

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Down || event.text === "j") {
            currentIndex = Math.min(count - 1, currentIndex + 1)
          } else if (event.key === Qt.Key_Up || event.text === "k") {
            currentIndex = Math.max(0, currentIndex - 1)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
              || event.key === Qt.Key_Space) {
            if (currentIndex >= 0 && currentIndex < root.providerOptions.length)
              root.providerRequested(root.providerOptions[currentIndex].value)
            providerMenu.popup.close()
          } else if (event.key === Qt.Key_Escape) {
            providerMenu.popup.close()
          } else {
            return
          }
          event.accepted = true
        }
      }
    }

    delegate: Controls.ItemDelegate {
      id: providerOption
      required property var modelData
      required property int index
      width: providerMenu.popup.availableWidth
      height: Style.spacing.popupRowHeight
      highlighted: providerList.currentIndex === index
      onHoveredChanged: if (hovered) providerList.currentIndex = index
      text: modelData.label
      Accessible.name: text
      contentItem: Text {
        text: providerOption.text
        color: providerOption.modelData.value === root.providerId ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: providerOption.modelData.value === root.providerId
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }
      background: Rectangle {
        radius: Style.space(4)
        color: providerOption.highlighted
          ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
      }
    }
  }
}
