pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Column {
  id: root

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color surface: Color.popups.background
  property string fontFamily: Style.font.family
  property string accountDetails: ""
  property string errorText: ""
  property var draft: ({})
  property alias managementKey: managementKeyField.text
  property alias keeperPassword: keeperPasswordField.text
  readonly property bool saving: keyWriter.running
  property var pendingValues: null
  property var pendingKeys: ({})
  property bool keySaveDecided: false
  property var proxyProviders: []
  readonly property var providerOptions: proxyMode ? UsageLogic.listOrEmpty(proxyProviders) : [
    { id: "claude", name: "Claude Code" },
    { id: "codex", name: "OpenAI Codex" },
    { id: "kimi", name: "Kimi Code" }
  ]
  readonly property var allProviderIds: {
    var ids = ["claude", "codex", "kimi"]
    for (var i = 0; i < proxyProviders.length; i++)
      if (!UsageLogic.contains(ids, proxyProviders[i].id)) ids.push(proxyProviders[i].id)
    return ids
  }
  readonly property bool proxyMode: draft.usageSource === "cliproxy"

  signal saveRequested(var values)
  signal cancelRequested()
  signal revealRequested(var item)

  spacing: Style.spacing.xxl
  enabled: !saving
  Keys.onEscapePressed: root.cancelRequested()

  function discardKey() {
    managementKey = ""
    keeperPassword = ""
    pendingKeys = ({})
    pendingValues = null
    if (keyWriter.running && !keySaveDecided) keyWriter.running = false
  }

  function finishSave(saved) {
    if (keyWriter.running && !keySaveDecided) {
      keySaveDecided = true
      keyWriter.write(saved ? "commit\n" : "abort\n")
    }
    pendingValues = null
    if (saved) { managementKey = ""; keeperPassword = "" }
  }

  function begin(settings) {
    discardKey()
    function value(key, fallback) {
      return settings[key] === undefined || settings[key] === null ? fallback : settings[key]
    }
    draft = {
      usageSource: value("usageSource", "direct") === "cliproxy" ? "cliproxy" : "direct",
      cliproxyUrl: String(value("cliproxyUrl", "http://127.0.0.1:8317")),
      cliproxyKeyFile: String(value("cliproxyKeyFile", "")),
      costKeeperUrl: String(value("costKeeperUrl", "")),
      costKeeperPasswordFile: String(value("costKeeperPasswordFile", "")),
      enabledProviders: value("enabledProviders", ["claude", "codex", "kimi"]),
      barProviders: value("barProviders", ["claude", "codex", "kimi"]),
      hideAccountEmails: value("hideAccountEmails", true) !== false,
      barDisplayMode: value("barDisplayMode", "Icon"),
      refreshIntervalSec: String(value("refreshIntervalSec", 900)),
      warningThreshold: String(value("warningThreshold", 25)),
      criticalThreshold: String(value("criticalThreshold", 10))
    }
    errorText = ""
  }

  function setValue(key, value) {
    var next = Object.assign({}, draft)
    next[key] = value
    draft = next
    errorText = ""
  }

  function toggleProvider(key, id) {
    var selected = UsageLogic.listOrEmpty(draft[key])
    var result = []
    for (var i = 0; i < allProviderIds.length; i++) {
      var candidate = allProviderIds[i]
      if (UsageLogic.contains(selected, candidate) !== (candidate === id)) result.push(candidate)
    }
    setValue(key, result)
  }

  function focusFirst() { sourceControl.forceActiveFocus() }

  function submit() {
    if (saving) return false
    var next = Object.assign({}, draft)
    var ranges = [
      ["refreshIntervalSec", "Refresh interval", 60, 3600],
      ["warningThreshold", "Warning threshold", 1, 100],
      ["criticalThreshold", "Critical threshold", 0, 100]
    ]
    for (var i = 0; i < ranges.length; i++) {
      var range = ranges[i]
      var raw = String(next[range[0]]).trim()
      var value = Number(raw)
      if (raw === "" || !isFinite(value) || Math.floor(value) !== value
          || value < range[2] || value > range[3]) {
        errorText = range[1] + " must be a whole number from " + range[2] + " to " + range[3] + "."
        return false
      }
      next[range[0]] = value
    }
    if (next.criticalThreshold > next.warningThreshold) {
      errorText = "Critical threshold must be at or below the warning threshold."
      return false
    }
    next.cliproxyUrl = String(next.cliproxyUrl).trim()
    next.cliproxyKeyFile = String(next.cliproxyKeyFile).trim()
    if (proxyMode && !/^https?:\/\/[^\s/?#@]+(?::[0-9]+)?(?:\/[^\s?#]*)?$/.test(next.cliproxyUrl)) {
      errorText = "Enter an HTTP or HTTPS server URL without credentials, query, or fragment."
      return false
    }
    var key = managementKey.trim()
    if (proxyMode && managementKey !== "" && (key === "" || key.length > 8191 || /[^\x20-\x7e]/.test(key))) {
      errorText = "Enter a nonempty management API key using ASCII characters."
      return false
    }
    next.costKeeperUrl = String(next.costKeeperUrl).trim()
    var password = keeperPassword.trim()
    if ((proxyMode && (next.costKeeperUrl !== "" || password !== ""))
        && !/^https?:\/\/[^\s/?#@]+(?::[0-9]+)?(?:\/[^\s?#]*)?$/.test(next.costKeeperUrl)) {
      errorText = "Enter the CPA Usage Keeper HTTP or HTTPS URL."
      return false
    }
    if (keeperPassword !== "" && (password === "" || password.length > 8191 || /[^\x20-\x7e]/.test(password))) {
      errorText = "Enter a nonempty Keeper password using ASCII characters."
      return false
    }
    var keys = ({})
    if (proxyMode && key !== "") keys.cliproxyKeyFile = key
    if (proxyMode && password !== "") keys.costKeeperPasswordFile = password
    errorText = ""
    if (Object.keys(keys).length > 0) {
      pendingValues = next
      pendingKeys = keys
      keySaveDecided = false
      keyWriter.running = true
    } else saveRequested(next)
    return true
  }

  Process {
    id: keyWriter
    command: ["python3", "-u", decodeURIComponent(String(Qt.resolvedUrl("scripts/management-key.py")).replace(/^file:\/\//, ""))]
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify({ keys: root.pendingKeys, previousPaths: {
        cliproxyKeyFile: root.draft.cliproxyKeyFile,
        costKeeperPasswordFile: root.draft.costKeeperPasswordFile
      } }) + "\n")
      root.pendingKeys = ({})
    }
    stdout: SplitParser {
      onRead: function(data) {
        if (!root.pendingValues || root.keySaveDecided) return
        var response = null
        try { response = JSON.parse(data) } catch (error) {}
        if (!response || !response.paths) return
        var values = Object.assign({}, root.pendingValues, response.paths)
        root.saveRequested(values)
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onRunningChanged: if (!running) {
      root.pendingKeys = ({})
      if (root.pendingValues && !root.keySaveDecided)
        root.errorText = "Could not save credentials. Check that your configuration directory is writable and try again."
      root.pendingValues = null
    }
  }

  Timer {
    interval: 7000
    running: keyWriter.running
    onTriggered: keyWriter.running = false
  }

  Ui.PanelHero {
    width: parent.width
    title: "Model Usage"
    meta: "Settings"
    foreground: root.foreground
    fontFamily: root.fontFamily
    trailingControl: Component {
      Ui.PanelActionButton {
        iconText: "󰅖"
        tooltipText: "Cancel settings"
        foreground: root.foreground
        fontFamily: root.fontFamily
        focusable: true
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
        onClicked: root.cancelRequested()
      }
    }
    iconComponent: Component {
      Text {
        text: "󰒓"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.md
    Label { text: "Quota source" }
    Ui.ButtonGroup {
      id: sourceControl
      objectName: "usageSourceControl"
      options: [{ value: "direct", label: "Local CLIs" }, { value: "cliproxy", label: "CLIProxyAPI" }]
      value: String(root.draft.usageSource || "direct")
      foreground: root.foreground
      background: root.surface
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(value) { root.setValue("usageSource", value) }
      onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
    }
    Hint { text: "Quota limits and estimated costs have separate data sources." }
  }

  Column {
    visible: root.proxyMode
    width: parent.width
    spacing: Style.spacing.md
    Label { text: "CLIProxyAPI server URL" }
    Field {
      objectName: "cliproxyUrlField"
      settingKey: "cliproxyUrl"
      placeholderText: "http://127.0.0.1:8317"
      Accessible.name: "CLIProxyAPI server URL"
    }
    Label { text: "Management API key" }
    Ui.TextField {
      id: managementKeyField
      objectName: "managementKeyField"
      width: parent.width
      password: true
      maximumLength: 8191
      placeholderText: "Enter key, or leave blank to keep saved key"
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      selectByMouse: true
      Accessible.name: "CLIProxyAPI management API key"
      onTextEdited: root.errorText = ""
      onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
    }
    Hint {
      text: "Use the key you sign in to the management panel with. Saved privately on this device. Leave blank to keep your existing key."
    }
    Hint { text: "Save to discover all proxy providers and accounts automatically. Limits shows each account’s quotas." }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.md
    visible: root.proxyMode
    Label { text: "Last-used account activity (optional)" }
    Column {
      width: parent.width
      spacing: Style.spacing.md
      Label { text: "CPA Usage Keeper URL" }
      Field {
        objectName: "costKeeperUrlField"
        settingKey: "costKeeperUrl"
        placeholderText: "https://proxy.example.com/keeper"
        Accessible.name: "CPA Usage Keeper URL"
      }
      Label { text: "Keeper login password" }
      Ui.TextField {
        id: keeperPasswordField
        objectName: "keeperPasswordField"
        width: parent.width
        password: true
        maximumLength: 8191
        placeholderText: "Leave blank to keep saved password"
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        selectByMouse: true
        Accessible.name: "Keeper login password"
        onTextEdited: root.errorText = ""
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      }
      Hint {
        visible: root.draft.usageSource === "cliproxy"
        text: "Use the Keeper connected to this proxy to show the last-used account in the percentage menubar. Account activity updates every 15 seconds, independently of Costs."
      }

    }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.sm
    Row {
      width: parent.width
      Label {
        width: parent.width - hideEmailSwitch.width
        anchors.verticalCenter: parent.verticalCenter
        text: "Hide account emails"
      }
      ProviderToggle {
        id: hideEmailSwitch
        objectName: "hideAccountEmailsToggle"
        width: Style.space(82)
        checked: root.draft.hideAccountEmails !== false
        Accessible.name: "Hide account emails"
        onToggled: root.setValue("hideAccountEmails", !checked)
      }
    }
    Hint { text: "Use Account 1, Account 2, … instead of usernames or email addresses. Also hides the account identity in settings." }
  }

  Column {
    id: providerSection
    width: parent.width
    spacing: Style.spacing.sm
    Row {
      width: parent.width
      Label { width: parent.width - monitorHeading.width - barHeading.width; text: "Providers" }
      Label { id: monitorHeading; width: Style.space(82); text: "Monitor"; horizontalAlignment: Text.AlignHCenter }
      Label { id: barHeading; width: Style.space(100); text: "Menu bar"; horizontalAlignment: Text.AlignHCenter }
    }
    Repeater {
      model: root.providerOptions
      delegate: Row {
        id: providerRow
        required property var modelData
        width: providerSection.width
        Label {
          width: parent.width - monitorSwitch.width - barSwitch.width
          anchors.verticalCenter: parent.verticalCenter
          text: providerRow.modelData.name
        }
        ProviderToggle {
          id: monitorSwitch
          width: Style.space(82)
          objectName: "monitor-" + providerRow.modelData.id
          Accessible.name: "Monitor " + providerRow.modelData.name
          enabled: !root.proxyMode
          checked: root.proxyMode || UsageLogic.contains(root.draft.enabledProviders, providerRow.modelData.id)
          onToggled: root.toggleProvider("enabledProviders", providerRow.modelData.id)
        }
        ProviderToggle {
          id: barSwitch
          width: Style.space(100)
          objectName: "bar-" + providerRow.modelData.id
          Accessible.name: "Show " + providerRow.modelData.name + " in menu bar"
          enabled: monitorSwitch.checked
          checked: monitorSwitch.checked && UsageLogic.contains(root.draft.barProviders, providerRow.modelData.id)
          opacity: enabled ? 1 : 0.4
          onToggled: root.toggleProvider("barProviders", providerRow.modelData.id)
        }
      }
    }
    Hint { text: root.proxyMode
      ? "All proxy providers are monitored automatically. Menu bar selects which providers show a percentage chip when quota data is available."
      : "Monitor keeps a provider in the popup. Menu bar selects its percentage chip below; hidden providers remain available in the popup." }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.md
    Label { text: "Menu bar display" }
    Ui.ButtonGroup {
      objectName: "barDisplayControl"
      options: [{ value: "Icon", label: "Widget icon" }, { value: "Percentages", label: "Provider percentages" }]
      value: String(root.draft.barDisplayMode || "Icon")
      foreground: root.foreground
      background: root.surface
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(value) { root.setValue("barDisplayMode", value) }
      onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
    }
    Hint { text: "The widget icon is used on vertical bars or when no selected provider has quota data." }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.md
    Label { text: "Refresh interval (seconds)" }
    Field {
      settingKey: "refreshIntervalSec"
      Accessible.name: "Refresh interval in seconds"
      validator: IntValidator { bottom: 60; top: 3600 }
      inputMethodHints: Qt.ImhDigitsOnly
    }
    Row {
      width: parent.width
      spacing: Style.spacing.lg
      Column {
        width: (parent.width - parent.spacing) / 2
        spacing: Style.spacing.md
        Label { text: "Warning (% remaining)" }
        Field {
          settingKey: "warningThreshold"
          Accessible.name: "Warning percentage remaining"
          validator: IntValidator { bottom: 1; top: 100 }
          inputMethodHints: Qt.ImhDigitsOnly
        }
      }
      Column {
        width: (parent.width - parent.spacing) / 2
        spacing: Style.spacing.md
        Label { text: "Critical (% remaining)" }
        Field {
          settingKey: "criticalThreshold"
          Accessible.name: "Critical percentage remaining"
          validator: IntValidator { bottom: 0; top: 100 }
          inputMethodHints: Qt.ImhDigitsOnly
        }
      }
    }
  }


  Hint {
    visible: root.accountDetails !== ""
    text: root.draft.hideAccountEmails !== false ? root.accountDetails.replace(/^Account:.*(?:\n|$)/m, "") : root.accountDetails
  }

  Label {
    id: errorLabel
    visible: root.errorText !== ""
    text: root.errorText
    color: root.urgent
    onVisibleChanged: if (visible) Qt.callLater(function() { root.revealRequested(errorLabel) })
  }

  Row {
    spacing: Style.spacing.md
    Ui.Button {
      objectName: "saveSettingsButton"
      text: root.saving ? "Saving…" : "Save"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      selected: true
      focusable: true
      onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      onClicked: root.submit()
    }
    Ui.Button {
      objectName: "cancelSettingsButton"
      text: "Cancel"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      focusable: true
      onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      onClicked: root.cancelRequested()
    }
  }

  component Label: Text {
    width: parent.width
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
  }

  component Hint: Label {
    color: Qt.darker(root.foreground, 1.5)
    font.pixelSize: Style.font.caption
  }

  component Field: Ui.TextField {
    required property string settingKey
    width: parent.width
    text: String(root.draft[settingKey] === undefined ? "" : root.draft[settingKey])
    foreground: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    selectByMouse: true
    onTextEdited: root.setValue(settingKey, text)
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }

  component ProviderToggle: Ui.ToggleSwitch {
    foreground: root.foreground
    activeFocusOnTab: true
    hasCursor: activeFocus
    Accessible.role: Accessible.CheckBox
    Accessible.checked: checked
    Accessible.onToggleAction: if (enabled) toggled()
    Keys.onSpacePressed: toggled()
    Keys.onReturnPressed: toggled()
    Keys.onEnterPressed: toggled()
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }
}
