pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Item {
  id: root

  property var payload: ({})
  property bool loading: false
  property string errorText: ""
  property int periodDays: 30
  property string metric: "cost"
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color surface: Color.popups.background
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property var totals: payload && payload.totals ? payload.totals : ({})
  readonly property var providers: payload ? UsageLogic.listOrEmpty(payload.providers) : []
  readonly property var models: payload ? UsageLogic.listOrEmpty(payload.models) : []
  readonly property var periods: payload ? UsageLogic.listOrEmpty(payload.periods) : []
  readonly property bool hasResult: !!(payload && payload.generatedAt && periods.length > 0)
  readonly property real chartMaximum: maximumPeriodValue()

  signal periodRequested(int days)

  implicitHeight: content.implicitHeight

  function alpha(color, opacity) {
    return Qt.rgba(color.r, color.g, color.b, opacity)
  }

  function formatUsd(value) {
    if (value === null || value === undefined || !isFinite(Number(value))) return "—"
    var amount = Number(value)
    if (Math.abs(amount) > 0 && Math.abs(amount) < 0.01) return "$" + amount.toFixed(4)
    return "$" + amount.toFixed(2)
  }

  function formatTokens(value) {
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var absolute = Math.abs(amount)
    if (absolute >= 1000000000000) return trimNumber(amount / 1000000000000) + "T"
    if (absolute >= 1000000000) return trimNumber(amount / 1000000000) + "B"
    if (absolute >= 1000000) return trimNumber(amount / 1000000) + "M"
    if (absolute >= 1000) return trimNumber(amount / 1000) + "K"
    return Math.round(amount).toString()
  }

  function trimNumber(value) {
    var absolute = Math.abs(value)
    var digits = absolute >= 100 ? 0 : (absolute >= 10 ? 1 : 2)
    return value.toFixed(digits).replace(/\.0+$/, "")
  }

  function percent(value) {
    var amount = Number(value)
    return isFinite(amount) ? Math.round(amount * 100) + "%" : "0%"
  }

  function priceCoverage(row) {
    if (!row || Number(row.records) <= 0) return 1
    return Math.max(0, Math.min(1, Number(row.pricedRecords || 0) / Number(row.records)))
  }

  function providerColor(providerId) {
    if (providerId === "claude") return "#d97757"
    if (providerId === "kimi") return "#eab308"
    return foreground
  }

  function periodValue(period) {
    if (!period) return 0
    if (metric === "tokens") return Math.max(0, Number(period.totalTokens) || 0)
    return period.costUsd === null ? 0 : Math.max(0, Number(period.costUsd) || 0)
  }

  function maximumPeriodValue() {
    var maximum = 0
    for (var i = 0; i < periods.length; i++) maximum = Math.max(maximum, periodValue(periods[i]))
    return maximum
  }

  function axisLabel(period) {
    if (!period) return ""
    if (periodDays === 1) {
      var date = new Date(String(period.start || ""))
      return isNaN(date.getTime()) ? "" : Qt.formatTime(date, "HH:mm")
    }
    var value = String(period.start || "")
    return value.length >= 10 ? value.substring(5).replace("-", "/") : value
  }

  function primaryValue(row) {
    if (row && (row.status === "missing" || row.status === "failed")) return "—"
    return metric === "tokens" ? formatTokens(row ? row.totalTokens : 0) : formatUsd(row ? row.costUsd : null)
  }

  function providerMetaText(row) {
    if (!row) return ""
    if (row.status === "missing" || row.status === "failed")
      return String(row.message || "Transcript coverage unavailable")
    return formatTokens(row.totalTokens) + " tokens"
      + (Number(row.records || 0) > 0 && Number(row.unpricedRecords || 0) > 0
        ? " · " + percent(priceCoverage(row)) + " priced" : "")
  }

  function summaryDetail() {
    var sessions = Number(totals.sessions || 0)
    var records = Number(totals.records || 0)
    var parts = [sessions + (sessions === 1 ? " session" : " sessions")]
    if (metric === "cost" && records > 0) parts.push(percent(priceCoverage(totals)) + " priced")
    parts.push("local transcripts")
    return parts.join(" · ")
  }

  Column {
    id: content
    width: parent.width
    spacing: Style.spacing.xxl

    Item {
      width: parent.width
      implicitHeight: Math.max(sectionTitle.implicitHeight, periodSwitch.implicitHeight)

      Ui.PanelSectionHeader {
        id: sectionTitle
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "ACTIVITY"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Ui.ButtonGroup {
        id: periodSwitch
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        options: [
          { value: "1", label: "24H" },
          { value: "7", label: "7D" },
          { value: "30", label: "30D" }
        ]
        value: String(root.periodDays)
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        focusable: false
        onChanged: function(value) { root.periodRequested(Number(value)) }
      }
    }

    Ui.ButtonGroup {
      width: parent.width
      options: [
        { value: "cost", label: "API estimate" },
        { value: "tokens", label: "Tokens" }
      ]
      value: root.metric
      foreground: root.foreground
      background: root.surface
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      focusable: false
      onChanged: function(value) { root.metric = value }
    }

    Text {
      visible: root.loading && !root.hasResult
      width: parent.width
      topPadding: Style.spacing.huge
      bottomPadding: Style.spacing.huge
      text: "Scanning local usage transcripts…"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }

    Ui.BorderSurface {
      id: errorCard
      visible: root.errorText !== "" && !root.hasResult
      width: parent.width
      implicitHeight: errorText.implicitHeight + contentTopInset + contentBottomInset
      color: root.alpha(root.urgent, 0.09)
      borderSpec: Border.flat(root.alpha(root.urgent, 0.4), Style.spacing.hairline)
      padding: Style.spacing.xxl
      radius: Style.cornerRadius

      Text {
        id: errorText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: errorCard.contentLeftInset
        anchors.rightMargin: errorCard.contentRightInset
        anchors.topMargin: errorCard.contentTopInset
        text: root.errorText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    Column {
      visible: root.hasResult
      width: parent.width
      spacing: Style.spacing.labelGap

      Text {
        width: parent.width
        text: root.metric === "cost" ? root.formatUsd(root.totals.costUsd)
          : root.formatTokens(root.totals.totalTokens)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
        font.weight: Font.DemiBold
      }

      Text {
        width: parent.width
        text: root.summaryDetail()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        visible: root.metric === "cost"
        width: parent.width
        text: "API-equivalent estimate · not subscription spend"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
        wrapMode: Text.WordWrap
      }
    }

    Column {
      visible: root.hasResult
      width: parent.width
      spacing: Style.spacing.lg

      Ui.PanelSectionHeader {
        text: root.periodDays === 1 ? "HOURLY" : "DAILY"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Row {
        id: chart
        width: parent.width
        height: Style.space(82)
        spacing: Style.spacing.xxs

        Repeater {
          model: root.periods

          delegate: Item {
            id: bucket
            required property var modelData
            required property int index

            width: root.periods.length > 0
              ? (chart.width - chart.spacing * (root.periods.length - 1)) / root.periods.length
              : 0
            height: chart.height

            function providerValue(row) {
              if (!row) return 0
              if (root.metric === "tokens") return Math.max(0, Number(row.totalTokens) || 0)
              return row.costUsd === null ? 0 : Math.max(0, Number(row.costUsd) || 0)
            }

            function cumulative(endIndex) {
              var total = 0
              var rows = modelData && modelData.providers ? modelData.providers : []
              for (var i = 0; i < endIndex && i < rows.length; i++) total += providerValue(rows[i])
              return total
            }

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Style.spacing.hairline
              color: root.alpha(root.foreground, 0.12)
            }

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Math.max(2, Style.spacing.hairline)
              visible: root.metric === "cost" && bucket.modelData.costUsd === null
                && Number(bucket.modelData.records || 0) > 0
              color: root.urgent
              opacity: 0.8
            }

            Repeater {
              model: bucket.modelData && bucket.modelData.providers
                ? bucket.modelData.providers : []

              delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property real amount: bucket.providerValue(modelData)
                readonly property real through: bucket.cumulative(index + 1)
                width: bucket.width
                height: root.chartMaximum > 0 ? amount / root.chartMaximum * bucket.height : 0
                y: bucket.height - (root.chartMaximum > 0
                  ? through / root.chartMaximum * bucket.height : 0)
                color: root.providerColor(String(modelData.id || ""))
                opacity: 0.82
              }
            }
          }
        }
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(axisStart.implicitHeight, axisMiddle.implicitHeight, axisEnd.implicitHeight)

        Text {
          id: axisStart
          anchors.left: parent.left
          text: root.periods.length > 0 ? root.axisLabel(root.periods[0]) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: axisMiddle
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.periods.length > 0
            ? root.axisLabel(root.periods[Math.floor(root.periods.length / 2)]) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: axisEnd
          anchors.right: parent.right
          text: "now"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Column {
      visible: root.hasResult
      width: parent.width
      spacing: Style.spacing.lg

      Ui.PanelSectionHeader {
        text: "TOKEN MIX"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.spacing.xxl
        rowSpacing: Style.spacing.lg

        Repeater {
          model: [
            { label: "Processed", value: root.formatTokens(root.totals.totalTokens) },
            { label: "Cached input", value: root.formatTokens(root.totals.cachedInputTokens) },
            { label: "Uncached input", value: root.formatTokens(root.totals.uncachedInputTokens) },
            { label: "Output", value: root.formatTokens(root.totals.outputTokens) },
            { label: "Reasoning output", value: root.formatTokens(root.totals.reasoningTokens) },
            { label: "Cache savings", value: root.formatUsd(root.totals.cacheSavingsUsd) }
          ]

          delegate: Column {
            required property var modelData
            width: (content.width - Style.spacing.xxl) / 2
            spacing: Style.spacing.labelGap

            Text {
              text: parent.modelData.label
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              text: parent.modelData.value
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.weight: Font.Medium
            }
          }
        }
      }
    }

    Column {
      visible: root.hasResult && root.providers.length > 0
      width: parent.width
      spacing: Style.spacing.lg

      Ui.PanelSectionHeader {
        text: "BY PROVIDER"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Ui.BorderSurface {
        id: providerSurface
        width: parent.width
        implicitHeight: providerRows.implicitHeight + contentTopInset + contentBottomInset
        color: Style.normalFillFor(root.foreground, Color.accent, root.urgent)
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent, root.urgent)
        padding: Style.spacing.xl
        radius: Style.cornerRadius

        Column {
          id: providerRows
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: providerSurface.contentLeftInset
          anchors.rightMargin: providerSurface.contentRightInset
          anchors.topMargin: providerSurface.contentTopInset
          spacing: Style.spacing.lg

          Repeater {
            model: root.providers

            delegate: Item {
              required property var modelData
              width: providerRows.width
              implicitHeight: Math.max(providerName.implicitHeight + providerMeta.implicitHeight
                + Style.spacing.labelGap, providerValue.implicitHeight)

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: Style.space(4)
                width: Style.space(7)
                height: width
                radius: width / 2
                color: root.providerColor(String(parent.modelData.id || ""))
              }

              Text {
                id: providerName
                anchors.left: parent.left
                anchors.leftMargin: Style.space(14)
                anchors.right: providerValue.left
                anchors.rightMargin: Style.spacing.controlGap
                text: String(parent.modelData.name || parent.modelData.id || "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.Medium
                elide: Text.ElideRight
              }

              Text {
                id: providerMeta
                anchors.left: providerName.left
                anchors.top: providerName.bottom
                anchors.topMargin: Style.spacing.labelGap
                text: root.providerMetaText(parent.modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: providerValue
                anchors.right: parent.right
                anchors.top: parent.top
                text: root.primaryValue(parent.modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.Medium
              }
            }
          }
        }
      }
    }

    Column {
      visible: root.hasResult && root.models.length > 0
      width: parent.width
      spacing: Style.spacing.lg

      Ui.PanelSectionHeader {
        text: "BY MODEL"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Ui.BorderSurface {
        id: modelSurface
        width: parent.width
        implicitHeight: modelRows.implicitHeight + contentTopInset + contentBottomInset
        color: Style.normalFillFor(root.foreground, Color.accent, root.urgent)
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent, root.urgent)
        padding: Style.spacing.xl
        radius: Style.cornerRadius

        Column {
          id: modelRows
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: modelSurface.contentLeftInset
          anchors.rightMargin: modelSurface.contentRightInset
          anchors.topMargin: modelSurface.contentTopInset
          spacing: Style.spacing.lg

          Repeater {
            model: UsageLogic.firstItems(root.models, 8)

            delegate: Item {
              required property var modelData
              width: modelRows.width
              implicitHeight: Math.max(modelName.implicitHeight + modelMeta.implicitHeight
                + Style.spacing.labelGap, modelValue.implicitHeight)

              TextEdit {
                id: modelName
                anchors.left: parent.left
                anchors.right: modelValue.left
                anchors.rightMargin: Style.spacing.controlGap
                text: String(parent.modelData.model || "Unknown model")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                readOnly: true
                selectByMouse: true
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
              }

              Text {
                id: modelMeta
                anchors.left: parent.left
                anchors.top: modelName.bottom
                anchors.topMargin: Style.spacing.labelGap
                text: String(parent.modelData.providerName || "") + " · "
                  + root.formatTokens(parent.modelData.totalTokens) + " tokens"
                  + (Number(parent.modelData.customPricedRecords || 0) > 0 ? " · custom prices"
                    : Number(parent.modelData.basePricedRecords || 0) > 0 ? " · base rates"
                    : parent.modelData.costSource === "providerReported" ? " · reported cost" : "")
                anchors.right: parent.right
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: modelValue
                anchors.right: parent.right
                anchors.top: parent.top
                text: root.primaryValue(parent.modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.Medium
              }
            }
          }
        }
      }
    }

    Text {
      visible: root.hasResult && Number(root.totals.records || 0) === 0
      width: parent.width
      topPadding: Style.spacing.huge
      bottomPadding: Style.spacing.huge
      text: "No transcript usage was found in this period."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }
}
