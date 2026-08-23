const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "UsageLogic.js"), "utf8")
  .replace(/^\.pragma library\s*/m, "");
const context = { Array, Math, Number, String, isFinite };
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

console.log("UsageLogic.js: all assertions passed");
