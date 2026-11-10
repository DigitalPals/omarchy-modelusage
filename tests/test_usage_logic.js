const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "UsageLogic.js"), "utf8")
  .replace(/^\.pragma library\s*/m, "");
const context = { Array, Date, Math, Number, String, isFinite };
vm.createContext(context);
vm.runInContext(source, context, { filename: "UsageLogic.js" });

const provider = (id, remaining, status = "ok") => ({
  id,
  name: id,
  status,
  windows: remaining === null ? [] : [{ remaining }],
});

assert.equal(context.minRemaining(provider("claude", 72)), 72);
assert.equal(context.minRemaining({ ...provider("codex", 44), windows: [{ remaining: 91 }, { remaining: 44 }] }), 44);
assert.equal(context.minRemaining({ ...provider("codex", 44), windows: { 0: { remaining: 62 }, length: 1 } }), 62);
assert.equal(context.minRemaining(provider("claude", null)), null);
assert.equal(context.minRemaining({ ...provider("codex", 44), windows: [{ remaining: null }] }), null);
assert.equal(context.severity(provider("kimi", 9), 25, 10), "critical");
assert.equal(context.severity(provider("kimi", 20), 25, 10), "warning");
assert.equal(context.severity(provider("kimi", 80), 25, 10), "ok");
assert.equal(context.severity(provider("kimi", null, "error"), 25, 10), "error");
const listLike = { 0: "first", 1: "second", length: 2 };
assert.equal(context.isListLike(listLike), true);
assert.equal(context.isListLike("not a list"), false);
assert.equal(context.isListLike({ length: 1.5 }), false);
assert.equal(context.contains(listLike, "second"), true);
assert.equal(context.contains(listLike, "missing"), false);
assert.equal(JSON.stringify(context.firstItems(listLike, 1)), '["first"]');
assert.equal(JSON.stringify(context.listOrEmpty(null)), "[]");
assert.equal(context.errorTitle({ id: "claude", name: "Claude Code", errorKind: "expired" }), "Claude Code sign-in expired");

const providers = [provider("claude", 72), provider("codex", 44), provider("kimi", null, "error")];
const selected = context.selectedProviders(providers, { 0: "codex", 1: "kimi", length: 2 });
assert.equal(selected.length, 2);
assert.equal(selected[0].id, "codex");
assert.equal(context.meaningfulProviders(selected).length, 1);
assert.equal(context.selectedProviders(providers, []).length, 0);
assert.equal(providers.length, 3);

const discovered = [
  { id: "claude", status: "ok", accounts: [{ status: "disabled" }, { status: "ok" }] },
  { id: "codex", status: "error", accounts: { 0: { status: "error", errorKind: "timeout" }, length: 1 } },
  { id: "xai", status: "disabled", accounts: [{ status: "disabled" }] },
  { id: "kimi", status: "error", errorKind: "no_credentials" },
  { id: "gemini", status: "unsupported", accounts: [{ status: "unsupported" }] },
];
assert.equal(JSON.stringify(context.availableProviders(discovered).map(row => row.id)),
  '["claude","codex","gemini"]', "hide unconnected or paused providers, retain active accounts even when quota checks fail");
assert.equal(context.availableProviders([{ id: "cliproxy", status: "error", errorKind: "no_credentials" }]).length,
  1, "proxy setup errors must remain visible");
assert.equal(context.availableProviders(null).length, 0);
assert.equal(discovered.length, 5, "filtering does not change backend discovery");

const priorAccount = { ...provider("antigravity", 75), accountId: "a", plan: "Pro", fetchedAt: "then" };
const oldProxy = { source: "cliproxy", providers: [{ ...priorAccount, accounts: [priorAccount] }] };
const failedAccount = { ...priorAccount, status: "error", windows: [], message: "Timeout" };
const stale = context.preserveProxyReadings(oldProxy, { source: "cliproxy",
  providers: [{ ...failedAccount, accounts: [failedAccount] }] });
assert.equal(stale.providers[0].accounts[0].windows[0].remaining, 75);
assert.equal(stale.providers[0].accounts[0].stale, true);
assert.equal(stale.providers[0].fetchedAt, "then");
const outage = context.preserveProxyReadings(oldProxy, { providers: [{ id: "cliproxy", status: "error", message: "Offline" }] });
assert.equal(outage.providers[0].id, "antigravity");
assert.equal(outage.providers[0].stale, true);
const paused = context.preserveProxyReadings(oldProxy, { providers: [{ ...priorAccount, status: "disabled", windows: [] }] });
assert.equal(paused.providers[0].status, "disabled");
assert.equal(paused.providers[0].windows.length, 0);

const accountPool = { ...provider("codex", 90), accounts: [
  { ...provider("codex", 90), accountId: "one", account: "one@example.invalid" },
  { ...provider("codex", 23), accountId: "two", account: "two@example.invalid" },
] };
const recent = [{ id: "codex", status: "ok", accountId: "two", lastUsedAt: 123 }];
let lastAccount = context.lastUsedAccount(accountPool, recent, true);
assert.equal(lastAccount.label, "Account 2");
assert.equal(context.minRemaining(lastAccount.reading), 23, "quota must belong to the last account, not the best account");
assert.equal(lastAccount.lastUsedAt, 123);
assert.equal(context.lastUsedAccount(accountPool, recent, false).label, "two@example.invalid");
assert.equal(context.lastUsedAccount(accountPool, [{ ...recent[0], accountId: "one" }], true).label, "Account 1");
assert.equal(context.lastUsedAccount(accountPool, [], true).reading, null);
assert.equal(context.lastUsedAccount(accountPool, [{ ...recent[0], accountId: "removed" }], true).reading, null);
assert.equal(context.lastUsedAccount(accountPool, [{ ...recent[0], status: "ambiguous" }], true).label, "Multiple accounts");
assert.equal(context.lastUsedAccount({ ...accountPool, accounts: { 0: accountPool.accounts[1], length: 1 } }, recent, true).label, "Account 1");
assert.equal(context.minRemaining(context.lastUsedAccount({ ...accountPool, accounts: [
  { ...accountPool.accounts[1], status: "disabled", windows: [] }
] }, recent, true).reading), null);
console.log("UsageLogic.js: all assertions passed");

const codexWindows = [
  {id: "additional-secondary", label: "Code review · Weekly limit", windowSeconds: 604800},
  {id: "codex-primary", label: "5 hour limit", windowSeconds: 18000},
  {id: "codex-secondary", label: "Weekly limit", windowSeconds: 604800}
];
assert.equal(context.accountWindows({windows: codexWindows}, false).length, 1);
assert.equal(context.accountWindows({windows: codexWindows}, false)[0].id, "codex-secondary");
assert.equal(context.accountWindows({windows: codexWindows}, true).length, 3);
assert.equal(context.accountWindows({windows: [{label: "Monthly limit"}]}, false)[0].label, "Monthly limit");
assert.equal(context.accountWindows({windows: []}, false).length, 0);
assert.equal(context.accountPlanLabel({id: "codex", planType: "pro"}), "Codex Pro · 20×");
assert.equal(context.accountPlanLabel({id: "codex", planType: "prolite"}), "Codex Pro · 5×");
assert.equal(context.accountPlanLabel({id: "codex", plan: "ChatGPT Pro"}), "Codex Pro · 20×");

const resetAccount = { ...provider("codex", 55), accountId: "reset-account", credits: { resetCreditsAvailable: 2 } };
assert.equal(context.accountResetLabel(resetAccount), "2 banked resets");
assert.equal(context.accountResetLabel({ ...resetAccount, credits: { resetCreditsAvailable: 1 } }), "1 banked reset");
assert.equal(context.accountResetLabel({ ...resetAccount, credits: { resetCreditsAvailable: 0 } }), "0 banked resets");
for (const count of [undefined, null, -1, 1.5, true, "2", NaN, Infinity])
  assert.equal(context.accountResetLabel({ ...resetAccount, credits: { resetCreditsAvailable: count } }), "");
assert.equal(context.accountResetLabel({ ...resetAccount, credits: null }), "");
assert.equal(context.accountResetLabel({ ...resetAccount, id: "claude" }), "");
assert.equal(context.accountResetLabel({ ...resetAccount, id: "claude", proxyImplementation: "rust" }), "2 banked resets");
assert.equal(context.accountResetLabel({ ...resetAccount, id: "claude", proxyImplementation: "rust", supportsBankedReset: false }), "");
assert.equal(context.minRemaining({ id: "claude", status: "ok", windows: [{ remaining: 5, informational: true }, { remaining: 60 }] }), 60);
assert.equal(context.minRemaining({ id: "claude", status: "ok", windows: [{ remaining: 5, informational: true }] }), null);
const statusNow = Date.UTC(2030, 0, 1, 0, 0, 0);
assert.equal(context.accountStatusText({ kind: "cooldown", text: "Rate limited", at: statusNow / 1000 + 750 }, statusNow), "Rate limited · 12m");
assert.equal(context.accountStatusText({ kind: "cooldown", text: "Rate limited", at: statusNow / 1000 - 1 }, statusNow), "");
assert.equal(context.accountStatusText({ kind: "info", text: "No 5-hour limit", at: null }, statusNow), "No 5-hour limit");
assert.match(context.accountStatusText({ kind: "renewal", text: "Renews", at: Date.UTC(2030, 0, 12, 12) / 1000, estimated: true }, statusNow),
  /^Renews Jan 1[12] \(estimated\)$/);
const statusRows = context.accountStatusItems({ statusItems: [{ kind: "error", text: "Last error: x", at: null },
  { kind: "info", text: "Takes new sessions last", at: null }] }, statusNow);
assert.equal(statusRows.length, 2);
assert.equal(statusRows[0].urgent, true);
assert.equal(statusRows[1].urgent, false);
assert.equal(context.accountResetLabel({ ...resetAccount, status: "disabled" }), "");
const resetFailure = { ...resetAccount, status: "error", credits: null, message: "Timeout" };
const resetStale = context.preserveProxyReadings({ source: "cliproxy", providers: [{ ...resetAccount, accounts: [resetAccount] }] },
  { source: "cliproxy", providers: [{ ...resetFailure, accounts: [resetFailure] }] });
assert.equal(context.accountResetLabel(resetStale.providers[0].accounts[0]), "2 banked resets");
assert.equal(resetStale.providers[0].accounts[0].stale, true);
const goSnapshot = { source: "cliproxy", proxyImplementation: "go",
  providers: [{ ...resetAccount, proxyImplementation: "go", accounts: [{ ...resetAccount, proxyImplementation: "go" }] }] };
const nativeFailure = { ...resetFailure, windows: [], proxyImplementation: "rust", supportsBankedReset: false };
const rustSnapshot = context.preserveProxyReadings(goSnapshot,
  { source: "cliproxy", proxyImplementation: "rust", providers: [{ ...nativeFailure, accounts: [nativeFailure] }] });
assert.equal(rustSnapshot.providers[0].accounts[0].credits, null, "implementation changes never restore Go reset credits");
assert.equal(rustSnapshot.providers[0].accounts[0].windows.length, 0);
const malformedNative = context.preserveProxyReadings(
  { source: "cliproxy", providers: [{ ...priorAccount, proxyImplementation: "rust" }] },
  { source: "cliproxy", providers: [{ ...failedAccount, proxyImplementation: "rust", errorKind: "malformed" }] });
assert.equal(malformedNative.providers[0].status, "error", "invalid native data cannot become a successful retained reading");

const customRows = [{model: " vendor/Model[1m] ", inputCostPerMillionTokens: "2",
  outputCostPerMillionTokens: "8", cacheReadCostPerMillionTokens: "0", cacheWriteCostPerMillionTokens: ""}];
const customJson = context.encodeCostPrices(customRows);
assert.deepEqual(JSON.parse(customJson), {"vendor/Model[1m]": {
  inputCostPerMillionTokens: 2, outputCostPerMillionTokens: 8, cacheReadCostPerMillionTokens: 0}});
assert.equal(context.encodeCostPrices(context.decodeCostPrices(customJson)), customJson);
assert.equal(context.encodeCostPrices([]), "{}");
for (const value of ["", "-1", "Infinity", "NaN", "0x10", "true", "1e10"])
  assert.throws(() => context.encodeCostPrices([{...customRows[0], inputCostPerMillionTokens: value}]));
assert.throws(() => context.encodeCostPrices([customRows[0], customRows[0]]));
assert.throws(() => context.encodeCostPrices([{...customRows[0], model: "<unattributed>"}]));
for (const raw of ["null", "[]", "{", '{"x":{"inputCostPerMillionTokens":true,"outputCostPerMillionTokens":2}}',
  '{"x":{"inputCostPerMillionTokens":2}}', '{"x":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":2,"extra":2}}'])
  assert.throws(() => context.decodeCostPrices(raw));
const specialId = context.encodeCostPrices([{...customRows[0], model: "__proto__"}]);
assert.ok(Object.prototype.hasOwnProperty.call(JSON.parse(specialId), "__proto__"));
console.log("Custom cost price validation: passed");

const a = { id: 'codex', accountId: '0123456789abcdef' };
const b = { id: 'codex', accountId: 'fedcba9876543210' };
const activity = { liveState: 'live', liveAccounts: [
  { provider: 'codex', accountId: a.accountId, inFlight: 3, sessions: 5 },
  { provider: 'codex', accountId: b.accountId, inFlight: 1, sessions: 1 }
] };
activity.liveState = 'reconnecting';
assert.equal(context.accountLoad(a, activity), null);
assert.equal(context.sessionBadgeText(null), 'Sessions unknown');
assert.equal(context.sessionBadgeText({sessions: 0}), '0 sessions');
assert.equal(context.sessionBadgeText({sessions: 1, inFlight: 3}), '1 session');
assert.equal(context.sessionBadgeText({sessions: 5, inFlight: 0}), '5 sessions');
assert.match(context.sessionDetails({sessions: 5}), /may remain assigned after a request finishes/);
const payload = { schemaVersion: 1, state: 'live', message: 'Live', providers: [], accounts: activity.liveAccounts };
assert.equal(context.validLivePayload(payload), true);
assert.equal(context.validLivePayload({ ...payload, state: 'reconnecting' }), false);
assert.equal(context.validLivePayload({ ...payload, accounts: [{...activity.liveAccounts[0], inFlight: NaN}] }), false);
assert.equal(context.validLivePayload({ ...payload, accounts: [{...activity.liveAccounts[0], inFlight: true}] }), false);
let created = 0, stopped = 0, destroyed = 0;
const factory = { createObject(parent) { assert.equal(parent,null); created++; return {
  stop() { stopped++; }, destroy() { destroyed++; }
}; } };
assert.equal(context.acquireLive('test', factory, {}), context.acquireLive('test', factory, {}));
assert.equal(created,1);
context.releaseLive('test'); assert.equal(stopped,0);
context.releaseLive('test'); assert.equal(stopped,1);

// Connection settings: renamed keys are read until a save migrates them.
const same = (actual, expected, message) => assert.equal(JSON.stringify(actual), JSON.stringify(expected), message);
const legacy = { usageSource: "cliproxy", cliproxyUrl: " https://proxy.test ", cliproxyKeyFile: "/k",
  costKeeperUrl: "https://keeper.test", costKeeperPasswordFile: "/p", costFuseboxEnabled: true };
assert.equal(context.usageSource(legacy), "proxy");
assert.equal(context.usageSource({ usageSource: "proxy" }), "proxy");
assert.equal(context.usageSource({}), "direct");
same(context.proxyConnection(legacy), { url: "https://proxy.test", keyFile: "/k" });
same(context.proxyConnection({}), { url: "http://127.0.0.1:8317", keyFile: "" });
assert.equal(context.setting(legacy, "keeperUrl", ""), "https://keeper.test");
assert.equal(context.setting({ keeperUrl: "new", costKeeperUrl: "old" }, "keeperUrl", ""), "new");
// Costs follow Limits: its Fusebox supplies history unless Costs chooses this
// computer or a different server. An older Costs URL stays a separate server.
same(context.fuseboxCostConnection(legacy),
  { source: "auto", mode: "limits", url: "https://proxy.test", keyFile: "/k", available: true,
    enabled: true, overlap: "fusebox", optional: true });
same(context.fuseboxCostConnection({ usageSource: "proxy", proxyUrl: "https://a.test" }, "rust"),
  { source: "auto", mode: "limits", url: "https://a.test", keyFile: "", available: true,
    enabled: true, overlap: "fusebox", optional: true }, "a fresh Fusebox Limits connection supplies costs");
assert.equal(context.fuseboxCostConnection({ usageSource: "proxy" }, "go").enabled, false, "CLIProxyAPI keeps no usage history");
assert.equal(context.fuseboxCostConnection({ usageSource: "direct", proxyUrl: "https://a.test" }).enabled, false,
  "local Limits have no Fusebox");
assert.equal(context.fuseboxCostConnection({ usageSource: "proxy", costHistorySource: "local" }).enabled, false);
same(context.fuseboxCostConnection({ usageSource: "proxy", costHistorySource: "mixed" }, "rust"),
  { source: "mixed", mode: "limits", url: "http://127.0.0.1:8317", keyFile: "", available: true,
    enabled: true, overlap: "transcripts", optional: true });
same(context.fuseboxCostConnection({ proxyUrl: "https://a.test", costFuseboxUrl: "https://b.test", costFuseboxKeyFile: "/b" }),
  { source: "auto", mode: "custom", url: "https://b.test", keyFile: "/b", available: true,
    enabled: true, overlap: "fusebox", optional: false }, "a different Costs server works without a Fusebox in Limits");
assert.equal(context.fuseboxCostConnection({ costFuseboxConnection: "limits", costFuseboxUrl: "https://b.test" }).url,
  "http://127.0.0.1:8317");
// The old switch: on keeps Fusebox (and its overlap choice); off was the
// untouched default too, so it follows Limits. A different server saved
// while switched off stays unused.
assert.equal(context.costHistorySource({ costFuseboxEnabled: true }), "auto");
assert.equal(context.costHistorySource({ costFuseboxEnabled: true, costFuseboxOverlap: "transcripts" }), "mixed");
assert.equal(context.costHistorySource({ costFuseboxEnabled: false, costFuseboxOverlap: "transcripts" }), "auto");
assert.equal(context.costHistorySource({ costHistorySource: "local", costFuseboxEnabled: true }), "local");
assert.equal(context.costHistorySource({ costHistorySource: "bogus" }), "auto");
assert.equal(context.fuseboxCostMode({ costFuseboxEnabled: false, costFuseboxUrl: "https://b.test" }), "limits");
assert.equal(context.fuseboxCostMode({ costFuseboxEnabled: true, costFuseboxUrl: "https://b.test" }), "custom");
assert.equal(context.fuseboxCostMode({ costHistorySource: "auto", costFuseboxEnabled: false,
  costFuseboxConnection: "custom" }), "custom", "a migrated choice is not second-guessed");
const migrated = context.migrateSettings(legacy);
same(Object.keys(migrated).filter((key) => /^cliproxy|^costKeeper|^costFuseboxEnabled|^costFuseboxOverlap/.test(key)), [],
  "legacy keys are removed");
assert.equal(migrated.usageSource, "proxy");
assert.equal(migrated.proxyUrl, " https://proxy.test ");
assert.equal(migrated.keeperPasswordFile, "/p");
assert.equal(migrated.costFuseboxConnection, "limits");
assert.equal(migrated.costHistorySource, "auto");
assert.equal(context.migrateSettings({ proxyUrl: "new", cliproxyUrl: "old" }).proxyUrl, "new");
assert.equal(context.migrateSettings({ costFuseboxUrl: "https://b.test" }).costFuseboxConnection, "custom");
same(context.migrateSettings({ costFuseboxEnabled: false, costFuseboxOverlap: "transcripts", costFuseboxUrl: "https://b.test" }),
  { costFuseboxUrl: "https://b.test", costFuseboxConnection: "limits", costHistorySource: "auto" });
same(context.migrateSettings({}), { costFuseboxConnection: "limits", costHistorySource: "auto" });
// The line under the Costs total and the notice for a failed Fusebox read.
assert.equal(context.urlHost("https://user:pw@fusebox.home.lan:8318/x"), "fusebox.home.lan:8318");
assert.equal(context.urlHost("not a url"), "");
const fuseboxRow = { id: "fusebox-claude", kind: "fusebox", status: "ok", included: true };
const localRow = { id: "local-claude", kind: "local", status: "ok", included: true };
const t3Row = { id: "home-codex", kind: "t3", status: "ok", included: true };
assert.equal(context.costSourceSummary([fuseboxRow, { ...localRow, status: "replaced", included: false }], "f.lan"),
  "From Fusebox · f.lan");
assert.equal(context.costSourceSummary([fuseboxRow, localRow], "f.lan"), "From this computer and Fusebox · f.lan");
assert.equal(context.costSourceSummary([localRow, t3Row], ""), "From this computer and T3 servers");
assert.equal(context.costSourceSummary([localRow], ""), "From this computer");
assert.equal(context.inertMarkup('<img src="file:///x.png">Full reset'), '\u2039img src="file:///x.png">Full reset',
  "labels for Omarchy's AutoText buttons cannot open a tag");
assert.equal(context.inertMarkup("Full reset"), "Full reset");
assert.equal(context.inertMarkup(null), "");
assert.equal(context.costSourceSummary([t3Row], ""), "From T3 servers");
assert.equal(context.costSourceSummary([], ""), "");
assert.equal(context.fuseboxFailure([fuseboxRow, localRow]), null);
same(context.fuseboxFailure([{ id: "fusebox", kind: "fusebox", status: "unavailable", included: false,
  message: "Fusebox usage request timed out." }, localRow]),
  { title: "Fusebox usage unavailable · showing this computer's history instead", detail: "Fusebox usage request timed out." });
assert.equal(context.fuseboxFailure([{ id: "fusebox", kind: "fusebox", status: "unavailable", included: false }]).title,
  "Fusebox usage unavailable");
assert.equal(context.fuseboxFailure([{ id: "fusebox", kind: "fusebox", status: "missing", included: false }]), null,
  "a Limits server without usage history is not a failure");
same(context.proxyArgs("https://p.test", "/k", "rust"),
  ["--proxy-url", "https://p.test", "--proxy-key-file", "/k", "--implementation", "rust"]);
same(context.proxyArgs("", "", ""), ["--proxy-url", "http://127.0.0.1:8317"]);
for (const url of ["https://p.test", "http://127.0.0.1:8317/prefix/management.html", "https://p.test:8443/a.b/"])
  assert.equal(context.validServerUrl(url), true, url);
for (const url of ["ftp://p.test", "https://u:p@p.test", "https://p.test/?q", "https://p.test/a/../b", "https://p.test/#x", ""])
  assert.equal(context.validServerUrl(url), false, url);
assert.equal(context.validSecret("key with spaces"), true);
assert.equal(context.validSecret("bad\nkey"), false);
assert.equal(context.validSecret("   "), false);
assert.equal(context.validSecret("x".repeat(8192)), false);
console.log("Connection settings: passed");

// Compact account cards keep a spent shorter window visible.
const json = (value) => JSON.stringify(value);
const spentSession = [
  {id: "codex-primary", label: "5 hour limit", windowSeconds: 18000, remaining: 0},
  {id: "codex-secondary", label: "Weekly limit", windowSeconds: 604800, remaining: 90},
  {id: "review", label: "Code review · Weekly limit", windowSeconds: 604800, remaining: 3, informational: true}
];
assert.equal(json(Array.from(context.accountWindows({windows: spentSession}, false, 25, 10)).map((row) => row.id)), json(["codex-primary", "codex-secondary"]));
assert.equal(json(Array.from(context.accountWindows({windows: spentSession}, false)).map((row) => row.id)), json(["codex-secondary"]));
assert.equal(json(Array.from(context.accountWindows({windows: [{...spentSession[0], remaining: 15}, spentSession[1]]}, false, 25, 10)).map((row) => row.id)), json(["codex-primary", "codex-secondary"]), "a warning-level shorter window is shown too");
assert.equal(json(Array.from(context.accountWindows({windows: [{...spentSession[0], remaining: 40}, spentSession[1]]}, false, 25, 10)).map((row) => row.id)), json(["codex-secondary"]));
assert.equal(json(Array.from(context.accountWindows({windows: [{...spentSession[0], remaining: 20}, {...spentSession[1], remaining: 10}]}, false, 25, 10)).map((row) => row.id)), json(["codex-secondary"]), "a looser shorter window stays hidden");
assert.equal(context.hasAdditionalWindows([{status: "ok", windows: spentSession}], 25, 10), true);
assert.equal(context.hasAdditionalWindows([{status: "ok", windows: [spentSession[1]]}], 25, 10), false);
assert.equal(context.hasAdditionalWindows([{status: "error", windows: spentSession}], 25, 10), false);
assert.equal(context.windowSeverity({remaining: 9}, 25, 10), "critical");
assert.equal(context.windowSeverity({remaining: 20}, 25, 10), "warning");
assert.equal(context.windowSeverity({remaining: 80}, 25, 10), "ok");
assert.equal(context.windowSeverity({remaining: 0, informational: true}, 25, 10), "none");
assert.equal(context.windowSeverity({remaining: null}, 25, 10), "none");

// Reset and refresh wording.
const now = Date.UTC(2030, 0, 1, 12, 0, 0);
const at = (seconds) => now / 1000 + seconds;
assert.match(context.resetText({resetsAt: at(3 * 3600 + 120)}, now), /^Resets in 3h 2m · \d\d:\d\d$/);
assert.match(context.resetText({resetsAt: at(2 * 86400 + 3600)}, now), /^Resets in 2d 1h · [A-Z][a-z]{2} \d+, \d\d:\d\d$/);
assert.match(context.resetText({resetsAt: at(0.4)}, now), /^Resets in 1s · /);
assert.equal(context.resetText({resetsAt: at(-5)}, now, true), "Reset due · updating");
assert.equal(context.resetText({resetsAt: at(-5)}, now, false), "Reset due · awaiting a new reading");
assert.equal(context.resetText({resetsAt: null}, now), "");
assert.equal(context.passedResetAt([{status: "ok", windows: [{resetsAt: at(-5)}]}], now - 60000, now), at(-5));
assert.equal(context.passedResetAt([{status: "ok", windows: [{resetsAt: at(-5)}]}], now, now), 0, "already-fetched resets do not refresh again");
assert.equal(context.passedResetAt([{status: "ok", accounts: [{status: "ok", windows: [{resetsAt: at(-1)}]}]}], 0, now), at(-1));
assert.equal(context.passedResetAt([{status: "error", windows: [{resetsAt: at(-1)}]}], 0, now), 0);
assert.equal(context.nextRefreshText(now + 9.5 * 60000, now), "Next refresh in 10m");
assert.equal(context.nextRefreshText(now + 45000, now), "Next refresh in 45s");
assert.equal(context.nextRefreshText(now - 1, now), "Refreshing soon");
assert.equal(context.nextRefreshText(0, now), "");
assert.equal(context.plural(1, "connected account"), "1 connected account");
assert.equal(context.plural(3, "connected account"), "3 connected accounts");

// Credits fill with what is left, like quota meters.
const credits = {used: 12.5, limit: 50, remaining: 37.5, currency: "USD"};
assert.equal(context.creditsPrimary(credits), "$37.50 remaining");
assert.equal(context.creditsDetail(credits), "$12.50 of $50.00 used");
assert.equal(context.creditsMeter(credits).fraction, 0.75);
assert.equal(context.creditsMeter(credits).label, "Monthly limit · 75% left");
// A prepaid wallet's balance is not the monthly cap.
const wallet = {used: 50, limit: 200, remaining: 100, total: 150, currency: "USD"};
assert.equal(context.creditsPrimary(wallet), "$100.00 balance");
assert.equal(context.creditsDetail(wallet), "$50.00 of $200.00 charged this month · $150.00 funded");
assert.equal(context.creditsMeter(wallet).label, "Monthly charge cap · 75% left");
assert.equal(context.creditsPrimary({remaining: 17.5, currency: ""}), "17.50 credits remaining");
assert.equal(context.creditsDetail({remaining: 17.5, currency: "", resetCreditsAvailable: 1}), "1 banked reset");
assert.equal(context.creditsMeter({used: 80, limit: 50}).fraction, 0);
assert.equal(context.creditsMeter({used: 1, limit: 0}), null);
assert.equal(context.creditsPrimary({resetCreditsAvailable: 1}), "1 banked reset");
assert.equal(context.creditsDetail({resetCreditsAvailable: 2}), "", "the reset count is not repeated under its own headline");
assert.equal(context.formatAmount(null, "USD"), "—");
assert.equal(context.formatAmount(7, "EUR"), "€7.00");

// Broken providers keep a bar chip instead of disappearing.
assert.equal(json(Array.from(context.barProviders([provider("claude", 72), provider("codex", null, "error"), provider("kimi", null)])
  ).map((row) => row.id)), json(["claude", "codex"]));

assert.equal(context.insecureRemoteUrl("http://fusebox.lan:8317"), true);
assert.equal(context.insecureRemoteUrl("http://127.0.0.1:8317"), false);
assert.equal(context.insecureRemoteUrl("http://localhost:8317/x"), false);
assert.equal(context.insecureRemoteUrl("http://[::1]:8317"), false);
assert.equal(context.insecureRemoteUrl("https://fusebox.example"), false);
assert.equal(context.insecureRemoteUrl("http://127.example.com:8317"), true, "a DNS name starting with 127 is not loopback");
assert.equal(context.insecureRemoteUrl("http://127.0.0.1@evil.example"), true, "user information is not the host");
assert.equal(context.insecureRemoteUrl("http://[0:0:0:0:0:0:0:1]:8317"), false);
console.log("UsageLogic.js presentation helpers: passed");

// Stale readings, the next reset, and label wrapping.
const freshAccount = {accountId: "a", status: "ok", windows: [{remaining: 50, resetsAt: at(600)}]};
const staleAccount = {accountId: "b", status: "ok", stale: true, notice: "Last known reading · Timeout", windows: [{remaining: 90, resetsAt: at(60)}]};
const pool = {id: "codex", status: "ok", windows: [{remaining: 90}], accounts: [freshAccount, staleAccount]};
assert.equal(context.hasStaleReading(pool), true, "one stale account makes the provider stale");
assert.equal(context.hasStaleReading({...pool, accounts: [freshAccount]}), false);
assert.equal(context.anyStaleReading([provider("claude", 40), pool]), true);
assert.equal(context.chipReadingStale(freshAccount, pool, false), false, "a fresh last-used account is current");
assert.equal(context.chipReadingStale(staleAccount, pool, false), true);
assert.equal(context.chipReadingStale(pool, pool, true), true, "the pool fallback is stale when any account is");
assert.equal(context.staleExplanation(staleAccount, pool), "Last known reading · Timeout");
assert.equal(context.staleExplanation({stale: true}, {}), "Last known reading; it may be out of date.");
assert.equal(context.staleExplanation(pool, pool), "Last known reading · Timeout", "the pool fallback explains its stale account");
assert.equal(context.nextResetAt([pool], now), at(60) * 1000);
assert.equal(context.nextResetAt([{...pool, status: "error"}], now), 0);
assert.equal(context.nextResetAt([], now), 0);
assert.equal(context.limitLabel("Preview · 1 day limit"), "Preview\u00a0· 1\u00a0day limit");
assert.equal(context.limitLabel(""), "Usage limit");
assert.equal(context.insecureRemoteUrl("http://[::1"), true, "a malformed IPv6 host warns");
assert.equal(context.sessionBadgeText({sessions: 1}), "1 session");
console.log("UsageLogic.js stale readings and resets: passed");

// Compact Limits rows: one line per account, details in the tooltip.
{
  const weekly = {id: "weekly", label: "Weekly limit", windowSeconds: 604800, remaining: 85, resetsAt: at(45 * 3600)};
  const session = {id: "session", label: "5 hour limit", windowSeconds: 18000, remaining: 8, resetsAt: at(42 * 60)};
  const opus = {id: "opus", label: "Opus weekly", windowSeconds: 604800, remaining: 70, resetsAt: at(45 * 3600)};
  const claude = {id: "claude", status: "ok", plan: "Claude Ultra", windows: [session, weekly, opus],
    statusItems: [{kind: "info", text: "No 5-hour limit", at: null},
      {kind: "renewal", text: "Renews", at: Date.UTC(2030, 0, 24, 12) / 1000},
      {kind: "cooldown", text: "Cooling down", at: at(720)}]};

  assert.equal(context.shortLimitLabel("Weekly limit"), "Weekly");
  assert.equal(context.shortLimitLabel("Code review · Weekly limit"), "Code review · Weekly");
  assert.equal(context.shortLimitLabel("Kimi K2.5 five-hour window"), "Kimi K2.5 five-hour window");
  assert.equal(context.shortLimitLabel(""), "Usage");

  const compact = context.accountRowWindows(claude, false, 25, 10);
  assert.equal(compact.main.id, "weekly", "the row meter is the plain weekly allowance");
  assert.equal(json(compact.extra.map((row) => row.id)), json(["session"]), "a spent shorter window gets its own row");
  const relaxed = context.accountRowWindows({...claude, windows: [{...session, remaining: 90}, weekly, opus]}, false, 25, 10);
  assert.equal(relaxed.extra.length, 0, "healthy shorter windows stay in the tooltip");
  const expanded = context.accountRowWindows(claude, true, 25, 10);
  assert.equal(json(expanded.extra.map((row) => row.id)), json(["session", "opus"]), "Details lists every other limit");
  const listLikeWindows = context.accountRowWindows({windows: {0: weekly, 1: session, length: 2}}, true, 25, 10);
  assert.equal(listLikeWindows.main.id, "weekly");
  assert.equal(listLikeWindows.extra.length, 1, "list-like windows still separate the main meter");
  assert.equal(context.accountRowWindows({windows: []}, false).main, null);

  assert.equal(context.accountsCaption([claude, {...claude}]), "weekly · resets");
  assert.equal(context.accountsCaption([claude, {...claude, windows: [{label: "Monthly limit"}]}]), "left · resets");
  assert.equal(context.accountsCaption([{...claude, status: "error"}]), "");
  assert.equal(context.accountsCaption([{...claude, windows: [{label: "Gemini 3 Pro"}]}]), "Gemini 3 Pro · resets");

  const codex = (planType) => ({id: "codex", status: "ok", planType, windows: []});
  assert.equal(context.providerTitle({id: "codex", name: "OpenAI Codex"}, [codex("pro"), codex("pro")]), "Codex Pro · 20×");
  assert.equal(context.providerTitle({id: "codex", name: "OpenAI Codex"}, [codex("pro"), codex("prolite")]), "OpenAI Codex",
    "mixed plans name the provider");
  assert.equal(context.providerTitle({id: "codex", name: "OpenAI Codex"}, [codex("pro"), {id: "codex", status: "disabled"}]),
    "Codex Pro · 20×", "an account without a plan does not make the plans mixed");
  assert.equal(context.providerTitle({id: "claude", name: "Claude Code", plan: "Claude Max 20x"}, []), "Claude Max 20x");
  assert.equal(context.providerTitle({id: "gemini", name: "Gemini"}, []), "Gemini");
  assert.equal(context.accountPlanTag(codex("prolite"), "OpenAI Codex"), "Pro · 5×");
  assert.equal(context.accountPlanTag(codex("pro"), "Codex Pro · 20×"), "", "a plan shown in the header is not repeated");
  assert.equal(context.accountPlanTag({id: "codex"}, "OpenAI Codex"), "");

  assert.equal(context.accountDisplayName({account: "a@example.invalid"}, 3, true), "Account 3");
  assert.equal(context.accountDisplayName({account: "a@example.invalid"}, 3, false), "a@example.invalid");
  assert.equal(context.accountIssue({status: "ok"}), "");
  assert.equal(context.accountIssue({status: "disabled"}), "Paused");
  assert.equal(context.accountIssue({status: "error", errorKind: "expired"}), "Sign-in expired");
  assert.equal(context.accountIssue({status: "error", errorKind: "network"}), "Unavailable");
  assert.equal(context.accountIssue({status: "unsupported", notice: "Quota lookup unavailable"}), "Quota lookup unavailable");
  assert.equal(context.errorBody({message: "Expired", errorKind: "expired", authCommand: "kimi login"}),
    "Expired Run “kimi login” in a terminal, then refresh.");

  assert.equal(context.remainingText(weekly, false), "85%");
  assert.equal(context.remainingText(weekly, true), "85%?", "a last-known reading is marked like the bar chip");
  assert.equal(context.remainingText({remaining: null}, false), "—");
  assert.equal(context.resetShort(weekly, now), "1d 21h");
  assert.equal(context.resetShort(session, now), "42m");
  assert.equal(context.resetShort({resetsAt: at(-1)}, now), "due");
  assert.equal(context.resetShort({resetsAt: null}, now), "");
  assert.match(context.resetClause(weekly, now), /^Resets [A-Z][a-z]{2} \d+, \d\d:\d\d \(in 1d 21h\)$/);
  assert.match(context.resetClause(session, now), /^Resets \d\d:\d\d \(in 42m\)$/);
  assert.equal(context.resetClause({resetsAt: at(-1)}, now, true), "Reset due · updating");
  assert.match(context.windowSummary(weekly, now), /^Weekly limit: 85% left · resets [A-Z][a-z]{2} \d+, \d\d:\d\d \(in 1d 21h\)$/);
  assert.equal(context.windowSummary({label: "Spend limit", remaining: 76, detail: "$12.00 used of $50.00"}, now),
    "Spend limit: 76% left · $12.00 used of $50.00");
  assert.equal(context.windowSummary({label: "Code review", remaining: 3, informational: true}, now),
    "Code review: 3% left · informational");
  assert.match(context.windowFacts(weekly, now), /^Resets [A-Z][a-z]{2} \d+, \d\d:\d\d$/, "Details omits the countdown the row shows");
  assert.match(context.resetClause(weekly, now + 30000), /\(in 1d 20h\)$/, "the tooltip countdown matches the reset column");
  assert.equal(context.resetShort(weekly, now + 30000), "1d 20h");
  assert.equal(context.windowFacts({detail: "x"}, now), "x");

  const details = context.accountDetails({...claude, credits: {label: "Extra usage", currency: "USD", remaining: 37.5}},
    {label: "Account 1", nowMs: now, liveActivity: true, load: {sessions: 2}});
  const lines = details.split("\n");
  assert.equal(lines[0], "Account 1 · Claude Ultra");
  assert.ok(lines.some((line) => /^Weekly limit: 85% left/.test(line)), "every limit is in the tooltip");
  assert.ok(lines.some((line) => /^5 hour limit: 8% left/.test(line)));
  assert.ok(lines.includes("No 5-hour limit") && lines.some((line) => /^Renews Jan 2[34]$/.test(line)));
  assert.ok(lines.includes("Cooling down · 12m"));
  assert.ok(lines.includes("Extra usage: $37.50 remaining"));
  assert.ok(lines.some((line) => /^2 sessions assigned/.test(line)));
  assert.ok(!details.includes("banked reset"), "Claude without Fusebox has no reset line");
  const withResets = context.accountDetails({id: "codex", status: "ok", windows: [], credits: {resetCreditsAvailable: 2}},
    {label: "Account 2", resetEnabled: true});
  assert.ok(withResets.includes("No subscription limits reported."));
  assert.ok(withResets.includes("2 banked resets · click " + context.RESET_ICON + " to apply one"));
  assert.equal(context.RESET_ICON, "\u{F099B}", "the restore glyph, not the header's refresh glyph");
  assert.equal(context.accountResetCount({id: "codex", status: "ok", credits: {resetCreditsAvailable: 3}}), 3);
  assert.equal(context.accountResetCount({id: "codex", status: "ok", credits: {resetCreditsAvailable: 0}}), 0);
  assert.equal(context.accountResetCount({id: "claude", status: "ok", credits: {resetCreditsAvailable: 3}}), -1,
    "Claude resets need Fusebox");
  assert.equal(context.accountResetCount({id: "codex", status: "ok", credits: {resetCreditsAvailable: 1.5}}), -1);
  const resettable = {id: "codex", status: "ok", credits: {resetCreditsAvailable: 1}};
  assert.equal(context.hasBankedResets([{accounts: [{...resettable, credits: {resetCreditsAvailable: 0}}]}]), false);
  assert.equal(context.hasBankedResets([{accounts: []}, {accounts: [resettable]}]), true);
  assert.equal(context.hasBankedResets(null), false);
  const failedDetails = context.accountDetails({status: "error", errorKind: "expired", message: "Sign in again.", windows: [weekly]},
    {label: "Account 3"});
  assert.equal(failedDetails, "Account 3\nSign in again.", "a failed account shows its error, not old limits");
  assert.ok(context.accountDetails({...claude, stale: true, notice: "Last known reading · Proxy offline"}, {})
    .endsWith("Last known reading · Proxy offline"));

  const facts = context.accountFacts(claude, weekly, now);
  assert.match(facts, /^Resets [A-Z][a-z]{2} \d+, \d\d:\d\d · No 5-hour limit · Renews Jan 2[34]$/,
    "Details shows the reset time and quiet facts; urgent facts have their own line");
  assert.equal(json(context.urgentAccountFacts(claude, now)), json(["Cooling down · 12m"]));
  assert.equal(context.urgentAccountFacts({statusItems: []}, now).length, 0);

  const pooled = (id, count) => ({id, status: "ok", accounts: Array.from({length: count}, () => ({status: "ok"}))});
  assert.equal(context.limitsContext([pooled("claude", 4), pooled("codex", 2), pooled("meta", 1)], true), "7 accounts · 3 providers");
  assert.equal(context.limitsContext([pooled("claude", 1)], true), "1 account");
  assert.equal(context.limitsContext([provider("claude", 40), provider("codex", 20)], false), "2 providers");
  assert.equal(context.limitsContext([provider("claude", 40)], false), "");

  assert.equal(context.hasQuotaHistory({status: "ok", history: {h24: [1], d7: []}}), true);
  assert.equal(context.hasQuotaHistory({status: "ok", history: {h24: [], d7: []}}), false);
  assert.equal(context.hasQuotaHistory({status: "ok", accounts: [{}], history: {h24: [1]}}), false,
    "managed accounts have no shared chart");
  assert.equal(context.hasQuotaHistory({status: "error", history: {h24: [1]}}), false);
  console.log("UsageLogic.js compact rows: passed");
}

// Claude's Fable week: its own line under every account that reports one.
{
  const weekly = {id: "weekly", label: "Weekly limit", windowSeconds: 604800, remaining: 74, resetsAt: at(54 * 3600)};
  const session = {id: "session", label: "5 hour limit", windowSeconds: 18000, remaining: 8, resetsAt: at(42 * 60)};
  const fable = {id: "fable", label: "Fable weekly", model: "fable", windowSeconds: 604800, remaining: 39,
    resetsAt: at(54 * 3600)};
  const opus = {id: "opus", label: "Opus weekly", model: "opus", windowSeconds: 604800, remaining: 70,
    resetsAt: at(54 * 3600)};
  const account = (windows) => ({id: "claude", status: "ok", plan: "Claude Ultra", windows});
  const ids = (rows) => json(rows.map((row) => row.id));

  const healthy = context.accountRowWindows(account([weekly, fable, opus]), false, 25, 10);
  assert.equal(healthy.main.id, "weekly", "the all-models week stays the account meter");
  assert.equal(ids(healthy.extra), json(["fable"]), "a healthy Fable week keeps its line; Opus stays in the tooltip");
  assert.equal(ids(context.accountRowWindows(account([fable, session, weekly]), false, 25, 10).extra),
    json(["session", "fable"]), "a spent shorter window comes first and Fable keeps its place below");
  assert.equal(ids(context.accountRowWindows(account([weekly, {...fable, remaining: 17}]), false, 25, 10).extra),
    json(["fable"]), "an urgent Fable week is listed once");
  const onlyFable = context.accountRowWindows(account([session, fable]), false, 25, 10);
  assert.equal(onlyFable.main.id, "fable", "without an all-models week, Fable can be the meter");
  assert.equal(ids(onlyFable.extra), json(["session"]), "the meter's window is not repeated below it");
  assert.equal(context.accountRowWindows(account([weekly, {...fable, informational: true}]), false, 25, 10).extra.length,
    0, "an informational allowance is not pinned");
  assert.equal(context.accountRowWindows(account([weekly, {...fable, model: undefined}]), false, 25, 10).extra.length,
    0, "a window without a model is not pinned");
  assert.equal(ids(context.accountWindows(account([weekly, fable]), false)), json(["weekly", "fable"]),
    "Fable is pinned without thresholds too");
  assert.equal(ids(context.accountRowWindows(account([weekly, fable, opus]), true, 25, 10).extra),
    json(["fable", "opus"]), "Details still lists every other window");
  assert.equal(context.hasAdditionalWindows([account([weekly, fable])], 25, 10), false,
    "Details reveals nothing new when Fable is already shown");
  assert.equal(context.hasAdditionalWindows([account([weekly, fable, opus])], 25, 10), true);
  assert.equal(context.accountsCaption([account([weekly, fable])]), "weekly · resets", "the caption names the meter");
  assert.equal(context.minRemaining({status: "ok", windows: [weekly, fable]}), 39, "the bar chip counts the Fable week");

  assert.equal(context.accountWindowLabel(fable), "Fable", "a model week is named by its model");
  assert.equal(context.accountWindowLabel(opus), "Opus");
  assert.equal(context.accountWindowLabel({label: "Fable · 5 hour limit", model: "fable", windowSeconds: 18000}),
    "Fable\u00a0· 5\u00a0hour", "other durations keep their full name");
  assert.equal(context.accountWindowLabel(session), "5\u00a0hour");
  assert.equal(context.accountWindowLabel(null), "Usage");

  assert.match(context.windowSummary(fable, now),
    /^Fable weekly: 39% left · resets [A-Z][a-z]{2} \d+, \d\d:\d\d \(in 2d 6h\)\n {2}Beyond it, Fable runs on extra usage, if enabled$/,
    "the Fable line explains what happens once it is spent");
  assert.equal(context.windowSummary(opus, now).indexOf("\n"), -1, "other model weeks add no note");
  assert.equal(context.windowNote({model: "toString"}), "", "only listed models have notes");
  const tip = context.accountDetails(account([weekly, fable]), {label: "Account 1", nowMs: now}).split("\n");
  assert.equal(tip[0], "Account 1 · Claude Ultra");
  assert.match(tip[2], /^Fable weekly: 39% left/);
  assert.equal(tip[3], "  Beyond it, Fable runs on extra usage, if enabled", "the note sits indented under its line");
  console.log("UsageLogic.js Fable week: passed");
}
