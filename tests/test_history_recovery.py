from __future__ import annotations

import json
import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

from test_cost_backend import costs, fixture_text
from test_keeper_costs import EVENT, STAMP
import keeper_costs as keeper


class HistoryRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.archive = costs.UsageRecord(**keeper.normalize_event(
            {**EVENT, "user_agent": "codex-tui/1.0 (private-host)"}, "server"))
        self.history = {"firstRecordAt": STAMP, "skippedRecords": 0, "status": "partial",
                        "collectorHealthy": True, "message": "Saved requests only."}
        self.local = replace(self.archive, origin="local", proxy_session=True,
                             session_id="session-hash", timestamp_ms=STAMP - 3_600_000,
                             uncached_input=123, dedupe_key=None)

    def recover(self, local, archive=None, history=None):
        with mock.patch.object(costs, "scan_transcripts", return_value=(local, [{"status": "ok"}])):
            return costs.recover_local_history(archive or [self.archive], history or self.history,
                                               STAMP - 86_400_000, STAMP + 1000, None)

    def test_client_families_discard_raw_identity(self):
        for raw, expected in (("t3code_desktop/1.2 (private-host)", "t3"),
                              ("codex-tui", "codex-cli"), ("codex_exec/1", "codex-exec"),
                              ("digital_brain/1", "digital-brain"),
                              ("private@example.test", "other"), (None, "other")):
            row = keeper.normalize_event({**EVENT, "user_agent": raw}, "server")
            self.assertEqual(row["client_id"], expected)
            self.assertNotIn("private", json.dumps(row))

    def test_recovery_excludes_direct_unknown_and_post_boundary_sessions(self):
        rejected = [replace(self.local, proxy_session=False),
                    replace(self.local, session_id=""),
                    replace(self.local, timestamp_ms=STAMP),
                    replace(self.local, timestamp_ms=STAMP + 1),
                    replace(self.local, timestamp_ms=STAMP - 86_400_001)]
        recovered, info = self.recover([self.local] + rejected)
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0].origin, "backfill")
        self.assertEqual(info["recoveredRecords"], 1)

    def test_duplicate_files_and_archive_overlap_are_not_added_twice(self):
        skewed = replace(self.archive, origin="local", proxy_session=True,
                         session_id="other-session", timestamp_ms=STAMP - 1000)
        recovered, info = self.recover([self.local, self.local, skewed, skewed])
        self.assertEqual(len(recovered), 1)
        self.assertEqual(info["overlapRecords"], 1)
        self.assertEqual(recovered, self.recover([self.local, self.local, skewed])[0])

    def test_equal_token_amounts_on_distinct_requests_survive(self):
        recovered, _ = self.recover([self.local, replace(self.local, timestamp_ms=self.local.timestamp_ms + 5000)])
        self.assertEqual(len(recovered), 2)
        # One archive request can suppress at most one skewed local request.
        skewed = replace(self.archive, origin="local", proxy_session=True, session_id="s",
                         timestamp_ms=STAMP - 2000)
        recovered, info = self.recover([skewed, replace(skewed, timestamp_ms=STAMP - 1000)])
        self.assertEqual(len(recovered), 1)
        self.assertEqual(info["overlapRecords"], 1)

    def test_missing_or_invalid_boundary_never_guesses_a_backfill_window(self):
        with mock.patch.object(costs, "scan_transcripts", side_effect=AssertionError("must not scan")):
            for history in ({**self.history, "firstRecordAt": None},
                            {**self.history, "skippedRecords": 1}):
                recovered, info = costs.recover_local_history([], history, STAMP - 1000, STAMP, None)
                self.assertEqual(recovered, [])
                self.assertEqual(info["status"], "unavailable")

    def test_combined_limit_fails_without_truncating_history(self):
        with mock.patch.object(costs, "MAX_TRANSCRIPT_RECORDS_TOTAL", 1), self.assertRaises(ValueError):
            self.recover([self.local])

    def build(self, client="all", days=1, backfill=True, archive=None):
        rows = [self.archive] if archive is None else archive
        history = {**self.history, "firstRecordAt": min((r.timestamp_ms for r in rows), default=None)}
        # Equivalent to the sanitized transport response, not raw event data.
        with mock.patch.object(keeper, "collect", return_value=([vars(r) for r in rows], history)) as fetch, \
             mock.patch.object(costs, "scan_transcripts", return_value=([self.local], [{"status": "ok"}])):
            result = costs.build_payload([], days, 5, None, now_ms=STAMP + 1000,
                zone_name="UTC", source="keeper", local_backfill=backfill, client_filter=client,
                rates_override=({"gpt-example": (1e-6, 2e-6, .1e-6, 1e-6)}, {"status": "fresh"}))
        return result, fetch.call_args.args[3]

    def test_filters_reconcile_totals_keep_provenance_and_do_not_leak_clients(self):
        t3 = replace(self.archive, client_id="t3", dedupe_key="different")
        all_apps, export_start = self.build(archive=[self.archive, t3])
        cli, _ = self.build(client="codex-cli", archive=[self.archive, t3])
        t3_only, _ = self.build(client="t3", archive=[self.archive, t3])
        self.assertEqual(all_apps["totals"]["totalTokens"],
                         cli["totals"]["totalTokens"] + t3_only["totals"]["totalTokens"])
        self.assertEqual(cli["totals"]["archiveRecords"], 1)
        self.assertEqual(cli["totals"]["backfillRecords"], 1)
        self.assertEqual(t3_only["totals"]["backfillRecords"], 0)
        self.assertEqual(all_apps["clients"], cli["clients"])
        self.assertLess(export_start, STAMP - 28 * 86_400_000)
        self.assertEqual(cli["history"]["firstRecordAt"], t3_only["history"]["firstRecordAt"])

    def test_gaps_local_only_and_filtered_zero_are_distinct(self):
        result, _ = self.build()
        statuses = {p["historyStatus"] for p in result["periods"]}
        self.assertEqual(statuses, {"recorded", "localOnly", "unavailable"})
        empty_filter, _ = self.build(client="t3")
        self.assertEqual(empty_filter["totals"]["records"], 0)
        self.assertEqual(empty_filter["totals"]["historyStatus"], "recorded")
        empty_archive, _ = self.build(archive=[])
        self.assertEqual(empty_archive["totals"]["historyStatus"], "unavailable")
        self.assertEqual(empty_archive["history"]["backfill"]["status"], "unavailable")

    def test_short_period_cannot_backfill_a_later_collection_gap(self):
        old = replace(self.archive, timestamp_ms=STAMP - 2 * 86_400_000)
        result, _ = self.build(archive=[old, self.archive])
        self.assertEqual(result["totals"]["backfillRecords"], 0)
        self.assertEqual(result["history"]["backfill"]["status"], "notNeeded")

    def test_codex_metadata_survives_warm_cache_and_incremental_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            transcripts = root / "sessions"
            transcripts.mkdir()
            path = transcripts / "session.jsonl"
            lines = [json.loads(line) for line in fixture_text("codex-rollout.jsonl").splitlines()]
            lines[0]["payload"].update(originator="codex-tui", model_provider="cli_proxy_api")
            path.write_text("".join(json.dumps(line) + "\n" for line in lines))
            os.utime(path, (STAMP / 1000, STAMP / 1000))
            with mock.patch.object(costs, "transcript_root", return_value=transcripts):
                first, _ = costs.scan_transcripts(["codex"], root / "state", STAMP)
                warm, _ = costs.scan_transcripts(["codex"], root / "state", STAMP)
                self.assertEqual(first, warm)
                self.assertEqual(len(first), 2)
                self.assertTrue(all(r.proxy_session and r.client_id == "codex-cli" for r in warm))
                with path.open("a") as handle:
                    handle.write(json.dumps({"timestamp": "2030-01-15T12:00:00Z", "type": "event_msg",
                        "payload": {"type": "token_count", "info": {"last_token_usage": {
                            "input_tokens": 999, "output_tokens": 3}}}}) + "\n")
                os.utime(path, (STAMP / 1000 + 1, STAMP / 1000 + 1))
                appended, _ = costs.scan_transcripts(["codex"], root / "state", STAMP)
                self.assertEqual(len(appended), len(first) + 1)
                self.assertTrue(appended[-1].proxy_session)
                self.assertEqual(appended[-1].client_id, "codex-cli")
                cold, _ = costs.scan_transcripts(["codex"], root / "cold", STAMP)
                self.assertEqual(appended, cold)


if __name__ == "__main__":
    unittest.main()
