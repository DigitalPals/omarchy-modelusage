pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Column {
  id: root
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property string loadError: ""
  signal revealRequested(var item)
  signal edited()
  spacing: Style.spacing.lg

  function begin(raw) {
    prices.clear()
    loadError = ""
    try {
      var rows = UsageLogic.decodeCostPrices(raw)
      for (var i = 0; i < rows.length; i++) {
        var row = Object.assign({}, rows[i], { modelId: rows[i].model })
        delete row.model
        prices.append(row)
      }
    } catch (error) { loadError = String(error.message || error) }
  }

  function serialize() {
    if (loadError !== "") throw new Error(loadError)
    var rows = []
    for (var i = 0; i < prices.count; i++) {
      var row = prices.get(i)
      rows.push(Object.assign({}, row, { model: row.modelId }))
    }
    return UsageLogic.encodeCostPrices(rows)
  }

  function addPrice() {
    if (prices.count >= 128 || loadError !== "") return
    prices.append({ modelId: "", inputCostPerMillionTokens: "", outputCostPerMillionTokens: "",
      cacheReadCostPerMillionTokens: "", cacheWriteCostPerMillionTokens: "" })
    edited()
  }

  ListModel { id: prices }

  Label { text: "Custom model prices" }
  Label {
    text: "USD per million tokens. Copy the exact model ID from Costs, including its provider and any [variant]. Custom prices override public and provider-reported costs for that ID. Remove a row to restore automatic pricing."
    opacity: 0.7
    font.pixelSize: Style.font.caption
  }
  Label { visible: root.loadError !== ""; text: root.loadError; color: root.urgent }
  Ui.Button {
    visible: root.loadError !== ""
    text: "Remove invalid custom prices"
    foreground: root.foreground
    fontFamily: root.fontFamily
    bordered: true
    focusable: true
    onClicked: { root.begin("{}"); root.edited() }
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }

  Repeater {
    model: prices
    delegate: Column {
      id: priceRow
      required property int index
      required property string modelId
      required property string inputCostPerMillionTokens
      required property string outputCostPerMillionTokens
      required property string cacheReadCostPerMillionTokens
      required property string cacheWriteCostPerMillionTokens
      width: root.width
      spacing: Style.spacing.md

      Label { text: "Model ID" }
      Ui.TextField {
        objectName: "costModel-" + priceRow.index
        width: parent.width
        text: priceRow.modelId
        maximumLength: 256
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        selectByMouse: true
        Accessible.name: "Custom price model ID"
        onTextEdited: { prices.setProperty(priceRow.index, "modelId", text); root.edited() }
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      }
      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.spacing.lg
        rowSpacing: Style.spacing.md
        Repeater {
          model: [
            { key: "inputCostPerMillionTokens", label: "Input" },
            { key: "outputCostPerMillionTokens", label: "Output" },
            { key: "cacheReadCostPerMillionTokens", label: "Cache read (optional)" },
            { key: "cacheWriteCostPerMillionTokens", label: "Cache write (optional)" }
          ]
          delegate: Column {
            id: rateField
            required property var modelData
            width: (priceRow.width - Style.spacing.lg) / 2
            spacing: Style.spacing.sm
            Label { text: rateField.modelData.label }
            Ui.TextField {
              objectName: "costRate-" + priceRow.index + "-" + rateField.modelData.key
              width: parent.width
              text: priceRow[rateField.modelData.key]
              maximumLength: 32
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              selectByMouse: true
              inputMethodHints: Qt.ImhFormattedNumbersOnly
              Accessible.name: rateField.modelData.label + " USD per million tokens"
              onTextEdited: { prices.setProperty(priceRow.index, rateField.modelData.key, text); root.edited() }
              onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
            }
          }
        }
      }
      Ui.Button {
        text: "Remove price"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        focusable: true
        onClicked: { prices.remove(priceRow.index); root.edited() }
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      }
    }
  }
  Label {
    text: prices.count === 0 ? "Automatic prices are in use. Kimi remains token-only without a known historical model."
      : "Blank cache prices use the input price. Enter 0 explicitly for free tokens. Kimi remains token-only."
    opacity: 0.7
    font.pixelSize: Style.font.caption
  }
  Ui.Button {
    objectName: "addCostPriceButton"
    text: "Add model price"
    enabled: prices.count < 128 && root.loadError === ""
    foreground: root.foreground
    fontFamily: root.fontFamily
    bordered: true
    focusable: true
    onClicked: root.addPrice()
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }

  component Label: Text {
    width: parent.width
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
