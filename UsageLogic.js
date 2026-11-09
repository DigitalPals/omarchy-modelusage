.pragma library

// One observer per connection across bars, monitors and open panels. The
// shared object has no panel parent; the final consumer explicitly stops it.
var liveConnections = ({})

function acquireLive(key, factory, properties) {
  var entry = liveConnections[key]
  if (!entry) {
    // Create in this engine-wide library context, not a consumer's context.
    // A parentless object alone still loses its functions when its creator dies.
    if (!factory) factory = Qt.createComponent("UsageLiveConnection.qml")
    var object = factory.createObject(null, properties)
    if (!object) return null
    entry = { object: object, references: 0 }
    liveConnections[key] = entry
  }
  entry.references++
  return entry.object
}

function releaseLive(key) {
  var entry = liveConnections[key]
  if (!entry) return
  entry.references--
  if (entry.references <= 0) {
    delete liveConnections[key]
    entry.object.stop()
  }
}

function validLivePayload(payload) {
  if (!payload || payload.schemaVersion !== 1) return false
  if (payload.heartbeat === true) return true
  if (!contains(["live", "reconnecting", "unavailable"], payload.state)
      || typeof payload.message !== "string" || payload.message.length > 256
      || !isListLike(payload.providers) || payload.providers.length > 4096
      || !isListLike(payload.accounts) || payload.accounts.length > 4096) return false
  var seen = ({})
  for (var p = 0; p < payload.providers.length; p++) {
    var provider = payload.providers[p]
    if (!provider || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(provider.id)
        || !contains(["ok", "ambiguous"], provider.status)
        || (provider.status === "ok" && !/^[a-f0-9]{16}$/.test(provider.accountId))
        || typeof provider.lastUsedAt !== "number" || !isFinite(provider.lastUsedAt)
        || provider.lastUsedAt <= 0) return false
  }
  for (var i = 0; i < payload.accounts.length; i++) {
    var row = payload.accounts[i]
    if (!row || !/^[a-f0-9]{16}$/.test(row.accountId)
        || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(row.provider)) return false
    if (seen[row.accountId]) return false
    seen[row.accountId] = true
    var counts = [row.inFlight, row.sessions]
    for (var j = 0; j < counts.length; j++)
      if (typeof counts[j] !== "number" || !isFinite(counts[j])
          || Math.floor(counts[j]) !== counts[j] || counts[j] < 0 || counts[j] > 1000000) return false
  }
  return payload.state === "live" || payload.accounts.length === 0
}

function accountLoad(account, activity) {
  if (!account || !activity || activity.liveState !== "live") return null
  var rows = listOrEmpty(activity.liveAccounts)
  for (var i = 0; i < rows.length; i++)
    if (rows[i].accountId === account.accountId && rows[i].provider === account.id) return rows[i]
  return null
}

function sessionBadgeText(load) {
  if (!load) return "Sessions unknown"
  return plural(load.sessions, "session")
}

function sessionDetails(load) {
  if (!load) return "Session counts are unknown until Fusebox reconnects."
  return sessionBadgeText(load) + " assigned to this account recently. Sessions may remain assigned after a request finishes."
}

function proxyName(implementation) {
  if (implementation === "rust") return "Fusebox"
  if (implementation === "go") return "CLIProxyAPI"
  return "Fusebox / CLIProxyAPI"
}

// ------------------------------------------------------------ Presentation

// Secondary text keeps the theme foreground at reduced opacity. Qt.darker()
// would make dark (light-theme) foregrounds darker still, inverting hierarchy.
var DIM_OPACITY = 0.66

function alpha(color, opacity) {
  return Qt.rgba(color.r, color.g, color.b, opacity)
}

function dimColor(color) {
  return alpha(color, DIM_OPACITY)
}

function plural(count, noun, nounPlural) {
  return count + " " + (count === 1 ? noun : (nounPlural || noun + "s"))
}

function pad2(value) {
  return (value < 10 ? "0" : "") + value
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Local "HH:mm" for resets within a day, otherwise "MMM d, HH:mm".
function clockText(epochSeconds, nowMs) {
  var date = new Date(epochSeconds * 1000)
  var time = pad2(date.getHours()) + ":" + pad2(date.getMinutes())
  if (epochSeconds * 1000 - nowMs < 86400000) return time
  return MONTHS[date.getMonth()] + " " + date.getDate() + ", " + time
}

// Precise countdown while the panel is open: days/hours, hours/minutes,
// then minutes/seconds in the final hour.
function countdown(seconds) {
  seconds = Math.floor(Number(seconds))
  if (!isFinite(seconds) || seconds <= 0) return ""
  var days = Math.floor(seconds / 86400)
  var hours = Math.floor((seconds % 86400) / 3600)
  var minutes = Math.floor((seconds % 3600) / 60)
  var secs = seconds % 60
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  if (minutes > 0) return minutes + "m " + secs + "s"
  return secs + "s"
}

function resetDue(window, nowMs) {
  var at = Number(window && window.resetsAt)
  return isFinite(at) && at > 0 && at * 1000 <= nowMs
}

// `refreshing` says whether a refresh is running, so a passed reset never
// claims an update that is not happening.
function resetText(window, nowMs, refreshing) {
  var at = Number(window && window.resetsAt)
  if (!isFinite(at) || at <= 0) return ""
  if (at * 1000 <= nowMs) return refreshing ? "Reset due · updating" : "Reset due · awaiting a new reading"
  return "Resets in " + countdown(Math.max(1, Math.ceil(at - nowMs / 1000))) + " · " + clockText(at, nowMs)
}

// Latest reset time that has passed since the reading was fetched, or 0.
// The panel refreshes once per such reset rather than showing a stale meter.
function passedResetAt(providers, fetchedAtMs, nowMs) {
  var latest = 0
  function visit(windows) {
    var rows = listOrEmpty(windows)
    for (var i = 0; i < rows.length; i++) {
      var at = Number(rows[i] && rows[i].resetsAt)
      if (isFinite(at) && at > 0 && at * 1000 > fetchedAtMs && at * 1000 <= nowMs) latest = Math.max(latest, at)
    }
  }
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    if (!list[i] || list[i].status !== "ok") continue
    visit(list[i].windows)
    var accounts = listOrEmpty(list[i].accounts)
    for (var j = 0; j < accounts.length; j++)
      if (accounts[j] && accounts[j].status === "ok") visit(accounts[j].windows)
  }
  return latest
}

function nextRefreshText(nextRefreshAtMs, nowMs) {
  if (!(nextRefreshAtMs > 0)) return ""
  var seconds = Math.max(0, Math.ceil((nextRefreshAtMs - nowMs) / 1000))
  if (seconds <= 0) return "Refreshing soon"
  if (seconds < 60) return "Next refresh in " + seconds + "s"
  return "Next refresh in " + Math.ceil(seconds / 60) + "m"
}

function currencyPrefix(currency) {
  var value = String(currency || "").toUpperCase()
  if (value === "USD") return "$"
  if (value === "EUR") return "€"
  if (value === "GBP") return "£"
  if (value === "CNY") return "¥"
  return value === "" ? "" : value + " "
}

// Money always has cents, like Costs. Amounts without a currency are
// provider credits and say so.
function formatAmount(value, currency) {
  if (value === null || value === undefined || value === "") return "—"
  var amount = Number(value)
  if (!isFinite(amount)) return "—"
  if (String(currency || "") === "") {
    var digits = Math.abs(amount - Math.round(amount)) < 0.001 ? 0 : 2
    return amount.toFixed(digits) + (Math.abs(amount - 1) < 0.001 ? " credit" : " credits")
  }
  return currencyPrefix(currency) + amount.toFixed(2)
}

function present(value) {
  return value !== null && value !== undefined
}

// A prepaid wallet (it reports a funded total) has a balance that is separate
// from its monthly charge cap; other credits are what is left of the cap.
function creditsWallet(credits) {
  return !!credits && present(credits.total)
}

function creditsPrimary(credits) {
  if (!credits) return ""
  if (present(credits.remaining))
    return formatAmount(credits.remaining, credits.currency) + (creditsWallet(credits) ? " balance" : " remaining")
  if (credits.unlimited) return "Unlimited"
  if (present(credits.used)) return formatAmount(credits.used, credits.currency) + " used"
  if (present(credits.resetCreditsAvailable)) return plural(credits.resetCreditsAvailable, "banked reset")
  return "Available"
}

function creditsDetail(credits) {
  if (!credits) return ""
  var parts = []
  if (present(credits.used)) {
    // The meter caption already names the limit; this line gives the amounts.
    if (present(credits.limit))
      parts.push(formatAmount(credits.used, credits.currency) + " of " + formatAmount(credits.limit, credits.currency)
        + (creditsWallet(credits) ? " charged this month" : " used"))
    else parts.push(formatAmount(credits.used, credits.currency) + " used this month")
  }
  if (credits.unlimited && present(credits.remaining)) parts.push("No monthly spending cap")
  if (present(credits.total)) parts.push(formatAmount(credits.total, credits.currency) + " funded")
  // Unless the headline already is the reset count.
  if (present(credits.resetCreditsAvailable) && (present(credits.remaining) || credits.unlimited || present(credits.used)))
    parts.push(plural(credits.resetCreditsAvailable, "banked reset"))
  return parts.join(" · ")
}

// Credits meters fill with what is left of the monthly cap, like every quota meter.
function creditsMeter(credits) {
  if (!credits || !present(credits.used) || !present(credits.limit)) return null
  var used = Number(credits.used), limit = Number(credits.limit)
  if (!isFinite(used) || !isFinite(limit) || limit <= 0) return null
  var remaining = clamp(100 - used / limit * 100, 0, 100)
  var label = creditsWallet(credits) ? "Monthly charge cap" : "Monthly limit"
  return { fraction: remaining / 100, remaining: remaining, label: label + " · " + Math.round(remaining) + "% left" }
}

// Limit names wrap in narrow cards. Keep a number with its unit ("1 day") and
// break after a "·" separator rather than before it.
function limitLabel(label) {
  return String(label || "Usage limit").replace(/ · /g, "\u00a0· ").replace(/(\d) (?=\S)/g, "$1\u00a0")
}

// Whether a provider or any of its accounts holds a last-known reading.
function hasStaleReading(provider) {
  if (!provider) return false
  if (provider.stale === true) return true
  var accounts = listOrEmpty(provider.accounts)
  for (var i = 0; i < accounts.length; i++)
    if (accounts[i] && accounts[i].stale === true) return true
  return false
}

function anyStaleReading(providers) {
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) if (hasStaleReading(list[i])) return true
  return false
}

// A bar chip shows one reading: the last-used account's, or (pool fallback)
// the provider summary, which is stale when any account behind it is.
function chipReadingStale(reading, provider, usingPool) {
  if (reading && reading.stale === true) return true
  return usingPool ? hasStaleReading(provider) : !!provider && provider.stale === true
}

// Why a reading is last-known: the provider's own notice when it has one
// (failed refresh, or an old Fusebox quota cache).
function staleExplanation(reading, provider) {
  var notice = String((reading && reading.stale && reading.notice) || (provider && provider.stale && provider.notice) || "")
  var accounts = listOrEmpty(provider && provider.accounts)
  for (var i = 0; notice === "" && i < accounts.length; i++)
    if (accounts[i] && accounts[i].stale === true && accounts[i].notice) notice = String(accounts[i].notice)
  return notice !== "" ? notice : "Last known reading; it may be out of date."
}

// Earliest reset still in the future, in ms, or 0.
function nextResetAt(providers, nowMs) {
  var earliest = 0
  function visit(windows) {
    var rows = listOrEmpty(windows)
    for (var i = 0; i < rows.length; i++) {
      var at = Number(rows[i] && rows[i].resetsAt) * 1000
      if (isFinite(at) && at > nowMs && (earliest === 0 || at < earliest)) earliest = at
    }
  }
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    if (!list[i] || list[i].status !== "ok") continue
    visit(list[i].windows)
    var accounts = listOrEmpty(list[i].accounts)
    for (var j = 0; j < accounts.length; j++)
      if (accounts[j] && accounts[j].status === "ok") visit(accounts[j].windows)
  }
  return earliest
}

// Providers that earn a bar chip: a reading, or an error the user must see.
function barProviders(providers) {
  var result = []
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    if (!list[i]) continue
    if (minRemaining(list[i]) !== null || list[i].status === "error") result.push(list[i])
  }
  return result
}

// A credential sent in clear text to another machine deserves a warning.
function insecureRemoteUrl(text) {
  var match = /^http:\/\/([^\/?#\s]*)/i.exec(String(text || "").trim())
  if (!match) return false
  var authority = match[1]
  var host = authority.slice(authority.lastIndexOf("@") + 1).toLowerCase()
  // An unterminated IPv6 literal is not a loopback address: warn.
  if (host.charAt(0) === "[" && host.indexOf("]") < 0) return true
  host = host.charAt(0) === "[" ? host.slice(0, host.indexOf("]") + 1) : host.split(":")[0]
  if (host === "localhost" || /\.localhost$/.test(host)) return false
  var octets = /^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host)
  if (octets && Number(octets[1]) <= 255 && Number(octets[2]) <= 255 && Number(octets[3]) <= 255) return false
  if (/^\[(?:0{0,4}:){2,7}0{0,3}1\]$/.test(host) || host === "[::ffff:127.0.0.1]") return false
  return host !== ""
}

// ------------------------------------------------------------ Connection settings

var DEFAULT_PROXY_URL = "http://127.0.0.1:8317"
// Settings renamed after 1.4. Old names are read until the next save migrates them.
var LEGACY_SETTINGS = {
  proxyUrl: "cliproxyUrl",
  proxyKeyFile: "cliproxyKeyFile",
  keeperUrl: "costKeeperUrl",
  keeperPasswordFile: "costKeeperPasswordFile"
}

function setting(settings, name, fallback) {
  var value = settings ? settings[name] : undefined
  if ((value === undefined || value === null) && settings && LEGACY_SETTINGS[name])
    value = settings[LEGACY_SETTINGS[name]]
  return value === undefined || value === null ? fallback : value
}

function usageSource(settings) {
  var value = setting(settings, "usageSource", "direct")
  return value === "proxy" || value === "cliproxy" ? "proxy" : "direct"
}

function proxyConnection(settings) {
  return {
    url: String(setting(settings, "proxyUrl", DEFAULT_PROXY_URL)).trim(),
    keyFile: String(setting(settings, "proxyKeyFile", "")).trim()
  }
}

// Costs reads Fusebox through the Limits connection unless a different
// server was chosen. Older settings with their own Costs URL stay separate.
function fuseboxCostMode(settings) {
  var value = setting(settings, "costFuseboxConnection", "")
  if (value === "limits" || value === "custom") return value
  return String(setting(settings, "costFuseboxUrl", "")).trim() !== "" ? "custom" : "limits"
}

function fuseboxCostConnection(settings) {
  var mode = fuseboxCostMode(settings)
  var limits = proxyConnection(settings)
  var custom = mode === "custom"
  return {
    enabled: setting(settings, "costFuseboxEnabled", false) === true,
    mode: mode,
    url: custom ? String(setting(settings, "costFuseboxUrl", "")).trim() : limits.url,
    keyFile: custom ? String(setting(settings, "costFuseboxKeyFile", "")).trim() : limits.keyFile,
    overlap: setting(settings, "costFuseboxOverlap", "fusebox") === "transcripts" ? "transcripts" : "fusebox"
  }
}

function migrateSettings(entry) {
  var result = Object.assign({}, entry || {})
  for (var name in LEGACY_SETTINGS) {
    var legacy = LEGACY_SETTINGS[name]
    if (result[name] === undefined || result[name] === null) {
      if (result[legacy] !== undefined && result[legacy] !== null) result[name] = result[legacy]
    }
    delete result[legacy]
  }
  if (result.usageSource !== undefined) result.usageSource = usageSource(result)
  result.costFuseboxConnection = fuseboxCostMode(result)
  return result
}

// Command-line arguments shared by every proxy script.
function proxyArgs(url, keyFile, implementation) {
  var args = ["--proxy-url", String(url || "").trim() || DEFAULT_PROXY_URL]
  if (String(keyFile || "").trim() !== "") args.push("--proxy-key-file", String(keyFile).trim())
  if (implementation === "go" || implementation === "rust") args.push("--implementation", implementation)
  return args
}

function validServerUrl(text) {
  var value = String(text || "").trim()
  return /^https?:\/\/[^\s/?#@]+(?:\/[^\s?#]*)?$/.test(value)
    && !/(?:^|\/)\.{1,2}(?:\/|$)/.test(value.replace(/^https?:\/\/[^/]*/, ""))
}

// The rule management-key.py applies when saving a key or password.
function validSecret(text) {
  var value = String(text || "").trim()
  return value !== "" && value.length <= 8191 && /^[\x20-\x7e]+$/.test(value)
}

function clamp(value, minimum, maximum) {
  var number = Number(value)
  if (!isFinite(number)) return minimum
  return Math.max(minimum, Math.min(maximum, number))
}

function isListLike(value) {
  if (!value || typeof value !== "object" || value.length === undefined) return false
  var length = Number(value.length)
  return isFinite(length) && length >= 0 && Math.floor(length) === length
}

function listOrEmpty(value) {
  return isListLike(value) ? value : []
}

function firstItems(value, limit) {
  var source = listOrEmpty(value)
  var count = Math.max(0, Math.min(Number(source.length), Math.floor(Number(limit) || 0)))
  var result = []
  for (var i = 0; i < count; i++) result.push(source[i])
  return result
}

function contains(value, needle) {
  var source = listOrEmpty(value)
  for (var i = 0; i < source.length; i++) {
    if (source[i] === needle) return true
  }
  return false
}

function minRemaining(provider) {
  if (!provider || provider.status !== "ok") return null
  // Repeater delegates expose nested JSON arrays as QML list-like objects on
  // some Quickshell builds. They still have length/index access, but fail
  // Array.isArray(), so do not reject them solely on that basis.
  var windows = provider.windows
  if (!isListLike(windows) || Number(windows.length) <= 0) return null
  var remaining = 101
  for (var i = 0; i < Number(windows.length); i++) {
    var row = windows[i]
    // Separate feature allowances never limit ordinary requests.
    if (row && row.informational === true) continue
    var raw = row ? row.remaining : null
    if (raw === null || raw === undefined || raw === "") continue
    var value = Number(raw)
    if (isFinite(value)) remaining = Math.min(remaining, value)
  }
  return remaining <= 100 ? clamp(remaining, 0, 100) : null
}

function severity(provider, warningThreshold, criticalThreshold) {
  var remaining = minRemaining(provider)
  if (remaining === null) return provider && provider.status === "error" ? "error" : "none"
  var critical = clamp(criticalThreshold, 0, 100)
  var warning = Math.max(critical, clamp(warningThreshold, 0, 100))
  if (remaining <= critical) return "critical"
  if (remaining <= warning) return "warning"
  return "ok"
}

function meaningfulProviders(providers) {
  var result = []
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    if (minRemaining(list[i]) !== null) result.push(list[i])
  }
  return result
}

function availableProviders(providers) {
  function available(reading) {
    return reading && reading.status !== "disabled" && reading.errorKind !== "no_credentials"
  }
  var result = []
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    var provider = list[i]
    // Keep connection-level errors visible so the user can fix proxy setup.
    if (provider && provider.id === "cliproxy") {
      result.push(provider)
      continue
    }
    var accounts = listOrEmpty(provider && provider.accounts)
    if (accounts.length > 0) {
      for (var j = 0; j < accounts.length; j++) {
        if (available(accounts[j])) {
          result.push(provider)
          break
        }
      }
    } else if (available(provider)) {
      result.push(provider)
    }
  }
  return result
}

function selectedProviders(providers, ids) {
  var result = []
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    if (list[i] && contains(ids, list[i].id)) result.push(list[i])
  }
  return result
}

function lastUsedAccount(provider, activityProviders, hideEmails) {
  var activity = listOrEmpty(activityProviders)
  var last = null
  for (var i = 0; i < activity.length; i++)
    if (provider && activity[i].id === provider.id) last = activity[i]
  if (!last) return { label: "Unknown", reading: null, lastUsedAt: 0 }
  if (last.status === "ambiguous")
    return { label: "Multiple accounts", reading: null, lastUsedAt: last.lastUsedAt }
  var accounts = listOrEmpty(provider && provider.accounts)
  for (var j = 0; j < accounts.length; j++) {
    if (last.status === "ok" && accounts[j].accountId === last.accountId)
      return { label: hideEmails ? "Account " + (j + 1) : String(accounts[j].account || "Account " + (j + 1)),
        reading: accounts[j], lastUsedAt: last.lastUsedAt }
  }
  // Account inventory and activity refresh independently. Never substitute the
  // pool's best-quota account when a new/deleted account cannot be matched.
  return { label: "Unknown", reading: null, lastUsedAt: last.lastUsedAt }
}

function providerMark(providerId) {
  if (providerId === "claude") return "C"
  if (providerId === "codex") return "O"
  if (providerId === "kimi") return "K"
  return String(providerId || "?").charAt(0).toUpperCase()
}

function accountPlanLabel(account) {
  if (!account) return ""
  var plan = String(account.planType || account.plan || "")
  var normalized = plan.toLowerCase().replace(/^chatgpt\s+/, "").replace(/[-_ ]/g, "")
  if (account.id === "codex") {
    if (normalized === "pro" || normalized === "pro20x") return "Codex Pro · 20×"
    if (normalized === "prolite" || normalized === "pro5x") return "Codex Pro · 5×"
  }
  return String(account.plan || account.name || account.id || "Account")
}

function supportsAccountReset(account) {
  if (!account || account.status !== "ok" || account.supportsBankedReset === false) return false
  // Fusebox redeems Claude and Codex resets; CLIProxyAPI only Codex.
  return account.id === "codex" || account.id === "claude" && account.proxyImplementation === "rust"
}

function accountResetLabel(account) {
  if (!supportsAccountReset(account)) return ""
  var count = account.credits && account.credits.resetCreditsAvailable
  if (typeof count !== "number" || !isFinite(count) || count < 0 || Math.floor(count) !== count) return ""
  return plural(count, "banked reset")
}

function shortDuration(seconds) {
  seconds = Math.floor(Number(seconds))
  if (!isFinite(seconds)) return ""
  if (seconds <= 0) return "now"
  var days = Math.floor(seconds / 86400)
  var hours = Math.floor((seconds % 86400) / 3600)
  var minutes = Math.floor((seconds % 3600) / 60)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  return Math.max(1, minutes) + "m"
}

// Fusebox account facts: renewals as a date, cooldowns as a countdown.
function accountStatusText(item, nowMs) {
  if (!item || !item.text) return ""
  var text = String(item.text)
  var at = Number(item.at)
  if (item.at === null || item.at === undefined || !isFinite(at) || at <= 0) return text
  if (item.kind === "renewal") {
    var date = new Date(at * 1000)
    return text + " " + MONTHS[date.getMonth()] + " " + date.getDate()
      + (item.estimated === true ? " (estimated)" : "")
  }
  var remaining = at - Number(nowMs) / 1000
  if (!isFinite(remaining) || remaining <= 0) return ""
  return text + " · " + shortDuration(remaining)
}

function accountStatusItems(account, nowMs) {
  var rows = listOrEmpty(account && account.statusItems)
  var result = []
  for (var i = 0; i < rows.length && result.length < 6; i++) {
    var text = accountStatusText(rows[i], nowMs)
    if (text !== "") result.push({ text: text, urgent: rows[i].kind === "error" || rows[i].kind === "warning"
      || rows[i].kind === "cooldown" })
  }
  return result
}

function windowRemaining(window) {
  if (!window || window.remaining === null || window.remaining === undefined || window.remaining === "") return null
  var value = Number(window.remaining)
  return isFinite(value) ? value : null
}

// Severity of one limit window. Informational allowances never limit requests.
function windowSeverity(window, warningThreshold, criticalThreshold) {
  if (!window || window.informational === true) return "none"
  var remaining = windowRemaining(window)
  if (remaining === null) return "none"
  var critical = clamp(criticalThreshold, 0, 100)
  var warning = Math.max(critical, clamp(warningThreshold, 0, 100))
  if (remaining <= critical) return "critical"
  if (remaining <= warning) return "warning"
  return "ok"
}

function primaryAccountWindows(rows) {
  var overall = [], weekly = [], monthly = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var label = String(row.label || "")
    var seconds = Number(row.windowSeconds)
    if (/^weekly(?: limit)?$/i.test(label)) overall.push(row)
    if (seconds === 604800 || /weekly/i.test(label)) weekly.push(row)
    if (/^monthly(?: limit)?$/i.test(label)) monthly.push(row)
  }
  if (overall.length) return overall
  if (weekly.length) return weekly
  if (monthly.length) return monthly
  // Plans without a weekly/monthly allowance still show their real main window.
  return firstItems(rows, 1)
}

// The compact account view shows the main weekly/monthly allowance. A shorter
// window at warning or critical level that is tighter than that allowance is
// what actually limits requests (e.g. a spent 5-hour limit), so it is shown
// too, first and tightest first.
function accountWindows(account, expanded, warningThreshold, criticalThreshold) {
  return selectAccountWindows(listOrEmpty(account && account.windows), expanded, warningThreshold, criticalThreshold)
}

function selectAccountWindows(rows, expanded, warningThreshold, criticalThreshold) {
  if (expanded) return rows
  var shown = primaryAccountWindows(rows)
  if (warningThreshold === undefined || warningThreshold === null) return shown
  var shownMinimum = 101
  for (var i = 0; i < shown.length; i++) {
    var value = windowRemaining(shown[i])
    if (value !== null && shown[i].informational !== true) shownMinimum = Math.min(shownMinimum, value)
  }
  var binding = []
  for (var j = 0; j < rows.length; j++) {
    var row = rows[j]
    if (contains(shown, row) || row.informational === true) continue
    var remaining = windowRemaining(row)
    var level = windowSeverity(row, warningThreshold, criticalThreshold)
    if (remaining !== null && remaining < shownMinimum && (level === "warning" || level === "critical"))
      binding.push(row)
  }
  binding.sort(function(a, b) { return windowRemaining(a) - windowRemaining(b) })
  return binding.concat(Array.prototype.slice.call(shown))
}

// Whether "Additional limits" would reveal anything for these accounts.
function hasAdditionalWindows(accounts, warningThreshold, criticalThreshold) {
  var list = listOrEmpty(accounts)
  for (var i = 0; i < list.length; i++) {
    if (!list[i] || list[i].status !== "ok") continue
    if (accountWindows(list[i], false, warningThreshold, criticalThreshold).length
        < listOrEmpty(list[i].windows).length) return true
  }
  return false
}

// ------------------------------------------------------------ Compact rows

// One line per account or limit. The row's meter shows the main allowance;
// everything else is in the row tooltip, or inline when Details is open.

// "Weekly limit" → "Weekly". Rows and column captions omit the word "limit".
function shortLimitLabel(label) {
  var text = String(label || "").replace(/\s+limit$/i, "").trim()
  return text === "" ? "Usage" : text
}

// The meter an account row shows (its first weekly/monthly allowance, or its
// only window), and the windows shown beneath it: tighter shorter windows
// and other main allowances, or, expanded, every other window. One list is
// read once, so the main window is found by identity on every Quickshell build.
function accountRowWindows(account, expanded, warningThreshold, criticalThreshold) {
  var rows = Array.prototype.slice.call(listOrEmpty(account && account.windows))
  var primary = primaryAccountWindows(rows)
  var main = primary.length > 0 ? primary[0] : null
  var shown = selectAccountWindows(rows, expanded, warningThreshold, criticalThreshold)
  var extra = []
  for (var i = 0; i < shown.length; i++) if (shown[i] !== main) extra.push(shown[i])
  return { main: main, extra: extra }
}

// The header caption over the percentage and reset columns: "weekly · resets"
// when every account's meter is the same allowance.
function accountsCaption(accounts) {
  var list = listOrEmpty(accounts)
  var labels = []
  for (var i = 0; i < list.length; i++) {
    if (!list[i] || list[i].status !== "ok") continue
    var main = accountRowWindows(list[i], false).main
    if (!main) continue
    var label = shortLimitLabel(main.label)
    if (/^(?:weekly|monthly|daily|\d+ hour)$/i.test(label)) label = label.toLowerCase()
    if (labels.indexOf(label) < 0) labels.push(label)
  }
  if (labels.length === 1) return labels[0] + " · resets"
  return labels.length > 1 ? "left · resets" : ""
}

function hasPlan(account) {
  return !!account && String(account.planType || account.plan || "") !== ""
}

// A plan every account shares heads the card; mixed plans name the provider
// and tag each row with its own plan instead.
function providerTitle(provider, accounts) {
  var list = listOrEmpty(accounts)
  var plans = []
  for (var i = 0; i < list.length; i++) {
    if (!hasPlan(list[i])) continue
    var plan = accountPlanLabel(list[i])
    if (plans.indexOf(plan) < 0) plans.push(plan)
  }
  if (plans.length === 1) return plans[0]
  if (list.length === 0 && provider && String(provider.plan || "") !== "") return accountPlanLabel(provider)
  return String(provider && (provider.name || provider.id) || "Provider")
}

// "Codex Pro · 5×" → "Pro · 5×" beside an account whose plan differs from
// the card title.
function accountPlanTag(account, title) {
  if (!hasPlan(account)) return ""
  var plan = accountPlanLabel(account)
  if (plan === title) return ""
  var words = plan.split(" ")
  return words.length > 1 ? words.slice(1).join(" ") : plan
}

function accountDisplayName(account, index, hideEmails) {
  return hideEmails ? "Account " + index : String(account && account.account || "Account " + index)
}

// Replaces an account's meter when it has no current reading.
function accountIssue(account) {
  if (!account || account.status === "ok") return ""
  if (account.status === "disabled") return "Paused"
  if (account.status === "error") {
    switch (account.errorKind) {
    case "expired": return "Sign-in expired"
    case "no_credentials": return "Sign-in required"
    case "rate_limited": return "Rate limited"
    case "timeout": return "Timed out"
    case "config": return "Configuration required"
    default: return "Unavailable"
    }
  }
  return String(account.notice || "Quota unavailable")
}

function errorBody(provider) {
  if (!provider) return ""
  var message = String(provider.message || "Usage data is unavailable.")
  if (provider.authCommand && (provider.errorKind === "no_credentials" || provider.errorKind === "expired"))
    message += " Run “" + provider.authCommand + "” in a terminal, then refresh."
  return message
}

function remainingText(window, stale) {
  var remaining = windowRemaining(window)
  return remaining === null ? "—" : Math.round(remaining) + "%" + (stale ? "?" : "")
}

// The reset column: "1d 21h", "3h 12m", "42m", or "due" once it has passed.
function resetShort(window, nowMs) {
  var at = Number(window && window.resetsAt)
  if (!isFinite(at) || at <= 0) return ""
  if (at * 1000 <= nowMs) return "due"
  return shortDuration(Math.ceil(at - nowMs / 1000))
}

// "Resets Nov 11, 17:00" for the Details line, beside the row's countdown.
function resetDate(window, nowMs, refreshing) {
  var at = Number(window && window.resetsAt)
  if (!isFinite(at) || at <= 0) return ""
  if (at * 1000 <= nowMs) return refreshing ? "Reset due · updating" : "Reset due · awaiting a new reading"
  return "Resets " + clockText(at, nowMs)
}

// "Resets Nov 11, 17:00 (in 1d 21h)" for tooltips, with the row's countdown.
function resetClause(window, nowMs, refreshing) {
  var text = resetDate(window, nowMs, refreshing)
  var at = Number(window && window.resetsAt)
  if (text === "" || at * 1000 <= nowMs) return text
  return text + " (in " + resetShort(window, nowMs) + ")"
}

// One tooltip line per limit: "Weekly limit: 85% left · resets 17:00 (in 3h 2m)".
function windowSummary(window, nowMs, refreshing) {
  if (!window) return ""
  var remaining = windowRemaining(window)
  var text = String(window.label || "Usage limit") + ": "
    + (remaining === null ? "unknown" : Math.round(remaining) + "% left")
  var reset = resetClause(window, nowMs, refreshing)
  if (reset !== "") text += " · " + reset.charAt(0).toLowerCase() + reset.slice(1)
  if (window.detail) text += " · " + String(window.detail)
  if (window.informational === true) text += " · informational"
  return text
}

// The Details line under a limit row.
function windowFacts(window, nowMs, refreshing) {
  if (!window) return ""
  var parts = []
  var reset = resetDate(window, nowMs, refreshing)
  if (reset !== "") parts.push(reset)
  if (window.detail) parts.push(String(window.detail))
  return parts.join(" · ")
}

function accountCreditsText(account) {
  var credits = account && account.credits
  if (!credits || !(present(credits.remaining) || present(credits.used) || credits.unlimited)) return ""
  return String(credits.label || "Credits") + ": " + creditsPrimary(credits)
}

// Everything about one account, for its row tooltip: plan, every limit,
// Fusebox facts, credits, banked resets, sessions and reading age.
function accountDetails(account, options) {
  if (!account) return ""
  var opts = options || {}
  var lines = []
  var plan = hasPlan(account) ? accountPlanLabel(account) : ""
  lines.push(String(opts.label || "Account") + (plan !== "" ? " · " + plan : ""))
  if (account.status === "error") lines.push(errorBody(account))
  else if (account.status !== "ok") lines.push(accountIssue(account))
  var windows = account.status === "ok" ? listOrEmpty(account.windows) : []
  for (var i = 0; i < windows.length && i < 12; i++) lines.push(windowSummary(windows[i], opts.nowMs, opts.refreshing))
  if (account.status === "ok" && windows.length === 0) lines.push("No subscription limits reported.")
  // Fact countdowns tick per minute, like the urgent facts under the row.
  var facts = accountStatusItems(account, opts.minuteMs !== undefined ? opts.minuteMs : opts.nowMs)
  for (var j = 0; j < facts.length; j++) lines.push(facts[j].text)
  var credits = accountCreditsText(account)
  if (credits !== "") lines.push(credits)
  var resets = accountResetLabel(account)
  if (resets !== "") lines.push(resets + (opts.resetEnabled ? " · click ↺ to apply one" : ""))
  if (opts.liveActivity) lines.push(sessionDetails(opts.load || null))
  if (account.stale === true) lines.push(String(account.notice || "Last known reading; it may be out of date."))
  return lines.join("\n")
}

// The Details line under an account row: when its meter resets, and the
// account facts that are not urgent (urgent ones are always shown).
function accountFacts(account, main, nowMs, refreshing) {
  if (!account) return ""
  var parts = []
  var reset = resetDate(main, nowMs, refreshing)
  if (reset !== "") parts.push(reset)
  var facts = accountStatusItems(account, nowMs)
  for (var i = 0; i < facts.length; i++) if (!facts[i].urgent) parts.push(facts[i].text)
  var credits = accountCreditsText(account)
  if (credits !== "") parts.push(credits)
  if (account.stale === true) parts.push(String(account.notice || "Last known reading"))
  return parts.join(" · ")
}

// Urgent Fusebox facts (cooldowns, warnings, errors) stay visible under the row.
function urgentAccountFacts(account, nowMs) {
  var facts = accountStatusItems(account, nowMs)
  var result = []
  for (var i = 0; i < facts.length; i++) if (facts[i].urgent) result.push(facts[i].text)
  return result
}

// Local providers keep a 24H/7D chart; managed accounts have none.
function hasQuotaHistory(provider) {
  if (!provider || provider.status !== "ok" || listOrEmpty(provider.accounts).length > 0) return false
  var history = provider.history
  return !!history && ((isListLike(history.h24) && history.h24.length > 0)
    || (isListLike(history.d7) && history.d7.length > 0))
}

// The line under the Limits tabs: "7 accounts · 3 providers".
function limitsContext(providers, proxyMode) {
  var list = listOrEmpty(providers)
  var accounts = 0
  for (var i = 0; i < list.length; i++) accounts += listOrEmpty(list[i] && list[i].accounts).length
  var parts = []
  if (proxyMode && accounts > 0) parts.push(plural(accounts, "account"))
  if (list.length > 1) parts.push(plural(list.length, "provider"))
  return parts.join(" · ")
}

function errorTitle(provider) {
  if (!provider) return "Provider unavailable"
  var name = String(provider.name || provider.id || "Provider")
  switch (provider.errorKind) {
  case "config": return proxyName(provider.proxyImplementation) + " configuration required"
  case "no_credentials": return name + " sign-in required"
  case "expired": return name + " sign-in expired"
  case "rate_limited": return name + " is rate limited"
  case "timeout": return name + " timed out"
  case "cli_unavailable": return name + " CLI unavailable"
  default: return name + " usage unavailable"
  }
}

function preserveProxyReadings(previous, next) {
  if (!previous || previous.source !== "cliproxy") return next
  if (previous.proxyImplementation && next.proxyImplementation
      && previous.proxyImplementation !== next.proxyImplementation) return next
  if (!next.proxyImplementation && previous.proxyImplementation)
    next.proxyImplementation = previous.proxyImplementation
  function retain(old, fresh) {
    if (!old || !fresh || fresh.status !== "error" || old.status !== "ok") return fresh
    if (old.proxyImplementation && fresh.proxyImplementation
        && old.proxyImplementation !== fresh.proxyImplementation) return fresh
    if (fresh.errorKind === "malformed" || fresh.supportsBankedReset === false
        && fresh.proxyImplementation !== old.proxyImplementation) return fresh
    if (fresh.proxyImplementation === "rust" && fresh.errorKind === "quota_unavailable") return fresh
    return Object.assign({}, fresh, {
      status: "ok", stale: true, windows: old.windows, credits: old.credits,
      plan: old.plan, account: old.account, fetchedAt: old.fetchedAt,
      notice: "Last known reading · " + String(fresh.message || "Refresh failed.")
    })
  }
  var oldProviders = listOrEmpty(previous.providers)
  if (next.providers.length === 1 && next.providers[0].id === "cliproxy" && next.providers[0].status === "error"
      && oldProviders.length > 0 && oldProviders[0].id !== "cliproxy") {
    var failure = next.providers[0]
    next.providers = Array.prototype.map.call(oldProviders, function(old) {
      var fresh = Object.assign({}, old, { status: "error", message: failure.message, errorKind: failure.errorKind })
      fresh.accounts = Array.prototype.map.call(listOrEmpty(old.accounts), function(account) {
        return retain(account, Object.assign({}, account, { status: "error", message: failure.message }))
      })
      return retain(old, fresh)
    })
  }
  next.providers = listOrEmpty(next.providers).map(function(fresh) {
    var old = null
    for (var i = 0; i < oldProviders.length; i++)
      if (oldProviders[i].id === fresh.id) old = oldProviders[i]
    var accounts = listOrEmpty(fresh.accounts).map(function(account) {
      var prior = listOrEmpty(old && old.accounts)
      for (var j = 0; j < prior.length; j++)
        if (prior[j].accountId === account.accountId) return retain(prior[j], account)
      return account
    })
    var result = old && old.accountId === fresh.accountId ? retain(old, fresh) : fresh
    if (fresh.accounts) result.accounts = accounts
    return result
  })
  return next
}

// Custom cost rates are stored as JSON for the manifest's string setting, but
// edited as ordinary fields. Model IDs deliberately keep case and prefixes.
function costPriceError(message, rowIndex, fieldKey) {
  var error = new Error(message)
  error.rowIndex = rowIndex
  error.fieldKey = fieldKey
  return error
}

function encodeCostPrices(rows) {
  var fields = ["inputCostPerMillionTokens", "outputCostPerMillionTokens",
    "cacheReadCostPerMillionTokens", "cacheWriteCostPerMillionTokens"]
  var result = Object.create(null)
  if (rows.length > 128) throw new Error("Custom prices support at most 128 models.")
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var model = String(row.model || "").trim()
    if (!model || model.length > 256 || /[\x00-\x1f]/.test(model))
      throw costPriceError("Enter a model ID of 1–256 characters for custom price " + (i + 1) + ".", i, "modelId")
    if (Object.prototype.hasOwnProperty.call(result, model))
      throw costPriceError("Each custom price must use a different model ID.", i, "modelId")
    var bare = model.toLowerCase().split("/").pop().split("[")[0]
    if (["<unattributed>", "<synthetic>", "synthetic"].indexOf(bare) >= 0)
      throw costPriceError("Custom prices require an attributable model ID.", i, "modelId")
    var prices = {}
    for (var j = 0; j < fields.length; j++) {
      var raw = row[fields[j]]
      var value = raw === undefined ? "" : String(raw).trim()
      if (j >= 2 && value === "") continue
      if (value === "" || !/^(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(value)
          || !isFinite(Number(value)) || Number(value) > 1000000000)
        throw costPriceError("Enter input/output prices from 0 to 1,000,000,000 USD per million tokens; cache prices may be blank.", i, fields[j])
      prices[fields[j]] = Number(value)
    }
    result[model] = prices
  }
  var json = JSON.stringify(result)
  if (encodeURIComponent(json).replace(/%[0-9A-F]{2}/gi, "x").length > 65536)
    throw new Error("Custom prices exceed the 64 KiB limit.")
  return json
}

function decodeCostPrices(raw) {
  if (typeof raw !== "string" || raw.length > 65536)
    throw new Error("Saved custom prices are invalid. Remove them to restore automatic pricing.")
  var document = JSON.parse(raw)
  if (!document || typeof document !== "object" || Array.isArray(document))
    throw new Error("Saved custom prices must be an object.")
  var fields = ["inputCostPerMillionTokens", "outputCostPerMillionTokens",
    "cacheReadCostPerMillionTokens", "cacheWriteCostPerMillionTokens"]
  var rows = Object.keys(document).map(function(model) {
    var prices = document[model]
    if (!prices || typeof prices !== "object" || Array.isArray(prices)
        || Object.keys(prices).some(function(key) { return fields.indexOf(key) < 0 }))
      throw new Error("Saved custom prices contain unsupported fields.")
    var row = { model: model }
    for (var i = 0; i < fields.length; i++) {
      var value = prices[fields[i]]
      if (value !== undefined && (typeof value !== "number" || !isFinite(value)))
        throw new Error("Saved custom prices must be numeric.")
      row[fields[i]] = value === undefined ? "" : String(value)
    }
    return row
  })
  encodeCostPrices(rows)
  return rows
}
