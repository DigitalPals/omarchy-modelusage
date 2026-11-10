import QtQuick
import qs.Commons
import qs.Ui as Ui

// Ui.PanelToolTip whose text is always plain. Tooltips carry limit names,
// account labels and errors from servers, and Omarchy releases before
// PanelToolTip set plain text render it as AutoText, which styles markup and
// loads any image it names.
Ui.PanelToolTip {
  id: root

  contentItem: Text {
    textFormat: Text.PlainText
    text: root.text
    color: root.panelForeground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    // Wraps only once an instance caps the tooltip's width.
    wrapMode: Text.WordWrap
    leftPadding: Border.left(root.panelBorderSpec) + Style.spacing.controlPaddingX
    rightPadding: Border.right(root.panelBorderSpec) + Style.spacing.controlPaddingX
    topPadding: Border.top(root.panelBorderSpec) + Style.spacing.controlPaddingY
    bottomPadding: Border.bottom(root.panelBorderSpec) + Style.spacing.controlPaddingY
  }
}
