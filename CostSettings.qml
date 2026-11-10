pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

// The Costs tab of SettingsView. Costs follow the Limits tab: its Fusebox
// supplies history unless this tab chooses this computer or another server.
// SettingsView collects this draft with the Limits tab and stores credentials
// for both in one Save.
Column {
  id: root
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property color surface: Commons.Color.popups.background
  property string fontFamily: Style.font.family
  property var sources: []
  property string errorText: ""
  property string loadError: ""
  property int draftGeneration: 0
  property var localProviders: ["claude", "codex"]
  property alias priceEditor: prices
  property alias remoteExpanded: serverSection.expanded
  property alias pricesExpanded: priceSection.expanded
  property alias diagnosticsExpanded: scanSection.expanded
  property alias fuseboxExpanded: fuseboxSection.expanded
  // auto: Fusebox when available, else this computer. local: this computer.
  // mixed: this computer, plus the providers only Fusebox records.
  property string historySource: "auto"
  property string fuseboxUrl: ""
  property string fuseboxKeyFile: ""
  property string fuseboxKey: ""
  // "limits" reads the Limits server; "custom" names another Fusebox for Costs.
  property string fuseboxConnection: "limits"
  // The Limits tab's unsaved draft, bound by SettingsView.
  property string limitsMode: "direct"
  property string limitsUrl: ""
  property string limitsImplementation: ""
  // Edited since begin(); SettingsView marks the tab.
  property bool touched: false
  readonly property bool customFusebox: fuseboxConnection === "custom"
  readonly property bool limitsFusebox: limitsMode === "proxy" && limitsImplementation !== "go"
  readonly property bool fuseboxAvailable: customFusebox || limitsFusebox
  readonly property bool usesFusebox: fuseboxAvailable && historySource === "auto"
  readonly property string fuseboxHost: UsageLogic.urlHost(customFusebox ? fuseboxUrl : limitsUrl)
  signal cancelRequested()
  signal revealRequested(var item)
  spacing: Style.spacing.xxl
  Keys.onEscapePressed: cancelRequested()

  function sourceDetail(source) {
    var labels = {ok: "Included", partial: "Partial history", stale: "Saved history · offline",
      missing: source.kind === "fusebox" ? "No usage history" : "No transcripts",
      failed: "Unavailable", unavailable: "Unavailable", duplicate: "Already included",
      replaced: "Replaced by Fusebox", excluded: "Not counted · this computer used"}
    var text = source.name + " · " + (labels[source.status] || source.status)
    if (source.status === "stale" && source.updatedAt)
      text += " · " + Qt.formatDateTime(new Date(Number(source.updatedAt)), "MMM d, HH:mm")
    // Generic notes for included sources stay out; anything else says why.
    if (source.status !== "ok" && source.message) text += "\n" + source.message
    return text
  }

  function historyDescription() {
    if (usesFusebox)
      return "Everything sent through Fusebox at " + (fuseboxHost || "this server")
        + ", from any computer. This computer's own history is left out, so nothing is counted twice."
    if (fuseboxAvailable && historySource === "mixed")
      return "Claude and OpenAI come from sessions recorded here, plus any T3 servers. Fusebox adds only the providers this computer has no history for."
    if (fuseboxAvailable)
      return "Codex and Claude Code sessions recorded here, plus any T3 servers. Fusebox's records are left out."
    if (limitsMode === "proxy" && limitsImplementation === "go")
      return "CLIProxyAPI keeps no usage history, so costs come from Codex and Claude Code sessions recorded here, plus any T3 servers."
    return "Codex and Claude Code sessions recorded here, plus any T3 servers. Limits reads this computer's CLIs, so there is no Fusebox server to use."
  }

  function edited() {
    touched = true
    errorText = ""
  }

  function discardKey() {
    for (let i = 0; i < servers.count; i++) servers.setProperty(i, "token", "")
    fuseboxKey = ""
    fuseboxCredential.reset()
    fuseboxTest.reset()
  }
  function finishSave(saved) {
    if (saved) discardKey()
  }
  function begin(settings) {
    draftGeneration++
    discardKey()
    servers.clear()
    errorText = ""
    loadError = ""
    serverSection.expanded = false
    priceSection.expanded = false
    scanSection.expanded = false
    fuseboxSection.expanded = false
    whySection.expanded = false
    var fusebox = UsageLogic.fuseboxCostConnection(settings, "")
    historySource = fusebox.source
    fuseboxConnection = fusebox.mode
    fuseboxUrl = String(settings.costFuseboxUrl || "")
    fuseboxKeyFile = String(settings.costFuseboxKeyFile || "")
    localProviders = settings.costLocalProviders === undefined ? ["claude", "codex"] : settings.costLocalProviders
    prices.begin(String(settings.costPriceOverrides || "{}"))
    try {
      let rows = JSON.parse(String(settings.costT3Servers || "[]"))
      if (!Array.isArray(rows) || rows.length > 4) throw new Error()
      for (let i = 0; i < rows.length; i++) {
        let row = rows[i]
        if (!row || typeof row.id !== "string" || typeof row.url !== "string" || typeof row.name !== "string") throw new Error()
        servers.append({serverId: row.id, name: row.name, url: row.url,
          tokenFile: String(row.tokenFile || ""), token: "", included: row.enabled !== false})
      }
    } catch (e) { loadError = "Saved T3 settings are invalid. Remove them to configure servers again." }
    if (loadError) serverSection.expanded = true
    if (prices.loadError) priceSection.expanded = true
    touched = false
  }
  function focusFirst() {
    if (fuseboxAvailable) historyControl.forceActiveFocus()
    else localCodex.forceActiveFocus()
  }
  // "fusebox" or "local" from the selector; the mixed switch refines "local".
  function chooseHistory(value) {
    if (value === "fusebox") historySource = "auto"
    else if (historySource === "auto") historySource = "local"
    edited()
  }
  function toggleLocal(id) {
    var next = []
    var allowed = ["claude", "codex"]
    for (let i = 0; i < allowed.length; i++)
      if (UsageLogic.contains(localProviders, allowed[i]) !== (allowed[i] === id)) next.push(allowed[i])
    localProviders = next
    edited()
  }
  function addServer() {
    if (servers.count >= 4) return
    servers.append({serverId: "t3-" + Date.now() + "-" + Math.floor(Math.random() * 1000000),
      name: "T3 Code", url: "", tokenFile: "", token: "", included: true})
    edited()
    focusServer(servers.count - 1, "t3Url-")
  }
  function removeServer(index) {
    servers.remove(index)
    edited()
  }
  function setServer(index, key, value) { servers.setProperty(index, key, value); edited() }
  function findItem(item, name) {
    if (item.objectName === name) return item
    var children = item.children || []
    for (let i = 0; i < children.length; i++) {
      let result = findItem(children[i], name)
      if (result) return result
    }
    return null
  }
  function focusServer(index, prefix) {
    var generation = draftGeneration
    serverSection.expanded = true
    Qt.callLater(function() {
      if (!root.visible || generation !== root.draftGeneration) return
      var row = serverRepeater.itemAt(index)
      if (!row) return
      row.editorSection.expanded = true
      Qt.callLater(function() {
        if (!root.visible || generation !== root.draftGeneration) return
        var field = root.findItem(row, prefix + index)
        if (!field) return
        if (field.focusEditor) field.focusEditor()
        else { field.forceActiveFocus(); root.revealRequested(field) }
      })
    })
  }
  function setFusebox(name, value) { root[name] = value; edited() }
  function setFuseboxConnection(mode) {
    // Start a different server from the Limits URL rather than an empty field.
    if (mode === "custom" && fuseboxUrl.trim() === "") fuseboxUrl = limitsUrl
    setFusebox("fuseboxConnection", mode)
  }
  function focusFusebox(name) {
    var generation = draftGeneration
    fuseboxSection.expanded = true
    Qt.callLater(function() {
      if (!root.visible || generation !== root.draftGeneration) return
      var field = root.findItem(fuseboxSection, name)
      if (!field) return
      if (field.focusEditor) field.focusEditor()
      else { field.forceActiveFocus(); root.revealRequested(field) }
    })
  }
  function fail(message) {
    errorText = message
    return null
  }
  // Validated values plus typed secrets to store privately, or null with errorText set.
  function collect() {
    if (loadError !== "") { serverSection.expanded = true; return fail(loadError) }
    var values = {costLocalProviders: localProviders, costHistorySource: historySource}
    try { values.costPriceOverrides = prices.serialize() }
    catch (e) { priceSection.expanded = true; return fail(String(e.message || e)) }
    var rows = [], keys = ({}), previous = ({}), ids = ({})
    for (let i = 0; i < servers.count; i++) {
      let row = servers.get(i), url = row.url.trim(), name = row.name.trim(), token = row.token.trim()
      if (!/^[a-zA-Z0-9-]{1,64}$/.test(row.serverId) || ids[row.serverId]
          || name === "" || name.length > 80 || /[\x00-\x1f]/.test(name)
          || !/^https?:\/\/[^\s/?#@]+(?:\/[^\s?#]*)?$/.test(url)
          || /(?:^|\/)\.{1,2}(?:\/|$)/.test(url)) {
        focusServer(i, name === "" || name.length > 80 || /[\x00-\x1f]/.test(name) ? "t3Name-" : "t3Url-")
        return fail("Give each T3 server a name and an HTTP(S) URL without credentials, query, or fragment.")
      }
      ids[row.serverId] = true
      if (row.token !== "" && (token === "" || /[^\x21-\x7e]/.test(token))) {
        focusServer(i, "t3Credential-")
        return fail("Enter the connection token without spaces.")
      }
      rows.push({id: row.serverId, name: name, url: url, tokenFile: row.tokenFile, enabled: row.included})
      if (token !== "") {
        keys["t3Token_" + row.serverId] = token
        previous["t3Token_" + row.serverId] = row.tokenFile
      }
    }
    values.costT3Servers = JSON.stringify(rows)
    var fuseboxAddress = fuseboxUrl.trim(), fuseboxToken = customFusebox ? fuseboxKey.trim() : ""
    if (customFusebox && !UsageLogic.validServerUrl(fuseboxAddress)) {
      focusFusebox("costFuseboxUrl")
      return fail("Enter the Fusebox server HTTP(S) URL without credentials, query, or fragment.")
    }
    if (customFusebox && fuseboxKey !== "" && !UsageLogic.validSecret(fuseboxToken)) {
      focusFusebox("costFuseboxCredential")
      return fail("Enter a nonempty management API key using ASCII characters.")
    }
    if (customFusebox && fuseboxToken === "" && fuseboxKeyFile === "") {
      focusFusebox("costFuseboxCredential")
      return fail("Enter the Fusebox management key.")
    }
    values.costFuseboxConnection = fuseboxConnection
    values.costFuseboxUrl = fuseboxAddress
    values.costFuseboxKeyFile = fuseboxKeyFile
    if (fuseboxToken !== "") {
      keys.costFuseboxKeyFile = fuseboxToken
      previous.costFuseboxKeyFile = fuseboxKeyFile
    }
    errorText = ""
    return {values: values, keys: keys, previousPaths: previous}
  }
  // Saved private files replace the typed secrets in the collected values.
  function applyPaths(values, paths) {
    var next = Object.assign({}, values)
    if (next.costT3Servers !== undefined) {
      let rows = JSON.parse(next.costT3Servers)
      for (let i = 0; i < rows.length; i++) {
        let path = paths["t3Token_" + rows[i].id]
        if (path) rows[i].tokenFile = path
      }
      next.costT3Servers = JSON.stringify(rows)
    }
    if (paths.costFuseboxKeyFile) next.costFuseboxKeyFile = paths.costFuseboxKeyFile
    return next
  }

  ListModel { id: servers }

  Column {
    width: parent.width
    spacing: Style.spacing.md
    Row {
      width: parent.width
      visible: root.fuseboxAvailable
      Label { width: parent.width - historyControl.width; text: "Cost history from"; anchors.verticalCenter: parent.verticalCenter }
      UsageSelect {
        id: historyControl
        objectName: "costHistoryControl"
        width: Math.min(implicitWidth, parent.width * 0.6)
        label: "Cost history from"
        options: [{ value: "fusebox", label: "Fusebox" }, { value: "local", label: "This computer" }]
        value: root.usesFusebox ? "fusebox" : "local"
        foreground: root.foreground
        surface: root.surface
        fontFamily: root.fontFamily
        alignPopupRight: true
        onChanged: function(value) { root.chooseHistory(value) }
        onMenuClosed: if (root.visible) historyControl.forceActiveFocus()
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      }
    }
    Label { visible: !root.fuseboxAvailable; text: "Cost history from"; font.bold: true }
    Hint { objectName: "costHistoryDescription"; text: root.historyDescription() }
    Row {
      width: parent.width
      visible: root.fuseboxAvailable && !root.usesFusebox
      Label { width: parent.width - otherProviders.width; text: "Add providers only Fusebox records"; anchors.verticalCenter: parent.verticalCenter }
      Toggle { id: otherProviders; objectName: "costFuseboxOtherProviders"; checked: root.historySource === "mixed"; onToggled: root.setFusebox("historySource", checked ? "local" : "mixed"); Accessible.name: "Add providers only Fusebox records" }
    }
    Hint { visible: root.fuseboxAvailable && !root.usesFusebox; text: "Muse, Grok and other providers this computer has no history for." }
    Section {
      id: whySection
      objectName: "costWhyNotBoth"
      visible: root.fuseboxAvailable
      title: "Why not both?"
      Hint { text: "Requests sent through Fusebox are also saved on this computer, and the two records can't be matched, so adding them would count the same requests twice. To include sessions that bypass Fusebox, turn on Claude Code and Codex history import in Fusebox; it removes duplicates itself." }
    }
    Section {
      id: fuseboxSection
      objectName: "fuseboxCostSection"
      title: root.limitsFusebox ? "Different Fusebox server" : "Fusebox server"
      summary: root.customFusebox ? (root.fuseboxHost || "Setup") : "Off"
      Row {
        width: parent.width
        Label { width: parent.width - fuseboxCustomToggle.width; text: root.limitsFusebox ? "Use a different Fusebox server for costs" : "Read costs from a Fusebox server"; anchors.verticalCenter: parent.verticalCenter }
        Toggle { id: fuseboxCustomToggle; objectName: "costFuseboxCustom"; checked: root.customFusebox; onToggled: root.setFuseboxConnection(checked ? "limits" : "custom"); Accessible.name: root.limitsFusebox ? "Use a different Fusebox server for costs" : "Read costs from a Fusebox server" }
      }
      Hint { visible: !root.customFusebox; text: root.limitsFusebox ? "Costs read the Fusebox server set in the Limits tab." : "For a Fusebox server that Limits doesn't use." }
      Label { visible: root.customFusebox; text: "Server URL" }
      Field { objectName: "costFuseboxUrl"; visible: root.customFusebox; text: root.fuseboxUrl; placeholderText: root.limitsUrl || UsageLogic.DEFAULT_PROXY_URL; maximumLength: 4096; onTextEdited: root.setFusebox("fuseboxUrl", text); Accessible.name: "Fusebox server URL" }
      Hint { visible: root.customFusebox && UsageLogic.insecureRemoteUrl(root.fuseboxUrl); color: root.urgent; text: "This credential is sent unencrypted over http:// to another computer. Use https:// unless the network is trusted." }
      SettingsCredential {
        id: fuseboxCredential
        objectName: "costFuseboxCredential"
        visible: root.customFusebox
        editorObjectName: "costFuseboxKey"
        width: parent.width
        label: "Management API key"
        saved: root.fuseboxKeyFile !== ""
        foreground: root.foreground
        fontFamily: root.fontFamily
        onEdited: function(value) { root.setFusebox("fuseboxKey", value) }
        onRevealRequested: function(item) { root.revealRequested(item) }
      }
      ConnectionTest {
        id: fuseboxTest
        objectName: "costFuseboxConnectionTest"
        visible: root.customFusebox
        width: parent.width
        requireFusebox: true
        url: root.fuseboxUrl
        keyFile: root.fuseboxKeyFile
        key: root.fuseboxKey
        foreground: root.foreground
        urgent: root.urgent
        fontFamily: root.fontFamily
        onRevealRequested: function(item) { root.revealRequested(item) }
      }
      Hint { visible: root.customFusebox; text: "Uses the management key from the Fusebox dashboard. Saved privately on this device; blank keeps the saved key. An offline server keeps its last history with a timestamp." }
    }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.xxl
    Text {
      objectName: "costInactiveNotice"
      visible: root.usesFusebox
      width: parent.width
      text: "NOT USED WHILE FUSEBOX SUPPLIES COSTS"
      color: UsageLogic.dimColor(root.foreground)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
    }
    Column {
      objectName: "costLocalSection"
      width: parent.width
      spacing: Style.spacing.md
      opacity: root.usesFusebox ? 0.45 : 1
      Label { text: "This computer"; font.bold: true }
      Row {
        width: parent.width
        Label { width: parent.width - localCodex.width; text: "Codex CLI"; anchors.verticalCenter: parent.verticalCenter }
        Toggle { id: localCodex; objectName: "costLocalCodex"; checked: UsageLogic.contains(root.localProviders, "codex"); onToggled: root.toggleLocal("codex"); Accessible.name: "Include local Codex" }
      }
      Row {
        width: parent.width
        Label { width: parent.width - localClaude.width; text: "Claude Code"; anchors.verticalCenter: parent.verticalCenter }
        Toggle { id: localClaude; objectName: "costLocalClaude"; checked: UsageLogic.contains(root.localProviders, "claude"); onToggled: root.toggleLocal("claude"); Accessible.name: "Include local Claude Code" }
      }
      Hint { text: "Include sessions recorded on this computer." }
    }

    Section {
      id: serverSection
      objectName: "remoteServersSection"
      opacity: root.usesFusebox ? 0.45 : 1
      title: "T3 Code servers"
      summary: servers.count ? servers.count + (servers.count === 1 ? " server" : " servers") : "Not configured"
      Hint { text: "Include history from other computers running T3 Code." }
      Label { visible: root.loadError !== ""; text: root.loadError; color: root.urgent }
      Ui.Button {
        visible: root.loadError !== ""
        text: "Remove invalid server settings"
        foreground: root.foreground
        fontFamily: root.fontFamily
        focusable: true
        onClicked: { servers.clear(); root.loadError = ""; root.edited() }
      }
      Repeater {
        id: serverRepeater
        model: servers
        Column {
          id: serverRow
          required property int index
          required property string name
          required property string url
          required property string token
          required property string tokenFile
          required property bool included
          property alias editorSection: serverDetails
          width: serverSection.width
          spacing: Style.spacing.sm
          Row {
            width: parent.width
            Label { width: parent.width - remoteToggle.width; text: serverRow.name || "New server"; anchors.verticalCenter: parent.verticalCenter }
            Toggle { id: remoteToggle; checked: serverRow.included; onToggled: root.setServer(serverRow.index, "included", !checked); Accessible.name: "Include T3 server " + (serverRow.index + 1) }
          }
          Section {
            id: serverDetails
            objectName: "t3Details-" + serverRow.index
            title: "Connection details"
            summary: serverRow.url ? "Configured" : "Setup"
            Label { text: "Server name" }
            Field { objectName: "t3Name-" + serverRow.index; text: serverRow.name; placeholderText: "Server name"; maximumLength: 80; onTextEdited: root.setServer(serverRow.index, "name", text); Accessible.name: "T3 server name" }
            Label { text: "Server URL" }
            Field { objectName: "t3Url-" + serverRow.index; text: serverRow.url; placeholderText: "https://t3.example.com"; maximumLength: 4096; onTextEdited: root.setServer(serverRow.index, "url", text); Accessible.name: "T3 server URL" }
            Hint { visible: UsageLogic.insecureRemoteUrl(serverRow.url); color: root.urgent; text: "This credential is sent unencrypted over http:// to another computer. Use https:// unless the network is trusted." }
            SettingsCredential {
              objectName: "t3Credential-" + serverRow.index
              editorObjectName: "t3Token-" + serverRow.index
              width: parent.width
              label: "Connection token"
              text: serverRow.token
              saved: serverRow.tokenFile !== ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              onEdited: function(value) { root.setServer(serverRow.index, "token", value) }
              onRevealRequested: function(item) { root.revealRequested(item) }
            }
            Ui.Button {
              text: "Remove server"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              onClicked: root.removeServer(serverRow.index)
              onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
            }
          }
          Ui.PanelSeparator { foreground: root.foreground }
        }
      }
      Ui.Button {
        objectName: "addT3Server"
        text: "Add T3 server"
        enabled: servers.count < 4 && root.loadError === ""
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        focusable: true
        onClicked: root.addServer()
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      }
      Section {
        title: "Learn more"
        Hint { text: "Use the server’s base URL and connection token. Credentials are saved privately on this device. T3 can include sessions started outside T3; matching transcript folders are counted once. Offline servers retain their last usable history with a timestamp." }
      }
    }
  }

  Section {
    id: priceSection
    objectName: "customPricesSection"
    title: "Custom prices"
    summary: prices.priceCount ? prices.priceCount + (prices.priceCount === 1 ? " override" : " overrides") : "Automatic pricing"
    CostPriceEditor {
      id: prices
      width: parent.width
      foreground: root.foreground
      urgent: root.urgent
      fontFamily: root.fontFamily
      onRevealRequested: function(item) { priceSection.expanded = true; root.revealRequested(item) }
      onEdited: root.edited()
    }
  }

  Section {
    id: scanSection
    objectName: "lastScanSection"
    title: "Last scan"
    summary: root.sources.length ? root.sources.length + (root.sources.length === 1 ? " source" : " sources") : "No scan yet"
    Repeater {
      model: root.sources
      Text {
        required property var modelData
        objectName: "costSource-" + modelData.id
        width: root.width
        text: root.sourceDetail(modelData)
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: modelData.status === "unavailable" || modelData.status === "failed" ? root.urgent : UsageLogic.dimColor(root.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    Hint { visible: root.sources.length === 0; text: "Open Costs to scan session history." }
  }

  component Section: SettingsSection {
    width: parent.width
    foreground: root.foreground
    fontFamily: root.fontFamily
    onRevealRequested: function(item) { root.revealRequested(item) }
  }
  component Label: Text { width: parent.width; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText; wrapMode: Text.WordWrap }
  component Hint: Label { color: UsageLogic.dimColor(root.foreground); font.pixelSize: Style.font.caption }
  component Field: SettingsField { width: parent.width; foreground: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; selectByMouse: true; onActiveFocusChanged: if (activeFocus) root.revealRequested(this) }
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
