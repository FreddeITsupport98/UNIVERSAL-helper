#!/usr/bin/env python3
# RUNNER_OPTIONAL=1
# RUNNER_RUNTIME=playwright
import re
import unittest
from python_regression_bootstrap import resolve_target_script_path as _resolve_target_script_path

try:
    from playwright.sync_api import sync_playwright
except Exception:  # pragma: no cover - optional dependency
    sync_playwright = None


class WebUiPollParseRecoveryPlaywrightRegressionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script_path = _resolve_target_script_path(__file__)
        cls.script_text = cls.script_path.read_text(encoding="utf-8")

    @classmethod
    def _extract_function(cls, name: str) -> str:
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
        needed_functions = [
            "_pollLiveWarnParse",
            "pollLive",
        ]
        funcs_js = "\n\n".join(self._extract_function(f) for f in needed_functions)

        return f"""<!doctype html>
<html>
<head><meta charset="utf-8"></head>
<body>
  <div id="status-text">INIT</div>
  <script>
    window.__fetchQueue = [];
    window.__fetchedUrls = [];
    window.__warns = [];
    window.__applied = [];

    var liveEnabled = true;
    var ZNH_DEBUG = false;
    var liveFailures = 0;
    var _pollLiveLastGoodData = null;
    var _pollLiveLastGoodTs = 0;
    var _pollLiveParseWarnLastMs = 0;
    var _pollLiveInFlight = false;

    window.ZNH = {{
      state: {{}},
      recordState: function(_name, _detail) {{}}
    }};

    function applyLiveData(d) {{
      var v = '';
      try {{ v = String((d && d.last_status) || ''); }} catch (e0) {{ v = ''; }}
      window.__applied.push(v);
      var el = document.getElementById('status-text');
      if (el) el.textContent = v;
    }}

    function znhDispatch(_name, _detail) {{ return false; }}
    function znhDebugWarn(_a, _b) {{}}
    function _znhSetLiveStatusUi() {{}}
    function toast(_title, _body, _level) {{}}

    function znhUiWarn(msg) {{
      window.__warns.push(String(msg || ''));
    }}

    function znhParseJsonLenient(txt, _label) {{
      try {{
        var parsed = JSON.parse(String(txt || ''));
        return {{ ok: true, value: parsed, recovered: false, error: '', snippet: '' }};
      }} catch (e0) {{
        return {{
          ok: false,
          value: null,
          recovered: false,
          error: String((e0 && e0.message) ? e0.message : 'parse failed'),
          snippet: String(txt || '').slice(0, 48)
        }};
      }}
    }}

    function znhFetch(url, _opts) {{
      window.__fetchedUrls.push(String(url || ''));
      var next = window.__fetchQueue.length ? window.__fetchQueue.shift() : null;
      if (!next) next = {{ ok: true, status: 200, body: '{{}}' }};
      return Promise.resolve({{
        ok: !!next.ok,
        status: Number(next.status || 200),
        text: function() {{
          return Promise.resolve(String(next.body || ''));
        }}
      }});
    }}

    {funcs_js}

    window.__runScenario = async function() {{
      // 1) Initial good payload seeds last-good cache.
      // 2) Malformed payload + malformed retry should fall back to last-good.
      // 3) Next good payload should recover forward to new status.
      window.__fetchQueue = [
        {{ ok: true, status: 200, body: '{{"last_status":"GOOD-1"}}' }},
        {{ ok: true, status: 200, body: '{{"last_status":' }},
        {{ ok: true, status: 200, body: '{{"last_status":' }},
        {{ ok: true, status: 200, body: '{{"last_status":"GOOD-2"}}' }}
      ];

      await pollLive(true);
      var after1 = document.getElementById('status-text').textContent;

      await pollLive(true);
      var after2 = document.getElementById('status-text').textContent;

      await pollLive(true);
      var after3 = document.getElementById('status-text').textContent;

      return {{
        after1: String(after1 || ''),
        after2: String(after2 || ''),
        after3: String(after3 || ''),
        applied: window.__applied.slice(),
        warns: window.__warns.slice(),
        fetchedUrls: window.__fetchedUrls.slice()
      }};
    }};
  </script>
</body>
</html>
"""

    def test_poll_live_keeps_last_good_before_recovery(self) -> None:
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

        self.assertEqual(state["after1"], "GOOD-1")
        self.assertEqual(
            state["after2"],
            "GOOD-1",
            "Malformed status-data payload should preserve last-good rendered status before recovery",
        )
        self.assertEqual(state["after3"], "GOOD-2")
        self.assertEqual(state["applied"], ["GOOD-1", "GOOD-1", "GOOD-2"])
        self.assertTrue(
            any("cached last-good status snapshot" in w for w in state["warns"]),
            "Expected parse-fallback warning mentioning cached last-good snapshot",
        )
        self.assertTrue(
            any("&retry=1" in u for u in state["fetchedUrls"]),
            "Expected pollLive retry fetch URL with retry marker",
        )


if __name__ == "__main__":
    unittest.main()
