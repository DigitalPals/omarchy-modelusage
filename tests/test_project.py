from __future__ import annotations

import json
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ProjectContractTests(unittest.TestCase):
    def test_manifest_has_current_quattro_bar_widget_shape(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "digitalpals.model-usage")
        self.assertEqual(manifest["kinds"], ["bar-widget"])
        self.assertEqual(manifest["entryPoints"]["barWidget"], "Panel.qml")
        self.assertEqual(manifest["barWidget"]["category"], "AI")
        self.assertEqual(manifest["barWidget"]["defaultSection"], "right")
        self.assertFalse(manifest["barWidget"]["allowMultiple"])
        self.assertNotIn("aliases", manifest)
        keys = {entry["key"] for entry in manifest["barWidget"]["schema"]}
        self.assertEqual(keys, {
            "refreshIntervalSec", "enabledProviders", "barDisplayMode",
            "warningThreshold", "criticalThreshold",
        })

    def test_packaged_paths_and_assets_are_self_contained(self):
        panel = (ROOT / "Panel.qml").read_text()
        backend = (ROOT / "UsageBackend.qml").read_text()
        cost_backend = (ROOT / "CostBackend.qml").read_text()
        self.assertIn('Qt.resolvedUrl("scripts/usage-fetch.py")', backend)
        self.assertIn('Qt.resolvedUrl("scripts/cost-fetch.py")', cost_backend)
        self.assertTrue((ROOT / "scripts" / "model_usage_common.py").is_file())
        self.assertIn('Qt.resolvedUrl("assets/', panel)
        for name in (
            "claude.svg", "codex.svg", "codex-light.svg", "kimi.svg",
            "claude-bar.svg", "codex-bar.svg", "kimi-bar.svg",
        ):
            self.assertTrue((ROOT / "assets" / name).is_file(), name)
        all_source = (
            panel + backend + cost_backend
            + (ROOT / "scripts" / "usage-fetch.py").read_text()
            + (ROOT / "scripts" / "cost-fetch.py").read_text()
        )
        self.assertNotIn("$OMARCHY_PATH/bin", all_source)
        self.assertNotIn("/usr/share/omarchy", all_source)
        self.assertNotIn("omarchy.agents", all_source)

    def test_release_metadata_documentation_and_screenshot_are_publishable(self):
        readme = (ROOT / "README.md").read_text()
        for path in (
            ".github/workflows/ci.yml",
            "CHANGELOG.md",
            "COMPATIBILITY.md",
            "SECURITY.md",
            "docs/backend-contract.md",
            "docs/cost-contract.md",
            "docs/releasing.md",
            "docs/model-usage-panel.png",
        ):
            self.assertTrue((ROOT / path).is_file(), path)

        self.assertIn("docs/model-usage-panel.png", readme)
        self.assertNotIn("screenshot-placeholder", readme)
        self.assertFalse((ROOT / "docs" / "screenshot-placeholder.svg").exists())

        screenshot = (ROOT / "docs" / "model-usage-panel.png").read_bytes()
        self.assertEqual(screenshot[:8], b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack(">II", screenshot[16:24])
        self.assertGreaterEqual(width, 500)
        self.assertGreaterEqual(height, 500)

        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn('python-version: ["3.10"', workflow)
        self.assertIn('"3.14"]', workflow)

        usage_backend = (ROOT / "scripts" / "usage-fetch.py").read_text()
        cost_backend = (ROOT / "scripts" / "cost-fetch.py").read_text()
        for source in (usage_backend, cost_backend):
            self.assertIn("from model_usage_common import", source)

    def test_performance_and_orientation_guards_are_present(self):
        panel = (ROOT / "Panel.qml").read_text()
        backend = (ROOT / "UsageBackend.qml").read_text()
        cost_backend = (ROOT / "CostBackend.qml").read_text()
        self.assertIn("bar && bar.vertical", panel)
        self.assertIn("running: root.opened", panel)
        self.assertIn("if (fetchProcess.running)", backend)
        self.assertIn("pendingRefresh = true", backend)
        self.assertIn("interval: 35000", backend)
        self.assertIn("Math.max(60, Math.min(3600", backend)
        self.assertNotIn("Timer {\n    interval:", cost_backend.split("Process {")[0])
        self.assertIn("function ensureLoaded()", cost_backend)
        self.assertIn("interval: 60000", cost_backend)
        for source in (backend, cost_backend):
            self.assertNotIn("StdioCollector", source)
            self.assertIn('splitMarker: ""', source)
            self.assertIn("outputTooLarge", source)
            self.assertIn("maxBodyChars", source)

        collector = (ROOT / "scripts" / "usage-fetch.py").read_text()
        self.assertIn('[codex, "-s", "read-only", "-a", "never", "app-server"]', collector)
        self.assertIn("MAX_HTTP_RESPONSE_BYTES + 1", collector)
        self.assertIn("class CodexRpcStream", collector)
        self.assertNotIn("process.stdout.readline", collector)

        cost_collector = (ROOT / "scripts" / "cost-fetch.py").read_text()
        self.assertIn('opaque_id(str(path.absolute()))', cost_collector)
        self.assertIn("cost = None", cost_collector)
        self.assertNotIn('document.get("prompt")', cost_collector)
        self.assertIn("MAX_TRANSCRIPT_LINE_BYTES + 1", cost_collector)
        self.assertIn("MAX_TRANSCRIPT_RECORDS_TOTAL", cost_collector)

    def test_namespaced_ipc_and_no_builtin_alias_collision(self):
        panel = (ROOT / "Panel.qml").read_text()
        self.assertIn('ipcTarget: "digitalpals.model-usage"', panel)
        for operation in ("open", "close", "toggle", "refresh", "next"):
            self.assertIn(f"function {operation}(", panel)
        for operation in ("limits", "costs"):
            self.assertIn(f"function {operation}(", panel)

    def test_cost_tab_is_native_isolated_and_honest(self):
        panel = (ROOT / "Panel.qml").read_text()
        costs = (ROOT / "UsageCosts.qml").read_text()
        backend = (ROOT / "CostBackend.qml").read_text()
        self.assertIn('{ value: "costs", label: "Costs" }', panel)
        self.assertIn("CostBackend {", panel)
        self.assertIn("UsageCosts {", panel)
        self.assertIn("API-equivalent estimate · not subscription spend", costs)
        self.assertIn('return "—"', costs)
        self.assertIn("periodDays", backend)
        self.assertIn('choices=(1, 7, 30)', (ROOT / "scripts" / "cost-fetch.py").read_text())

    def test_percentage_mode_uses_provider_logo_chips(self):
        panel = (ROOT / "Panel.qml").read_text()
        self.assertIn("model: root.percentageProviders", panel)
        self.assertIn("source: root.barIconUrl(providerChip.modelData)", panel)
        self.assertIn("colorizationColor: providerChip.contentColor", panel)
        self.assertIn("text: providerChip.remainingText", panel)
        self.assertIn("root.handleProviderChipPress", panel)

    def test_account_details_are_kept_behind_help_tooltip(self):
        panel = (ROOT / "Panel.qml").read_text()
        self.assertIn('return provider && provider.plan ? String(provider.plan) : ""', panel)
        self.assertIn('lines.push("Account: " + String(provider.account))', panel)
        self.assertIn('lines.push("Source: " + String(provider.source))', panel)
        self.assertIn('iconText: "?"', panel)
        self.assertIn("tooltipText: root.accountTooltip(root.provider)", panel)


if __name__ == "__main__":
    unittest.main()
