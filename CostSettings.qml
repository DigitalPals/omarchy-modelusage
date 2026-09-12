pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
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
  property var sources: []
  property string errorText: ""
  property string loadError: ""
  property var localProviders: ["claude", "codex"]
  property alias priceEditor: prices
  property var pendingValues: null
  property var pendingKeys: ({})
  property var previousPaths: ({})
  property bool keySaveDecided: false
  readonly property bool saving: keyWriter.running
  signal saveRequested(var values)
  signal cancelRequested()
  signal revealRequested(var item)
  spacing: Style.spacing.xxl
  enabled: !saving
  Keys.onEscapePressed: cancelRequested()

  function sourceDetail(source) {
    var labels = {ok: "Included", partial: "Partial history", stale: "Saved history · offline",
      missing: "No transcripts", failed: "Unavailable", unavailable: "Unavailable", duplicate: "Already included"}
    var text = source.name + " · " + (labels[source.status] || source.status)
    if (source.status === "stale" && source.updatedAt)
      text += " · " + Qt.formatDateTime(new Date(Number(source.updatedAt)), "MMM d, HH:mm")
    return text
  }

  function discardKey() {
    for (var i = 0; i < servers.count; i++) servers.setProperty(i, "token", "")
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
    if (saved) discardKey()
  }
  function begin(settings) {
    discardKey()
    servers.clear()
    errorText = ""
    loadError = ""
    localProviders = settings.costLocalProviders === undefined ? ["claude", "codex"] : settings.costLocalProviders
    prices.begin(String(settings.costPriceOverrides || "{}"))
    try {
      var rows = JSON.parse(String(settings.costT3Servers || "[]"))
      if (!Array.isArray(rows) || rows.length > 4) throw new Error()
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i]
        if (!row || typeof row.id !== "string" || typeof row.url !== "string" || typeof row.name !== "string") throw new Error()
        servers.append({serverId: row.id, name: row.name, url: row.url,
          tokenFile: String(row.tokenFile || ""), token: "", included: row.enabled !== false})
      }
    } catch (e) { loadError = "Saved T3 settings are invalid. Remove them to configure servers again." }
  }
  function focusFirst() { localCodex.forceActiveFocus() }
  function toggleLocal(id) {
    var next = []
    var allowed = ["claude", "codex"]
    for (var i = 0; i < allowed.length; i++)
      if (UsageLogic.contains(localProviders, allowed[i]) !== (allowed[i] === id)) next.push(allowed[i])
    localProviders = next
  }
  function addServer() {
    if (servers.count >= 4) return
    servers.append({serverId: "t3-" + Date.now() + "-" + Math.floor(Math.random() * 1000000),
      name: "T3 Code", url: "", tokenFile: "", token: "", included: true})
  }
  function setServer(index, key, value) { servers.setProperty(index, key, value); errorText = "" }
  function submit() {
    if (saving) return false
    if (loadError !== "") { errorText = loadError; return false }
    var values = {costLocalProviders: localProviders}
    try { values.costPriceOverrides = prices.serialize() }
    catch (e) { errorText = String(e.message || e); return false }
    var rows = [], keys = ({}), previous = ({}), ids = ({})
    for (var i = 0; i < servers.count; i++) {
      var row = servers.get(i), url = row.url.trim(), name = row.name.trim(), token = row.token.trim()
      if (!/^[a-zA-Z0-9-]{1,64}$/.test(row.serverId) || ids[row.serverId]
          || name === "" || name.length > 80 || /[\x00-\x1f]/.test(name)
          || !/^https?:\/\/[^\s/?#@]+(?:\/[^\s?#]*)?$/.test(url)
          || /(?:^|\/)\.{1,2}(?:\/|$)/.test(url)) {
        errorText = "Give each T3 server a name and an HTTP(S) URL without credentials, query, or fragment."
        return false
      }
      ids[row.serverId] = true
      if (row.token !== "" && (token === "" || /[^\x21-\x7e]/.test(token))) {
        errorText = "Enter the connection token without spaces."; return false
      }
      rows.push({id: row.serverId, name: name, url: url, tokenFile: row.tokenFile, enabled: row.included})
      if (token !== "") {
        keys["t3Token_" + row.serverId] = token
        previous["t3Token_" + row.serverId] = row.tokenFile
      }
    }
    values.costT3Servers = JSON.stringify(rows)
    errorText = ""
    if (Object.keys(keys).length) {
      pendingValues = values; pendingKeys = keys; previousPaths = previous
      keySaveDecided = false; keyWriter.running = true
    } else saveRequested(values)
    return true
  }

  ListModel { id: servers }
  Process {
    id: keyWriter
    command: ["python3", "-u", decodeURIComponent(String(Qt.resolvedUrl("scripts/management-key.py")).replace(/^file:\/\//, ""))]
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify({keys: root.pendingKeys, previousPaths: root.previousPaths}) + "\n")
      root.pendingKeys = ({})
    }
    stdout: SplitParser {
      onRead: function(data) {
        if (!root.pendingValues || root.keySaveDecided) return
        var response
        try { response = JSON.parse(data) } catch (e) { return }
        if (!response.paths) return
        var values = Object.assign({}, root.pendingValues)
        var rows = JSON.parse(values.costT3Servers)
        for (var i = 0; i < rows.length; i++) {
          var path = response.paths["t3Token_" + rows[i].id]
          if (path) rows[i].tokenFile = path
        }
        values.costT3Servers = JSON.stringify(rows)
        root.saveRequested(values)
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onRunningChanged: if (!running) {
      root.pendingKeys = ({})
      if (root.pendingValues && !root.keySaveDecided) root.errorText = "Could not save the private T3 token. Check your configuration directory and try again."
      root.pendingValues = null
    }
  }
  Timer { interval: 7000; running: keyWriter.running; onTriggered: keyWriter.running = false }

  Ui.PanelHero {
    width: parent.width
    title: "Costs"
    meta: "Sources and prices"
    foreground: root.foreground
    fontFamily: root.fontFamily
    trailingControl: Component {
      Ui.PanelActionButton {
        iconText: "󰅖"
        tooltipText: "Cancel cost settings"
        foreground: root.foreground
        focusable: true
        onClicked: root.cancelRequested()
      }
    }
  }
  Column {
    width: parent.width
    spacing: Style.spacing.md
    Label { text: "Local session history" }
    Row {
      width: parent.width
      Label { width: parent.width - localCodex.width; text: "Codex CLI"; anchors.verticalCenter: parent.verticalCenter }
      Toggle { id: localCodex; objectName: "costLocalCodex"; checked: UsageLogic.contains(root.localProviders, "codex"); onToggled: root.toggleLocal("codex"); Accessible.name: "Include local Codex" }
    }
    Row {
      width: parent.width
      Label { width: parent.width - localClaude.width; text: "Claude Code CLI"; anchors.verticalCenter: parent.verticalCenter }
      Toggle { id: localClaude; objectName: "costLocalClaude"; checked: UsageLogic.contains(root.localProviders, "claude"); onToggled: root.toggleLocal("claude"); Accessible.name: "Include local Claude Code" }
    }
    Hint { text: "Read session history on this computer. Enabled sources are combined automatically." }
  }
  Column {
    id: serverSection
    width: parent.width
    spacing: Style.spacing.lg
    Label { text: "Remote T3 Code" }
    Hint { text: "Connect a T3 server to include Codex and Claude sessions it can read on that computer, including sessions started outside T3. Matching transcript folders are counted once." }
    Label { visible: root.loadError !== ""; text: root.loadError; color: root.urgent }
    Ui.Button { visible: root.loadError !== ""; text: "Remove invalid server settings"; onClicked: { servers.clear(); root.loadError = "" } }
    Repeater {
      model: servers
      Column {
        id: serverRow
        required property int index
        required property string name
        required property string url
        required property string token
        required property bool included
        width: serverSection.width
        spacing: Style.spacing.md
        Row {
          width: parent.width
          Label { width: parent.width - remoteToggle.width; text: "Server " + (serverRow.index + 1); anchors.verticalCenter: parent.verticalCenter }
          Toggle { id: remoteToggle; checked: serverRow.included; onToggled: root.setServer(serverRow.index, "included", !checked); Accessible.name: "Include T3 server " + (serverRow.index + 1) }
        }
        Field { objectName: "t3Name-" + serverRow.index; text: serverRow.name; placeholderText: "Server name"; maximumLength: 80; onTextEdited: root.setServer(serverRow.index, "name", text); Accessible.name: "T3 server name" }
        Field { objectName: "t3Url-" + serverRow.index; text: serverRow.url; placeholderText: "https://t3.example.com"; maximumLength: 4096; onTextEdited: root.setServer(serverRow.index, "url", text); Accessible.name: "T3 server URL" }
        Field { objectName: "t3Token-" + serverRow.index; text: serverRow.token; password: true; maximumLength: 8191; placeholderText: "Connection token · blank keeps saved token"; onTextEdited: root.setServer(serverRow.index, "token", text); Accessible.name: "T3 connection token" }
        Ui.Button { text: "Remove server"; foreground: root.foreground; fontFamily: root.fontFamily; focusable: true; onClicked: servers.remove(serverRow.index); onActiveFocusChanged: if (activeFocus) root.revealRequested(this) }
        Ui.PanelSeparator { foreground: root.foreground }
      }
    }
    Ui.Button { objectName: "addT3Server"; text: "Add T3 server"; enabled: servers.count < 4 && root.loadError === ""; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; focusable: true; onClicked: root.addServer(); onActiveFocusChanged: if (activeFocus) root.revealRequested(this) }
    Hint { text: "Use the server’s base URL and connection token. Tokens are saved privately on this device. If a server is offline, its last usable history stays visible with a timestamp." }
  }
  Column {
      visible: root.sources.length > 0
      width: parent.width
      spacing: Style.spacing.sm
      Label { text: "Last scan" }
      Repeater {
        model: root.sources
        Text {
          required property var modelData
          objectName: "costSource-" + modelData.id
          width: root.width
          text: root.sourceDetail(modelData)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: modelData.status === "unavailable" || modelData.status === "failed" ? root.urgent : Qt.darker(root.foreground, 1.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          HoverHandler { id: sourceHover }
          Controls.ToolTip.visible: sourceHover.hovered
          Controls.ToolTip.text: String(modelData.message || "")
        }
      }
    }

  CostPriceEditor { id: prices; width: parent.width; foreground: root.foreground; urgent: root.urgent; fontFamily: root.fontFamily; onRevealRequested: function(item) { root.revealRequested(item) }; onEdited: root.errorText = "" }
  Label { id: errorLabel; visible: root.errorText !== ""; text: root.errorText; color: root.urgent; onVisibleChanged: if (visible) Qt.callLater(function() { root.revealRequested(errorLabel) }) }
  Row {
    spacing: Style.spacing.md
    Ui.Button { objectName: "saveCostSettings"; text: root.saving ? "Saving…" : "Save"; bordered: true; selected: true; foreground: root.foreground; fontFamily: root.fontFamily; focusable: true; onClicked: root.submit(); onActiveFocusChanged: if (activeFocus) root.revealRequested(this) }
    Ui.Button { text: "Cancel"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; focusable: true; onClicked: root.cancelRequested(); onActiveFocusChanged: if (activeFocus) root.revealRequested(this) }
  }
  component Label: Text { width: parent.width; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText; wrapMode: Text.WordWrap }
  component Hint: Label { opacity: 0.7; font.pixelSize: Style.font.caption }
  component Field: Ui.TextField { width: parent.width; foreground: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; selectByMouse: true; onActiveFocusChanged: if (activeFocus) root.revealRequested(this) }
  component Toggle: Ui.ToggleSwitch {
    width: Style.space(82)
    foreground: root.foreground
    activeFocusOnTab: true
    hasCursor: activeFocus
    Accessible.role: Accessible.CheckBox
    Accessible.checked: checked
    Accessible.onToggleAction: if (enabled) toggled()
    Keys.onSpacePressed: toggled()
    Keys.onReturnPressed: toggled()
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }
}
