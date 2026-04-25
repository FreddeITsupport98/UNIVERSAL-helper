#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/target_resolver.sh"
TARGET_FILE="$(znh_regression_resolve_target_file "${REPO_ROOT}" "${1:-}")"

usage() {
    cat <<'EOF'
Usage: ./test_rocket_pm_runtime_recovery_sse_regression.sh [path/to/UNI-auto.sh]

Runtime regression for Rocket package-manager-aware recovery/SSE paths:
  - extracts embedded dashboard API Python helpers from UNI-auto.sh
  - executes _recover_system_dup_job in an isolated temp filesystem sandbox
  - validates package_manager recovery fallback from legacy status/logs (apt/dnf)
  - validates zypper-only output prettification gating in recovery payload
  - validates _job_update_progress_dup PM-aware stage/progress behavior used by SSE stream updates
  - validates /api/events/job SSE stream reset/append/done transitions with PM-aware payload behavior
  - validates /api/events/job self-update SSE stream reset/append/done transitions
EOF
}

FAILURES=()

record_failure() {
    local msg="$1"
    FAILURES+=("${msg}")
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ ! -f "${TARGET_FILE}" ]; then
    echo "FAIL SUMMARY (1)" >&2
    echo " - Target file not found: ${TARGET_FILE}" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}" 2>/dev/null || true' EXIT
REPORT_FILE="${TMP_ROOT}/runtime-failures.txt"

if ! python3 - "${TARGET_FILE}" "${REPORT_FILE}" <<'PY'
import ast
import os
import re
import sys
import tempfile
from pathlib import Path

target_path, report_path = sys.argv[1], sys.argv[2]
failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(str(msg))


def extract_embedded_dashboard_api(source_text: str) -> str:
    marker = "if write_atomic \"${DASH_API_BIN}\" <<'PYEOF'"
    idx = source_text.find(marker)
    if idx < 0:
        raise RuntimeError("dashboard API heredoc marker not found")
    tail = source_text[idx:].splitlines()
    in_block = False
    out_lines: list[str] = []
    for line in tail:
        if not in_block:
            if line.strip() == marker:
                in_block = True
            continue
        if line.strip() == "PYEOF":
            break
        out_lines.append(line)
    if not out_lines:
        raise RuntimeError("dashboard API heredoc content extraction failed")
    return "\n".join(out_lines) + "\n"


def extract_functions(py_src: str, names: set[str]) -> str:
    tree = ast.parse(py_src)
    src_lines = py_src.splitlines()
    selected_nodes = []
    found = set()
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in names:
            selected_nodes.append(node)
            found.add(node.name)
    missing = sorted(names - found)
    if missing:
        raise RuntimeError(f"missing embedded functions: {', '.join(missing)}")
    selected_nodes.sort(key=lambda n: int(getattr(n, "lineno", 0)))
    chunks = []
    for node in selected_nodes:
        start = int(getattr(node, "lineno", 0))
        end = int(getattr(node, "end_lineno", 0))
        if start <= 0 or end <= 0 or end < start:
            raise RuntimeError(f"invalid source range for function {node.name}")
        chunks.append("\n".join(src_lines[start - 1:end]))
    return "\n\n".join(chunks) + "\n"


def extract_classes(py_src: str, names: set[str]) -> str:
    tree = ast.parse(py_src)
    src_lines = py_src.splitlines()
    selected_nodes = []
    found = set()
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name in names:
            selected_nodes.append(node)
            found.add(node.name)
    missing = sorted(names - found)
    if missing:
        raise RuntimeError(f"missing embedded classes: {', '.join(missing)}")
    selected_nodes.sort(key=lambda n: int(getattr(n, "lineno", 0)))
    chunks = []
    for node in selected_nodes:
        start = int(getattr(node, "lineno", 0))
        end = int(getattr(node, "end_lineno", 0))
        if start <= 0 or end <= 0 or end < start:
            raise RuntimeError(f"invalid source range for class {node.name}")
        chunks.append("\n".join(src_lines[start - 1:end]))
    return "\n\n".join(chunks) + "\n"


def write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


try:
    source_text = Path(target_path).read_text(encoding="utf-8", errors="replace")
except Exception as exc:
    fail(f"failed to read target file: {exc}")
    source_text = ""

if source_text:
    try:
        py_src = extract_embedded_dashboard_api(source_text)
    except Exception as exc:
        fail(f"failed to extract dashboard API heredoc: {exc}")
        py_src = ""
else:
    py_src = ""

if py_src:
    needed_functions = {
        "_normalize_pm",
        "_dup_paths",
        "_su_paths",
        "_tail_file",
        "_read_file_effective_full",
        "_read_kv_status",
        "_detect_solver_conflict",
        "_zypper_xml_pretty",
        "_job_update_progress",
        "_job_update_progress_dup",
        "_recover_system_dup_job",
    }
    needed_classes = {"Handler"}
    try:
        funcs_src = extract_functions(py_src, needed_functions)
        classes_src = extract_classes(py_src, needed_classes)
    except Exception as exc:
        fail(f"failed to extract required embedded symbols: {exc}")
        funcs_src = ""
        classes_src = ""
else:
    funcs_src = ""
    classes_src = ""

env = {}
if funcs_src and classes_src:
    setup_src = "\n".join(
        [
            "import json",
            "import os",
            "import re",
            "import time",
            "from urllib.parse import parse_qs, urlparse",
            "SUPPORTED_PACKAGE_MANAGERS = {'zypper', 'apt', 'dnf', 'pacman'}",
            "DUP_LOG_DIR = ''",
            "DUP_STATUS_DIR = ''",
            "SU_LOG_DIR = ''",
            "SU_STATUS_DIR = ''",
            "JOB_OUTPUT_TAIL_CHARS = 120000",
            "SELF_UPDATE_API_MAX_CHARS = 80000",
            "class BaseHTTPRequestHandler:",
            "    def __init__(self, *args, **kwargs):",
            "        self._sent_status = None",
            "        self._sent_headers = []",
            "    def send_response(self, code):",
            "        self._sent_status = int(code)",
            "    def send_header(self, key, value):",
            "        self._sent_headers.append((str(key), str(value)))",
            "    def end_headers(self):",
            "        return None",
            "def _allowed_origin(origin):",
            "    return ''",
            "def _json_response(self, status, payload, origin=None):",
            "    try:",
            "        self.send_response(int(status))",
            "        self.send_header('Content-Type', 'application/json')",
            "        self.end_headers()",
            "        body = json.dumps(payload, ensure_ascii=False)",
            "        self.wfile.write(body.encode('utf-8', errors='replace'))",
            "        try:",
            "            self.wfile.flush()",
            "        except Exception:",
            "            pass",
            "    except Exception:",
            "        pass",
            "    return None",
        ]
    )
    try:
        exec(setup_src + "\n\n" + funcs_src + "\n\n" + classes_src, env, env)
    except Exception as exc:
        fail(f"failed to evaluate extracted function harness: {exc}")
if "_recover_system_dup_job" in env and "_job_update_progress_dup" in env and "Handler" in env:
    sandbox_root = tempfile.mkdtemp(prefix="znh-rocket-pm-runtime-")
    dup_log_dir = os.path.join(sandbox_root, "logs")
    dup_status_dir = os.path.join(sandbox_root, "status")
    os.makedirs(dup_log_dir, exist_ok=True)
    os.makedirs(dup_status_dir, exist_ok=True)

    env["DUP_LOG_DIR"] = dup_log_dir
    env["DUP_STATUS_DIR"] = dup_status_dir
    env["SU_LOG_DIR"] = dup_log_dir
    env["SU_STATUS_DIR"] = dup_status_dir
    env["JOB_OUTPUT_TAIL_CHARS"] = 200000

    def fake_run_cmd(cmd, timeout_s, log=None, extra_env=None):  # noqa: ANN001
        if isinstance(cmd, list) and len(cmd) >= 2 and cmd[0] == "systemctl" and cmd[1] == "show":
            return 1, ""
        return 0, ""

    def fake_detect_solver_conflict(text, rc, pm="zypper"):  # noqa: ANN001
        return False, ""

    env["_run_cmd"] = fake_run_cmd
    env["_detect_solver_conflict"] = fake_detect_solver_conflict

    recover = env["_recover_system_dup_job"]
    dup_paths = env["_dup_paths"]
    progress_fn = env["_job_update_progress_dup"]
    handler_cls = env["Handler"]

    pretty_calls = []

    def pretty_spy(text):  # noqa: ANN001
        pretty_calls.append(str(text))
        return "PRETTY::" + str(text)

    env["_zypper_xml_pretty"] = pretty_spy

    # Case 1: legacy status (no package_manager) should recover apt from log payload.
    apt_job = "aptjob000001"
    _, apt_log_path, apt_status_path = dup_paths(apt_job)
    write_text(
        apt_status_path,
        "\n".join(
            [
                "done=1",
                "rc=0",
                "simulate=0",
                "stage=running-package-manager",
                "",
            ]
        ),
    )
    write_text(
        apt_log_path,
        "\n".join(
            [
                "[webui] stage: running-package-manager",
                "env DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade",
                "=== RESTART CHECK (reboot-required markers) ===",
                "/run/reboot-required",
                "",
            ]
        ),
    )
    apt_payload = recover(apt_job)
    if not isinstance(apt_payload, dict):
        fail("apt recovery payload was not returned as a dict")
    else:
        if str(apt_payload.get("package_manager", "")) != "apt":
            fail(f"apt fallback package_manager mismatch (got={apt_payload.get('package_manager')!r})")
        if pretty_calls:
            fail("non-zypper apt recovery unexpectedly invoked zypper XML prettifier")
        if "reboot-required" not in str(apt_payload.get("restart_check_output", "")):
            fail("apt recovery did not extract reboot-required restart-check section")
        if str(apt_payload.get("output", "")).startswith("PRETTY::"):
            fail("apt recovery output should not be passed through zypper XML prettifier")

    # Case 2: zypper status should still use prettifier + zypper restart marker extraction.
    pretty_calls.clear()
    zypper_job = "zypper000001"
    _, zy_log_path, zy_status_path = dup_paths(zypper_job)
    write_text(
        zy_status_path,
        "\n".join(
            [
                "done=1",
                "rc=0",
                "simulate=0",
                "stage=running-package-manager",
                "package_manager=zypper",
                "",
            ]
        ),
    )
    write_text(
        zy_log_path,
        "\n".join(
            [
                "[webui] stage: running-package-manager",
                "<progress percent=\"42\" name=\"Resolving\"/>",
                "=== RESTART CHECK (zypper ps -s) ===",
                "restart-check-zypper",
                "",
            ]
        ),
    )
    zypper_payload = recover(zypper_job)
    if not isinstance(zypper_payload, dict):
        fail("zypper recovery payload was not returned as a dict")
    else:
        if str(zypper_payload.get("package_manager", "")) != "zypper":
            fail(f"zypper recovery package_manager mismatch (got={zypper_payload.get('package_manager')!r})")
        if len(pretty_calls) != 1:
            fail(f"zypper recovery should invoke prettifier exactly once (calls={len(pretty_calls)})")
        if not str(zypper_payload.get("output", "")).startswith("PRETTY::"):
            fail("zypper recovery output should be zypper XML prettified")
        if "restart-check-zypper" not in str(zypper_payload.get("restart_check_output", "")):
            fail("zypper recovery did not extract zypper restart-check marker section")

    # Case 3: dnf legacy status fallback recovery from log payload.
    pretty_calls.clear()
    dnf_job = "dnfjob000001"
    _, dnf_log_path, dnf_status_path = dup_paths(dnf_job)
    write_text(
        dnf_status_path,
        "\n".join(
            [
                "done=1",
                "rc=0",
                "simulate=0",
                "stage=running-package-manager",
                "",
            ]
        ),
    )
    write_text(
        dnf_log_path,
        "\n".join(
            [
                "[webui] stage: running-package-manager",
                "dnf -q check-update",
                "=== RESTART CHECK (needs-restarting -s) ===",
                "restart-check-dnf",
                "",
            ]
        ),
    )
    dnf_payload = recover(dnf_job)
    if not isinstance(dnf_payload, dict):
        fail("dnf recovery payload was not returned as a dict")
    else:
        if str(dnf_payload.get("package_manager", "")) != "dnf":
            fail(f"dnf fallback package_manager mismatch (got={dnf_payload.get('package_manager')!r})")
        if "restart-check-dnf" not in str(dnf_payload.get("restart_check_output", "")):
            fail("dnf recovery did not extract needs-restarting marker section")

    # PM-aware progress helper behavior (used by SSE append parser).
    p_apt = {"stage": "Starting", "progress": 0}
    progress_fn(p_apt, "[webui] stage: running-package-manager\n", pm="apt")
    if str(p_apt.get("stage", "")) != "Running apt":
        fail(f"apt running stage label mismatch (got={p_apt.get('stage')!r})")
    if int(p_apt.get("progress", 0) or 0) < 18:
        fail(f"apt running stage progress should bump to >=18 (got={p_apt.get('progress')!r})")
    progress_fn(p_apt, "Reading package lists... Done\n", pm="apt")
    if str(p_apt.get("stage", "")) != "Computing":
        fail(f"apt progress parser should classify 'Reading package lists' as Computing (got={p_apt.get('stage')!r})")

    p_dnf = {"stage": "Starting", "progress": 0}
    progress_fn(p_dnf, "[webui] stage: running-package-manager\n", pm="dnf")
    if str(p_dnf.get("stage", "")) != "Running dnf":
        fail(f"dnf running stage label mismatch (got={p_dnf.get('stage')!r})")

    p_zy = {"stage": "Starting", "progress": 0}
    progress_fn(p_zy, '<progress percent="42" name="Resolving package dependencies"/>\n', pm="zypper")
    if int(p_zy.get("progress", 0) or 0) != 42:
        fail(f"zypper xml progress parser expected 42 (got={p_zy.get('progress')!r})")
    if str(p_zy.get("stage", "")) != "Resolving package dependencies":
        fail(f"zypper xml progress parser stage mismatch (got={p_zy.get('stage')!r})")

    p_non_zy = {"stage": "Starting", "progress": 0}
    progress_fn(p_non_zy, '<progress percent="77" name="ShouldNotApply"/>\n', pm="apt")
    if int(p_non_zy.get("progress", 0) or 0) != 0:
        fail(f"non-zypper xml line should not alter progress (got={p_non_zy.get('progress')!r})")
    if str(p_non_zy.get("stage", "")) != "Starting":
        fail(f"non-zypper xml line should not alter stage (got={p_non_zy.get('stage')!r})")

    # SSE /api/events/job end-to-end stream checks.
    try:
        import io
        import json as pyjson
        import threading
        import time as pytime
    except Exception as exc:
        fail(f"failed to import SSE runtime harness modules: {exc}")
    else:
        sse_pretty_calls = []

        def pretty_spy_sse(text):  # noqa: ANN001
            sse_pretty_calls.append(str(text))
            return "PRETTY::" + str(text)

        env["_zypper_xml_pretty"] = pretty_spy_sse

        class _CaptureWFile(io.BytesIO):
            def flush(self):  # noqa: D401
                return None

        class _FakeServer:
            def __init__(self) -> None:
                self.token = "sse_runtime_token"

            @staticmethod
            def _znh_log(*_args, **_kwargs):  # noqa: ANN002, ANN003
                return None

        def parse_sse_events(raw_text: str) -> list[tuple[str, dict]]:
            out: list[tuple[str, dict]] = []
            for frame in (raw_text or "").split("\n\n"):
                lines = [ln for ln in frame.splitlines() if ln.strip()]
                if not lines:
                    continue
                ev_name = ""
                data_parts: list[str] = []
                for ln in lines:
                    if ln.startswith("event:"):
                        ev_name = ln.split(":", 1)[1].strip()
                    elif ln.startswith("data:"):
                        data_parts.append(ln.split(":", 1)[1].lstrip())
                if not ev_name or not data_parts:
                    continue
                try:
                    payload = pyjson.loads("".join(data_parts))
                except Exception:
                    continue
                if isinstance(payload, dict):
                    out.append((ev_name, payload))
            return out
        def collect_sse_events(h, run_err: list[str], context_label: str):  # noqa: ANN001
            if run_err:
                fail(f"SSE stream handler raised runtime error for {context_label}: {run_err[0]}")
                return None
            if int(getattr(h, "_sent_status", 0) or 0) != 200:
                fail(
                    f"SSE stream expected HTTP 200 for {context_label} "
                    f"(got={getattr(h, '_sent_status', None)!r})"
                )
                return None
            raw = h.wfile.getvalue().decode("utf-8", errors="replace")
            events = parse_sse_events(raw)
            if not events:
                fail(f"SSE stream emitted no parseable events for {context_label}")
                return None
            return events
        def validate_sse_sequence_and_extract_payloads(events: list[tuple[str, dict]], context_label: str):
            names = [ev for ev, _payload in events]
            if names[0] != "reset":
                fail(f"SSE stream first event should be reset for {context_label} (got={names[0]!r})")
            if "append" not in names:
                fail(f"SSE stream did not emit append event for {context_label}")
                return None, None
            if names[-1] != "done":
                fail(f"SSE stream final event should be done for {context_label} (got={names[-1]!r})")
            append_payload = None
            done_payload = None
            for ev, payload in events:
                if ev == "append" and append_payload is None:
                    append_payload = payload
                if ev == "done":
                    done_payload = payload
            return append_payload, done_payload
        def assert_sse_done_payload_contract(
            done_payload,  # noqa: ANN001
            context_label: str,
            expected_rc: int,
            expected_stage: str,
            expected_package_manager=None,  # noqa: ANN001
        ) -> None:
            if not isinstance(done_payload, dict):
                fail(f"SSE stream done payload missing for {context_label}")
                return
            if not bool(done_payload.get("done", False)):
                fail(f"SSE done payload should set done=true for {context_label}")
            if int(done_payload.get("progress", 0) or 0) != 100:
                fail(f"SSE done payload should set progress=100 for {context_label}")
            got_rc_raw = done_payload.get("rc", None)
            try:
                got_rc_int = int(got_rc_raw)
            except Exception:
                got_rc_int = -999999
            if got_rc_int != int(expected_rc):
                fail(
                    f"SSE done payload should set rc={int(expected_rc)} for {context_label} "
                    f"(got={got_rc_raw!r})"
                )
            done_stage = str(done_payload.get("stage", ""))
            if done_stage != str(expected_stage):
                fail(
                    f"SSE done payload stage mismatch for {context_label} "
                    f"(expected={str(expected_stage)!r}, got={done_stage!r})"
                )
            if expected_package_manager is not None:
                done_pm = str(done_payload.get("package_manager", ""))
                if done_pm != str(expected_package_manager):
                    fail(
                        f"SSE done payload package_manager mismatch for {context_label} "
                        f"(expected={str(expected_package_manager)!r}, got={done_pm!r})"
                    )
        def launch_sse_handler(job_type: str, job_id: str, client_port: int):
            h = handler_cls()
            h.server = _FakeServer()
            h.headers = {"X-ZNH-Token": h.server.token}
            h.client_address = ("127.0.0.1", int(client_port))
            h.path = f"/api/events/job?job_type={job_type}&job_id={job_id}"
            h.wfile = _CaptureWFile()
            h._sent_headers = []
            h._sent_status = None
            run_err: list[str] = []
            def _runner() -> None:
                try:
                    h.do_GET()
                except Exception as exc2:
                    run_err.append(str(exc2))
            t = threading.Thread(target=_runner, daemon=True)
            t.start()
            pytime.sleep(0.20)
            return h, t, run_err
        def wait_for_sse_thread_termination(t, context_label: str, timeout_s: float = 8.0):  # noqa: ANN001
            t.join(timeout=float(timeout_s))
            if t.is_alive():
                fail(f"SSE stream did not terminate for {context_label}")
                return False
            return True

        def run_sse_case(
            pm_name: str,
            job_id: str,
            append_chunk: str,
            expected_append_stage: str,
            min_append_progress: int,
            expect_pretty_append: bool,
        ) -> None:
            _unit, log_path2, status_path2 = dup_paths(job_id)
            write_text(
                status_path2,
                "\n".join(
                    [
                        "done=0",
                        "simulate=0",
                        f"package_manager={pm_name}",
                        "action=dup",
                        "",
                    ]
                ),
            )
            write_text(log_path2, "")
            h, t, run_err = launch_sse_handler("system-dup", job_id, 12345)
            with open(log_path2, "a", encoding="utf-8") as f:
                f.write(append_chunk)
            pytime.sleep(0.45)
            write_text(
                status_path2,
                "\n".join(
                    [
                        "rc=0",
                        "stage=done",
                        "simulate=0",
                        f"package_manager={pm_name}",
                        "action=dup",
                        "done=1",
                        "",
                    ]
                ),
            )
            if not wait_for_sse_thread_termination(t, f"pm={pm_name} case"):
                return
            context_label = f"pm={pm_name}"
            events = collect_sse_events(h, run_err, context_label)
            if events is None:
                return
            append_payload, done_payload = validate_sse_sequence_and_extract_payloads(events, context_label)
            if append_payload is None:
                fail(f"SSE stream append payload missing for {context_label}")
            else:
                got_pm = str(append_payload.get("package_manager", ""))
                if got_pm != pm_name:
                    fail(f"SSE append package_manager mismatch for {context_label} (got={got_pm!r})")
                got_stage = str(append_payload.get("stage", ""))
                if got_stage != expected_append_stage:
                    fail(
                        f"SSE append stage mismatch for {context_label} "
                        f"(expected={expected_append_stage!r}, got={got_stage!r})"
                    )
                got_progress = int(append_payload.get("progress", 0) or 0)
                if got_progress < int(min_append_progress):
                    fail(
                        f"SSE append progress too low for {context_label} "
                        f"(expected>={min_append_progress}, got={got_progress})"
                    )
                txt = str(append_payload.get("text", ""))
                if expect_pretty_append and not txt.startswith("PRETTY::"):
                    fail(f"SSE append should be zypper-prettified for {context_label}")
                if (not expect_pretty_append) and txt.startswith("PRETTY::"):
                    fail(f"SSE append should not be prettified for {context_label}")
            assert_sse_done_payload_contract(done_payload, context_label, expected_rc=0, expected_stage="Done")
        def run_self_update_sse_case(job_id: str, done_rc: int, done_stage_raw: str, expected_done_stage: str) -> None:
            _unit, log_path2, status_path2, _script_path2 = env["_su_paths"](job_id)
            write_text(
                status_path2,
                "\n".join(
                    [
                        "done=0",
                        "stage=starting",
                        "dry_run=0",
                        "channel=stable",
                        "",
                    ]
                ),
            )
            write_text(log_path2, "")
            h, t, run_err = launch_sse_handler("self-update", job_id, 12346)
            with open(log_path2, "a", encoding="utf-8") as f:
                f.write("downloading update\n")
            append_seen = False
            append_deadline = pytime.time() + 4.0
            while pytime.time() < append_deadline:
                raw_now = h.wfile.getvalue().decode("utf-8", errors="replace")
                if "event: append\n" in raw_now:
                    append_seen = True
                    break
                pytime.sleep(0.05)
            if not append_seen:
                fail("SSE stream did not emit append event before self-update completion gating")
            write_text(
                status_path2,
                "\n".join(
                    [
                        f"rc={int(done_rc)}",
                        f"stage={str(done_stage_raw)}",
                        "dry_run=0",
                        "channel=stable",
                        "done=1",
                        "",
                    ]
                ),
            )
            if not wait_for_sse_thread_termination(t, "self-update case"):
                return
            context_label = "self-update"
            events = collect_sse_events(h, run_err, context_label)
            if events is None:
                return
            append_payload, done_payload = validate_sse_sequence_and_extract_payloads(events, context_label)
            if append_payload is None:
                fail("SSE stream append payload missing for self-update")
            else:
                got_job_type = str(append_payload.get("job_type", ""))
                if got_job_type != "self-update":
                    fail(f"SSE append job_type mismatch for self-update (got={got_job_type!r})")
                got_pm = str(append_payload.get("package_manager", ""))
                if got_pm != "":
                    fail(f"SSE append package_manager should be empty for self-update (got={got_pm!r})")
                got_stage = str(append_payload.get("stage", ""))
                if got_stage not in ("Starting", "Downloading"):
                    fail(f"SSE append stage mismatch for self-update (got={got_stage!r})")
                got_progress = int(append_payload.get("progress", 0) or 0)
                if got_progress < 5:
                    fail(f"SSE append progress too low for self-update (expected>=5, got={got_progress})")
                txt = str(append_payload.get("text", ""))
                if txt.startswith("PRETTY::"):
                    fail("SSE append should not be zypper-prettified for self-update")
            assert_sse_done_payload_contract(
                done_payload,
                context_label,
                expected_rc=int(done_rc),
                expected_stage=str(expected_done_stage),
                expected_package_manager="",
            )

        run_sse_case(
            pm_name="apt",
            job_id="aptstream001",
            append_chunk="[webui] stage: running-package-manager\nReading package lists... Done\n",
            expected_append_stage="Computing",
            min_append_progress=18,
            expect_pretty_append=False,
        )
        run_sse_case(
            pm_name="zypper",
            job_id="zypstream01",
            append_chunk='<progress percent="42" name="Resolving package dependencies"/>\n',
            expected_append_stage="Resolving package dependencies",
            min_append_progress=42,
            expect_pretty_append=True,
        )
        run_self_update_sse_case(job_id="selfupd001", done_rc=0, done_stage_raw="done", expected_done_stage="Done")
        run_self_update_sse_case(job_id="selfupdfail", done_rc=17, done_stage_raw="failed", expected_done_stage="Failed")
else:
    fail("extracted runtime helpers are unavailable (_recover_system_dup_job/_su_paths/_read_file_effective_full/_job_update_progress/_job_update_progress_dup/Handler)")

Path(report_path).write_text("\n".join(failures), encoding="utf-8")
PY
then
    echo "FAIL SUMMARY (1)" >&2
    echo " - Python runtime harness failed to execute" >&2
    exit 1
fi

if [ -f "${REPORT_FILE}" ] && [ -s "${REPORT_FILE}" ]; then
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        record_failure "${line}"
    done < "${REPORT_FILE}"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAIL SUMMARY (${#FAILURES[@]})" >&2
    for f in "${FAILURES[@]}"; do
        echo " - ${f}" >&2
    done
    exit 1
fi

echo "PASS: Rocket PM-aware recovery/SSE runtime regression checks passed"
