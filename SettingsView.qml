pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// One settings page for both views. Each tab keeps its own draft; edits
// survive switching tabs, and one Save validates both and stores every typed
// credential in a single transaction that commits or aborts together.
Column {
  id: root
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property color surface: Commons.Color.popups.background
  property string fontFamily: Style.font.family
  // Passed through to the tabs.
  property string accountDetails: ""
  property var proxyProviders: []
  property string proxyImplementation: ""
  property var sources: []
  property string tab: "limits"
  property string transactionError: ""
  property alias limitsForm: limitsForm
  property alias costForm: costForm
  property var pendingValues: null
  property var pendingKeys: ({})
  property var previousPaths: ({})
  property bool keySaveDecided: false
  readonly property bool saving: keyWriter.running
  readonly property bool touched: limitsForm.touched || costForm.touched
  readonly property string errorText: transactionError !== "" ? transactionError
    : limitsForm.errorText !== "" ? limitsForm.errorText : costForm.errorText
  signal saveRequested(var values)
  signal cancelRequested()
  signal revealRequested(var item)
  spacing: Style.spacing.md
  enabled: !saving
  Keys.onEscapePressed: cancelRequested()

  function begin(settings, initialTab) {
    discardKey()
    transactionError = ""
    limitsForm.begin(settings)
    costForm.begin(settings)
    tab = initialTab === "costs" ? "costs" : "limits"
  }
  function selectTab(value) {
    tab = value === "costs" ? "costs" : "limits"
    transactionError = ""
  }
  function focusFirst() {
    if (tab === "costs") costForm.focusFirst()
    else limitsForm.focusFirst()
  }
  function discardKey() {
    limitsForm.discardKey()
    costForm.discardKey()
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
    limitsForm.finishSave(saved)
    costForm.finishSave(saved)
  }
  // Limits first, then Costs; the first problem opens its tab.
  function submit() {
    if (saving) return false
    transactionError = ""
    var limits = limitsForm.collect()
    if (!limits) { tab = "limits"; return false }
    var costs = costForm.collect()
    if (!costs) { tab = "costs"; return false }
    var values = Object.assign({}, limits.values, costs.values)
    var keys = Object.assign({}, limits.keys, costs.keys)
    if (Object.keys(keys).length === 0) {
      saveRequested(values)
      return true
    }
    pendingValues = values
    pendingKeys = keys
    previousPaths = Object.assign({}, limits.previousPaths, costs.previousPaths)
    keySaveDecided = false
    keyWriter.running = true
    return true
  }

  Process {
    id: keyWriter
    command: ["python3", "-u", decodeURIComponent(String(Qt.resolvedUrl("scripts/management-key.py")).replace(/^file:\/\//, ""))]
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify({ keys: root.pendingKeys, previousPaths: root.previousPaths }) + "\n")
      root.pendingKeys = ({})
    }
    stdout: SplitParser {
      onRead: function(data) {
        if (!root.pendingValues || root.keySaveDecided) return
        var response = null
        try { response = JSON.parse(data) } catch (error) { response = null }
        if (!response || !response.paths) return
        var values = root.costForm.applyPaths(root.limitsForm.applyPaths(root.pendingValues, response.paths), response.paths)
        root.saveRequested(values)
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onRunningChanged: if (!running) {
      root.pendingKeys = ({})
      if (root.pendingValues && !root.keySaveDecided)
        root.transactionError = "Could not save credentials. Check that your configuration directory is writable and try again."
      root.pendingValues = null
    }
  }
  Timer { interval: 7000; running: keyWriter.running; onTriggered: keyWriter.running = false }

  SettingsHeader {
    width: parent.width
    title: "Settings"
    foreground: root.foreground
    fontFamily: root.fontFamily
    onCloseRequested: root.cancelRequested()
    onRevealRequested: function(item) { root.revealRequested(item) }
  }

  // A dot marks a tab with unsaved edits, since Save writes both.
  UsageTabs {
    id: tabs
    objectName: "settingsTabs"
    width: parent.width
    options: [{ value: "limits", label: "Limits" }, { value: "costs", label: "Costs" }]
    marked: (limitsForm.touched ? ["limits"] : []).concat(costForm.touched ? ["costs"] : [])
    value: root.tab
    foreground: root.foreground
    fontFamily: root.fontFamily
    onChanged: function(value) { root.selectTab(value) }
  }

  Item { width: 1; height: Style.spacing.md }

  UsageSettings {
    id: limitsForm
    visible: root.tab === "limits"
    width: parent.width
    foreground: root.foreground
    urgent: root.urgent
    surface: root.surface
    fontFamily: root.fontFamily
    accountDetails: root.accountDetails
    proxyProviders: root.proxyProviders
    proxyImplementation: root.proxyImplementation
    onCancelRequested: root.cancelRequested()
    onRevealRequested: function(item) { root.revealRequested(item) }
  }

  CostSettings {
    id: costForm
    visible: root.tab === "costs"
    width: parent.width
    foreground: root.foreground
    urgent: root.urgent
    surface: root.surface
    fontFamily: root.fontFamily
    sources: root.sources
    // The Limits tab's draft, saved or not, decides where Fusebox costs come from.
    limitsMode: String(limitsForm.draft.usageSource || "direct")
    limitsUrl: String(limitsForm.draft.proxyUrl || "")
    limitsImplementation: limitsForm.knownImplementation
    onCancelRequested: root.cancelRequested()
    onRevealRequested: function(item) { root.revealRequested(item) }
  }
}
