#!/usr/bin/env python3
# RUNNER_OPTIONAL=1
# RUNNER_RUNTIME=playwright
"""
Playwright runtime regression for the WebUI Notification Center body that the
downloader prefetch raises when the shell-side classifier writes the new
structured `error:repo:readonly_fs` status.

Why this test exists:
The original "Downloader prefetch error" Notification Center popup classified
ANY non-zero rc from the prefetch as `error:solver:RC`, which mis-flagged
read-only sandbox failures (libdnf5 offline staging blocked by
`ProtectSystem=full` + missing `ReadWritePaths=`) as solver/conflict errors.
The fix introduced a structured subkind in the status string,
`error:repo:readonly_fs`, plus matching wiring in the WebUI:
    - parseDownloadStatus() now extracts `error_subkind` for `error:repo:*`
      and rewrites `obj.detail` to mention `ReadWritePaths=` so users know
      the unit's `ReadWritePaths=` line needs to include the libdnf5
      offline staging dirs.
    - _downloaderIncidentId() now appends the subkind to the incident id
      (`inc-downloader-repo-readonly-fs`) so the AI Smart Report and the
      Notification Center dedupe on the actual sub-class instead of
      collapsing every repo failure into the same incident.
    - _downloaderMaybeNotifyError() pulls the (now subkind-aware) detail
      and incident id into the notification body that znhNotifyAdd() sees.

This regression executes the real, extracted JS helpers in headless Chromium
and asserts the notification body that ends up in znhNotifyAdd() mentions
`ReadWritePaths=` AND uses the new sub-classed incident id. It also asserts
that the original `error:repo` (no subkind) still produces the legacy
"Repository refresh error" body so we don't regress dedupe behaviour for
generic repo failures.

This catches future copy regressions in `_downloaderMaybeNotifyError`
(per the rule: WebUI surfaces are the user-visible fix surface).
"""
import re
import unittest
from python_regression_bootstrap import resolve_target_script_path as _resolve_target_script_path

try:
    from playwright.sync_api import sync_playwright
except Exception:  # pragma: no cover - optional dependency
    sync_playwright = None


class DownloaderReadonlyFsNotificationPlaywrightRegressionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script_path = _resolve_target_script_path(__file__)
        cls.script_text = cls.script_path.read_text(encoding="utf-8")

    @classmethod
    def _extract_function(cls, name: str) -> str:
        # Reuse the proven brace-balancing extractor pattern from
        # test_webui_poll_parse_recovery_playwright_regression.py.
        pattern = re.compile(rf"function\s+{re.escape(name)}\s*\(")
        m = pattern.search(cls.script_text)
        if not m:
            raise AssertionError(f"Could not find function {name} in {cls.script_path}")

        start = m.start()
        brace_start = cls.script_text.find("{", m.end())
        if brace_start < 0:
            raise AssertionError(f"Could not find opening brace for function {name}")

        text = cls.script_text
        depth = 0
        i = brace_start
        in_single = False
        in_double = False
        in_backtick = False
        escaped = False

        while i < len(text):
            ch = text[i]

            if escaped:
                escaped = False
                i += 1
                continue

            if in_single:
                if ch == "\\":
                    escaped = True
                elif ch == "'":
                    in_single = False
                i += 1
                continue

            if in_double:
                if ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_double = False
                i += 1
                continue

            if in_backtick:
                if ch == "\\":
                    escaped = True
                elif ch == "`":
                    in_backtick = False
                i += 1
                continue

            if ch == "'":
                in_single = True
                i += 1
                continue
            if ch == '"':
                in_double = True
                i += 1
                continue
            if ch == "`":
                in_backtick = True
                i += 1
                continue

            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[start : i + 1]
            i += 1

        raise AssertionError(f"Could not parse full function body for {name}")

    def _build_harness_html(self) -> str:
        # Pull the real, embedded helper functions out of UNI-auto.sh so the
        # test exercises the same code that ships in status.html.
        needed_functions = [
            "parseDownloadStatus",
            "_downloaderErrorSeverity",
            "_downloaderIncidentId",
            "_downloaderMaybeNotifyError",
        ]
        funcs_js = "\n\n".join(self._extract_function(f) for f in needed_functions)

        return f"""<!doctype html>
<html>
<head><meta charset="utf-8"></head>
<body>
  <script>
    // Capture every call to znhNotifyAdd so the test can assert the body the
    // user would see in the dashboard's Notification Center bell.
    window.__notifyCalls = [];
    window.znhNotifyAdd = function(payload) {{
      try {{
        window.__notifyCalls.push(payload || null);
      }} catch (e0) {{}}
    }};

    // Module-level dedupe state used by _downloaderMaybeNotifyError. We let
    // the function declarations below (extracted from UNI-auto.sh) re-declare
    // them; that's why we do NOT predeclare the underscored vars here.

    {funcs_js}

    window.__runScenario = function() {{
      window.__notifyCalls = [];

      // 1) New structured read-only sandbox status (error:repo:readonly_fs).
      //    Must produce the new subkind incident id AND mention
      //    ReadWritePaths= in the body.
      var roParsed = parseDownloadStatus('error:repo:readonly_fs');
      _downloaderMaybeNotifyError('error:repo:readonly_fs', roParsed);

      // 2) Generic legacy error:repo (no subkind). Must still produce the
      //    legacy "Repository refresh error" body and the original
      //    inc-downloader-repo incident id (no subkind suffix).
      var repoParsed = parseDownloadStatus('error:repo');
      _downloaderMaybeNotifyError('error:repo', repoParsed);

      // 3) Solver error - sanity check that the existing error:solver:RC
      //    flow is unchanged and dedupes against its own incident id.
      var solverParsed = parseDownloadStatus('error:solver:1');
      _downloaderMaybeNotifyError('error:solver:1', solverParsed);

      return {{
        notifyCalls: window.__notifyCalls.slice(),
        readonlyParsed: {{
          state: String((roParsed && roParsed.state) || ''),
          error_kind: String((roParsed && roParsed.error_kind) || ''),
          error_subkind: String((roParsed && roParsed.error_subkind) || ''),
          detail: String((roParsed && roParsed.detail) || '')
        }},
        repoParsed: {{
          state: String((repoParsed && repoParsed.state) || ''),
          error_kind: String((repoParsed && repoParsed.error_kind) || ''),
          error_subkind: String((repoParsed && repoParsed.error_subkind) || ''),
          detail: String((repoParsed && repoParsed.detail) || '')
        }},
        solverParsed: {{
          state: String((solverParsed && solverParsed.state) || ''),
          error_kind: String((solverParsed && solverParsed.error_kind) || ''),
          error_code: String((solverParsed && solverParsed.error_code) || ''),
          detail: String((solverParsed && solverParsed.detail) || '')
        }}
      }};
    }};
  </script>
</body>
</html>
"""

    def test_readonly_fs_notification_mentions_read_write_paths(self) -> None:
        if sync_playwright is None:
            self.skipTest("playwright is not installed (python package missing)")

        html = self._build_harness_html()

        with sync_playwright() as pw:
            try:
                browser = pw.chromium.launch(headless=True)
            except Exception as exc:  # pragma: no cover - environment dependent
                self.skipTest(f"playwright chromium is not available: {exc}")
                return

            page = browser.new_page()
            try:
                page.set_content(html, wait_until="domcontentloaded")
                state = page.evaluate("() => window.__runScenario()")
            finally:
                browser.close()

        # --- 1. parseDownloadStatus() returns structured fields ------------
        ro_parsed = state["readonlyParsed"]
        self.assertEqual(ro_parsed["state"], "error")
        self.assertEqual(ro_parsed["error_kind"], "repo")
        self.assertIn(
            ro_parsed["error_subkind"],
            ("readonly_fs", "readonly-fs"),
            msg=f"error:repo:readonly_fs status must surface a structured subkind; got: {ro_parsed!r}",
        )
        self.assertIn(
            "ReadWritePaths=",
            ro_parsed["detail"],
            msg=(
                "parseDownloadStatus() must rewrite obj.detail for the readonly_fs "
                "subkind so the WebUI Notification Center body explicitly mentions "
                "ReadWritePaths= (the user-actionable fix). Got: "
                f"{ro_parsed['detail']!r}"
            ),
        )

        repo_parsed = state["repoParsed"]
        self.assertEqual(repo_parsed["state"], "error")
        self.assertEqual(repo_parsed["error_kind"], "repo")
        self.assertEqual(
            repo_parsed["error_subkind"],
            "",
            msg="error:repo (no subkind) must not invent a subkind",
        )
        self.assertEqual(
            repo_parsed["detail"],
            "Repository refresh error",
            msg="legacy error:repo body must remain unchanged for non-readonly_fs failures",
        )

        solver_parsed = state["solverParsed"]
        self.assertEqual(solver_parsed["state"], "error")
        self.assertEqual(solver_parsed["error_kind"], "solver")
        self.assertEqual(solver_parsed["error_code"], "1")

        # --- 2. _downloaderMaybeNotifyError() emits the right notifications.
        notify_calls = state["notifyCalls"]
        self.assertEqual(
            len(notify_calls),
            3,
            msg=f"expected exactly 3 notifications (readonly_fs, repo, solver); got {len(notify_calls)}: {notify_calls!r}",
        )

        ro_call = notify_calls[0]
        repo_call = notify_calls[1]
        solver_call = notify_calls[2]

        # readonly_fs
        self.assertIsNotNone(ro_call, "readonly_fs notification must be emitted")
        self.assertEqual(ro_call.get("title"), "Downloader prefetch error")
        self.assertEqual(ro_call.get("level"), "error")
        ro_id = str(ro_call.get("id") or "")
        self.assertTrue(
            ro_id.endswith("inc-downloader-repo-readonly-fs")
            or ro_id.endswith("inc-downloader-repo-readonly_fs"),
            msg=(
                "readonly_fs notification must use the new sub-classed incident id "
                f"`inc-downloader-repo-readonly-fs`; got: {ro_id!r}"
            ),
        )
        ro_body = str(ro_call.get("body") or "")
        self.assertIn(
            "ReadWritePaths=",
            ro_body,
            msg=(
                "WebUI Notification Center body for error:repo:readonly_fs must "
                "explicitly mention ReadWritePaths= so the user knows the unit "
                "config fix. Got body: " + ro_body
            ),
        )
        self.assertIn(
            "error:repo:readonly_fs",
            ro_body,
            msg=(
                "Notification body must echo the raw error:repo:readonly_fs "
                "status so support reports include the structured subkind. "
                f"Got body: {ro_body!r}"
            ),
        )

        # generic error:repo
        self.assertIsNotNone(repo_call, "generic error:repo notification must be emitted")
        repo_id = str(repo_call.get("id") or "")
        self.assertTrue(
            repo_id.endswith("inc-downloader-repo"),
            msg=f"generic error:repo must keep the legacy incident id `inc-downloader-repo`; got: {repo_id!r}",
        )
        # IMPORTANT: legacy error:repo body must NOT mention ReadWritePaths= so
        # we don't regress messaging for unrelated repo refresh failures.
        repo_body = str(repo_call.get("body") or "")
        self.assertNotIn(
            "ReadWritePaths=",
            repo_body,
            msg=(
                "Legacy error:repo (no subkind) must NOT mention "
                "ReadWritePaths= - that wording is reserved for the readonly_fs "
                f"subkind. Got body: {repo_body!r}"
            ),
        )

        # solver error
        self.assertIsNotNone(solver_call, "error:solver notification must be emitted")
        solver_id = str(solver_call.get("id") or "")
        self.assertTrue(
            solver_id.endswith("inc-downloader-solver-1"),
            msg=f"error:solver:1 must keep the existing incident id `inc-downloader-solver-1`; got: {solver_id!r}",
        )


if __name__ == "__main__":
    unittest.main()
