#!/usr/bin/env python3
import ast
import builtins
import contextlib
import io
import json
import tempfile
import types
import unittest
from dataclasses import dataclass
from email.message import Message
from python_regression_bootstrap import resolve_target_script_path as _resolve_target_script_path
from unittest import mock


_MISSING = object()


@contextlib.contextmanager
def _override(ns: dict, **repls):
    old = {}
    for k, v in repls.items():
        old[k] = ns.get(k, _MISSING)
        ns[k] = v
    try:
        yield
    finally:
        for k, prev in old.items():
            if prev is _MISSING:
                ns.pop(k, None)
            else:
                ns[k] = prev


def _extract_dashboard_api_python_source(script_text: str) -> str:
    marker = "if write_atomic \"${DASH_API_BIN}\" <<'PYEOF'"
    start = script_text.find(marker)
    if start < 0:
        raise RuntimeError("Could not locate embedded dashboard API python block start marker")
    start += len(marker)
    end = script_text.find("\nPYEOF", start)
    if end < 0:
        raise RuntimeError("Could not locate embedded dashboard API python block end marker")
    return script_text[start:end].lstrip("\n")


@dataclass(frozen=True)
class _CapsMockProfile:
    root_fstype: str = "btrfs"
    snapper_installed: bool = True
    snapper_root_config: bool = True
    bls_present: bool = True
    grub_present: bool = True
    grub_bls_mode: bool = True
    loader_conf_present: bool = False
    grub_read_error: bool = False
    os_release_text: str = "ID=mocklinux\nID_LIKE=mock\n"


@contextlib.contextmanager
def _mock_caps_probe_environment(ns: dict, profile: _CapsMockProfile):
    class _CP:
        def __init__(self, stdout: str, rc: int = 0):
            self.stdout = stdout
            self.returncode = rc

    def _fake_run(cmd, **_kwargs):  # noqa: ANN001
        c = list(cmd or [])
        if c[:5] == ["findmnt", "-n", "-o", "FSTYPE", "/"]:
            return _CP(f"{profile.root_fstype}\n", 0)
        return _CP("", 0)

    def _fake_which(name: str):
        n = str(name or "").strip()
        if n == "snapper":
            return "/usr/bin/snapper" if profile.snapper_installed else None
        return None

    entries_dir = "/boot/loader/entries"
    grub_cfg_primary = "/boot/grub2/grub.cfg"
    grub_cfg_secondary = "/boot/grub/grub.cfg"
    bls_files = [
        f"{entries_dir}/snapper-aaa.conf",
        f"{entries_dir}/normal-bbb.conf",
    ]
    grub_text = "menuentry 'mock' {}\n"
    if profile.grub_bls_mode:
        grub_text = "insmod blscfg\nblscfg\nmenuentry 'mock' {}\n"

    _orig_open = builtins.open
    _orig_glob = ns["glob"].glob
    _orig_isdir = ns["os"].path.isdir
    _orig_exists = ns["os"].path.exists
    _orig_isfile = ns["os"].path.isfile
    _orig_getsize = ns["os"].path.getsize

    def _fake_open(path, mode="r", *args, **kwargs):  # noqa: ANN001
        p = str(path or "")
        if p == grub_cfg_primary and "r" in str(mode or "r") and profile.grub_present:
            if profile.grub_read_error:
                raise OSError("mock grub read failure")
            return io.StringIO(grub_text)
        if p == "/etc/os-release" and "r" in str(mode or "r"):
            return io.StringIO(str(profile.os_release_text or ""))
        return _orig_open(path, mode, *args, **kwargs)

    def _fake_glob(pattern):  # noqa: ANN001
        pat = str(pattern or "")
        if pat == f"{entries_dir}/*.conf":
            return list(bls_files) if profile.bls_present else []
        if pat.startswith("/boot/efi/EFI/"):
            return []
        return _orig_glob(pattern)

    def _fake_isdir(path):  # noqa: ANN001
        p = str(path or "")
        if p == entries_dir:
            return bool(profile.bls_present)
        if p in ("/boot/efi/loader/entries", "/efi/loader/entries"):
            return False
        return bool(_orig_isdir(path))

    def _fake_exists(path):  # noqa: ANN001
        p = str(path or "")
        if p == grub_cfg_primary:
            return bool(profile.grub_present)
        if p == grub_cfg_secondary:
            return False
        return bool(_orig_exists(path))

    def _fake_isfile(path):  # noqa: ANN001
        p = str(path or "")
        if p == "/etc/snapper/configs/root":
            return bool(profile.snapper_root_config)
        if p in ("/boot/loader/loader.conf", "/efi/loader/loader.conf"):
            return bool(profile.loader_conf_present)
        if p == grub_cfg_primary:
            return bool(profile.grub_present)
        if p == grub_cfg_secondary:
            return False
        if p in bls_files:
            return bool(profile.bls_present)
        return bool(_orig_isfile(path))

    def _fake_getsize(path):  # noqa: ANN001
        p = str(path or "")
        if p in bls_files:
            return 128
        return int(_orig_getsize(path))

    with _override(ns, open=_fake_open):
        with mock.patch.object(ns["subprocess"], "run", side_effect=_fake_run):
            with mock.patch.object(ns["shutil"], "which", side_effect=_fake_which):
                with mock.patch.object(ns["glob"], "glob", side_effect=_fake_glob):
                    with mock.patch.object(ns["os"].path, "isdir", side_effect=_fake_isdir):
                        with mock.patch.object(ns["os"].path, "exists", side_effect=_fake_exists):
                            with mock.patch.object(ns["os"].path, "isfile", side_effect=_fake_isfile):
                                with mock.patch.object(ns["os"].path, "getsize", side_effect=_fake_getsize):
                                    yield


class EmbeddedDashboardApiSyntaxRegressionTest(unittest.TestCase):
    def test_embedded_dashboard_api_python_parses(self) -> None:
        script_path = _resolve_target_script_path(__file__)
        py_src = _extract_dashboard_api_python_source(script_path.read_text(encoding="utf-8"))
        ast.parse(py_src)


class SnapperCapabilitiesApiRuntimeRegressionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        script_path = _resolve_target_script_path(__file__)
        py_src = _extract_dashboard_api_python_source(script_path.read_text(encoding="utf-8"))
        cls.ns: dict = {"__name__": "znh_dashboard_api_test_caps_runtime"}
        exec(py_src, cls.ns, cls.ns)
        cls.handler_cls = cls.ns["Handler"]

    def _invoke_get(self, path: str, *, conf_path: str, server_extras: dict | None = None) -> tuple[int, dict]:
        h = object.__new__(self.handler_cls)
        h.path = path
        h.client_address = ("127.0.0.1", 0)
        h.rfile = io.BytesIO(b"")
        h.wfile = io.BytesIO()
        h.request_version = "HTTP/1.1"
        h.command = "GET"

        headers = Message()
        headers["X-ZNH-Token"] = "tok"
        headers["Origin"] = "http://127.0.0.1:8765"
        h.headers = headers

        state = {"code": 0}

        def _send_response(code: int, _msg: str | None = None):
            state["code"] = int(code)

        h.send_response = _send_response
        h.send_header = lambda *_args, **_kwargs: None
        h.end_headers = lambda: None

        server_kwargs = {
            "token": "tok",
            "conf_path": str(conf_path),
            "_znh_log": (lambda *_args, **_kwargs: None),
        }
        if server_extras:
            server_kwargs.update(server_extras)
        h.server = types.SimpleNamespace(**server_kwargs)

        self.handler_cls.do_GET(h)
        raw = h.wfile.getvalue().decode("utf-8", errors="replace").strip()
        payload = json.loads(raw or "{}")
        return int(state.get("code", 0) or 0), payload

    def _temp_file(self, content: str) -> str:
        tf = tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8")
        tf.write(content)
        tf.flush()
        tf.close()
        return tf.name

    def _invoke_caps_with_profile(self, profile: _CapsMockProfile) -> tuple[int, dict]:
        conf_path = self._temp_file("SELF_UPDATE_CHANNEL=\"stable\"\n")
        with _mock_caps_probe_environment(self.ns, profile):
            return self._invoke_get("/api/snapper/capabilities", conf_path=conf_path)

    def test_capabilities_all_prereqs_present_reports_supported(self) -> None:
        code, payload = self._invoke_caps_with_profile(
            _CapsMockProfile(
                root_fstype="btrfs",
                snapper_installed=True,
                snapper_root_config=True,
                bls_present=True,
                grub_present=True,
                grub_bls_mode=True,
                loader_conf_present=False,
            )
        )

        self.assertEqual(code, 200)
        self.assertTrue(bool(payload.get("ok")))
        self.assertEqual(str(payload.get("root_fstype") or ""), "btrfs")
        self.assertTrue(bool(payload.get("snapper_supported")))
        self.assertTrue(bool(payload.get("ghost_scrub_supported")))
        self.assertEqual(payload.get("snapper_missing_reasons"), [])
        self.assertEqual(payload.get("ghost_missing_reasons"), [])

    def test_capabilities_missing_prereqs_reports_reason_arrays(self) -> None:
        code, payload = self._invoke_caps_with_profile(
            _CapsMockProfile(
                root_fstype="ext4",
                snapper_installed=False,
                snapper_root_config=False,
                bls_present=False,
                grub_present=False,
                grub_bls_mode=False,
                loader_conf_present=False,
            )
        )

        self.assertEqual(code, 200)
        self.assertFalse(bool(payload.get("snapper_supported")))
        self.assertFalse(bool(payload.get("ghost_scrub_supported")))

        snap_reasons = payload.get("snapper_missing_reasons") or []
        ghost_reasons = payload.get("ghost_missing_reasons") or []

        self.assertIsInstance(snap_reasons, list)
        self.assertIsInstance(ghost_reasons, list)
        self.assertGreaterEqual(len(snap_reasons), 3)
        self.assertGreaterEqual(len(ghost_reasons), 4)
        self.assertEqual(len(snap_reasons), len(set(snap_reasons)))
        self.assertEqual(len(ghost_reasons), len(set(ghost_reasons)))

        snap_join = " | ".join(str(x) for x in snap_reasons)
        ghost_join = " | ".join(str(x) for x in ghost_reasons)
        self.assertIn("requires btrfs", snap_join)
        self.assertIn("snapper command is not installed", snap_join)
        self.assertIn("Missing /etc/snapper/configs/root", snap_join)
        self.assertIn("BLS entries directory was not detected", ghost_join)

    def test_capabilities_systemd_boot_loader_conf_enables_ghost_support(self) -> None:
        code, payload = self._invoke_caps_with_profile(
            _CapsMockProfile(
                root_fstype="btrfs",
                snapper_installed=True,
                snapper_root_config=True,
                bls_present=True,
                grub_present=False,
                grub_bls_mode=False,
                loader_conf_present=True,
            )
        )

        self.assertEqual(code, 200)
        self.assertTrue(bool(payload.get("snapper_supported")))
        self.assertTrue(bool(payload.get("systemd_boot_detected")))
        self.assertFalse(bool(payload.get("grub_detected")))
        self.assertTrue(bool(payload.get("ghost_scrub_supported")))
        self.assertEqual(payload.get("ghost_missing_reasons"), [])

    def test_capabilities_no_supported_bootloader_profile_reports_reason(self) -> None:
        code, payload = self._invoke_caps_with_profile(
            _CapsMockProfile(
                root_fstype="btrfs",
                snapper_installed=True,
                snapper_root_config=True,
                bls_present=True,
                grub_present=True,
                grub_bls_mode=False,
                loader_conf_present=False,
                grub_read_error=True,
            )
        )

        self.assertEqual(code, 200)
        self.assertTrue(bool(payload.get("snapper_supported")))
        self.assertTrue(bool(payload.get("bls_entries_present")))
        self.assertFalse(bool(payload.get("systemd_boot_detected")))
        self.assertFalse(bool(payload.get("grub_detected")))
        self.assertFalse(bool(payload.get("ghost_scrub_supported")))

        ghost_reasons = payload.get("ghost_missing_reasons") or []
        self.assertIsInstance(ghost_reasons, list)
        ghost_join = " | ".join(str(x) for x in ghost_reasons)
        self.assertIn("No supported bootloader profile detected", ghost_join)


if __name__ == "__main__":
    unittest.main()
