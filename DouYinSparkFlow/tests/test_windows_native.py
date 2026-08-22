"""Windows Native runtime-layer tests.

These tests cover the runtime plumbing that makes douyin-sparkflow run on
Windows without Docker/WSL2. They deliberately avoid business logic.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

from core import protocol_dispatch


class NodeLaunchPathTests(unittest.TestCase):
    """Module 1: Node startup path for the protocol sender."""

    def test_node_executable_prefers_sparkflow_node_bin(self):
        with mock.patch.dict(os.environ, {"SPARKFLOW_NODE_BIN": "C:\\tools\\node.exe"}, clear=False):
            with mock.patch.object(protocol_dispatch.shutil, "which", return_value=None) as which_mock:
                result = protocol_dispatch._node_executable()
        self.assertEqual(result, "C:\\tools\\node.exe")
        which_mock.assert_called_once_with("C:\\tools\\node.exe")

    def test_node_executable_resolves_configured_bin_through_path(self):
        with mock.patch.dict(os.environ, {"SPARKFLOW_NODE_BIN": "custom-node"}, clear=False):
            with mock.patch.object(
                protocol_dispatch.shutil,
                "which",
                side_effect=lambda name: "C:\\nodejs\\node.exe" if name == "custom-node" else None,
            ) as which_mock:
                result = protocol_dispatch._node_executable()
        self.assertEqual(result, "C:\\nodejs\\node.exe")
        which_mock.assert_called_once_with("custom-node")

    def test_node_executable_falls_back_to_path_node(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            with mock.patch.object(protocol_dispatch.shutil, "which", return_value="C:\\nodejs\\node.exe") as which_mock:
                result = protocol_dispatch._node_executable()
        self.assertEqual(result, "C:\\nodejs\\node.exe")
        which_mock.assert_called_once_with("node")

    def test_build_protocol_command_uses_configured_node(self):
        with mock.patch.dict(os.environ, {"SPARKFLOW_NODE_BIN": "C:\\tools\\node.exe"}, clear=False):
            with mock.patch.object(protocol_dispatch.shutil, "which", return_value=None):
                command, cwd, label, runtime_root = protocol_dispatch._build_protocol_command()
        self.assertEqual(command[0], "C:\\tools\\node.exe")
        self.assertEqual(label, "local-node")
        self.assertTrue(str(command[1]).endswith("protocol_sender.mjs"))
        self.assertEqual(cwd, protocol_dispatch.repo_root())
        self.assertEqual(runtime_root, str(protocol_dispatch.repo_root()))

    @unittest.skipIf(os.name != "nt", "Windows-only branch; not applicable on POSIX")
    def test_windows_without_node_raises_actionable_error_without_docker(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            with mock.patch.object(protocol_dispatch.shutil, "which", return_value=None):
                with self.assertRaises(RuntimeError) as ctx:
                    protocol_dispatch._build_protocol_command()
        message = str(ctx.exception)
        self.assertIn("Node.js", message)
        self.assertIn("SPARKFLOW_NODE_BIN", message)
        self.assertIn("useProtocolSender", message)
        self.assertNotIn("docker", message.lower())

    @unittest.skipIf(os.name == "nt", "POSIX-only branch; runs on Linux CI")
    def test_posix_without_node_still_falls_back_to_docker(self):
        # Regression guard: the Linux/Docker fallback must stay intact.
        with mock.patch.dict(os.environ, {}, clear=False):
            with mock.patch.object(
                protocol_dispatch.shutil,
                "which",
                side_effect=lambda name: "/usr/bin/docker" if name == "docker" else None,
            ):
                command, _cwd, label, _runtime_root = protocol_dispatch._build_protocol_command()
        self.assertEqual(label, "docker-node-helper")
        self.assertIn("docker", command[0].lower())

    def test_protocol_script_executes_under_real_node(self):
        node = protocol_dispatch._node_executable()
        if not node:
            self.skipTest("node is not available in this environment")
        script = protocol_dispatch.PROTOCOL_SCRIPT
        result = subprocess.run(
            [node, str(script)],
            input="",
            text=True,
            capture_output=True,
            timeout=60,
            cwd=str(protocol_dispatch.repo_root()),
        )
        # With an empty stdin payload the script must fail immediately with a
        # clear error -- proof that Node can actually launch the protocol
        # sender on this platform.
        combined = (result.stdout or "") + (result.stderr or "")
        self.assertIn("Missing JSON payload", combined)


def _make_temp_dir():
    """Create a temp dir via plain os.makedirs.

    The sandbox on this machine restricts writes inside directories created
    by tempfile.mkdtemp, so tests must build their own scratch dirs.
    """
    import uuid

    path = Path(tempfile.gettempdir()) / ("wntest-" + uuid.uuid4().hex)
    path.mkdir(parents=True)
    return path


def _rmdir_tree_manual(root: Path):
    """Remove a small tree without shutil.rmtree (sandbox-restricted here)."""
    for p in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if p.is_dir():
            p.rmdir()
        else:
            p.unlink()
    root.rmdir()


@unittest.skipUnless(os.name == "nt", "Windows scheduling tests run on Windows only")
class WindowsScheduleTests(unittest.TestCase):
    """Module 2: Windows scheduling (state/cron/root spool + cmd execution)."""

    def test_build_task_run_spec_uses_local_python(self):
        from webui import ops

        command, cwd = ops.build_task_run_spec()
        self.assertEqual(command, [sys.executable, "main.py", "--doTask"])
        self.assertEqual(cwd, ops.repo_root())

    def test_build_scheduled_task_command_uses_cmd_syntax(self):
        from webui import ops

        command = ops.build_scheduled_task_command()
        self.assertIn("cd /d", command)
        self.assertIn("main.py --doTask", command)
        self.assertNotIn("/bin/bash", command)
        self.assertNotIn("docker", command.lower())

    def test_build_scheduled_task_command_injects_env_via_set(self):
        from webui import ops

        command = ops.build_scheduled_task_command(extra_env={"SPARKFLOW_MANUAL_RUN": "1"})
        self.assertIn('set "SPARKFLOW_MANUAL_RUN=1"', command)

    def test_replace_douyin_cron_schedule_windows_redirect_and_lines(self):
        from webui import ops

        updated = ops.replace_douyin_cron_schedule("", "10:00-18:00/20m")
        lines = [line for line in updated.splitlines() if line.strip()]
        self.assertEqual(len(lines), 3)
        for line in lines:
            self.assertIn("main.py --doTask", line)
            self.assertIn(r">> logs\ops.log 2>&1", line)
            self.assertNotIn("/var/log", line)

    def test_read_crontab_windows_reads_repo_spool(self):
        from webui import ops

        tmp = _make_temp_dir()
        try:
            spool = tmp / "state" / "cron" / "root"
            spool.parent.mkdir(parents=True)
            spool.write_text("*/20 10-17 * * * python main.py --doTask\n", encoding="utf-8")
            with mock.patch.object(ops, "windows_crontab_path", return_value=spool):
                content = ops.read_crontab()
            self.assertIn("main.py --doTask", content)
        finally:
            _rmdir_tree_manual(tmp)

    def test_update_daily_schedule_windows_writes_spool(self):
        from webui import ops

        tmp = _make_temp_dir()
        try:
            spool = tmp / "state" / "cron" / "root"
            with mock.patch.object(ops, "windows_crontab_path", return_value=spool):
                with mock.patch.object(ops, "persist_schedule_config") as persist_mock:
                    with mock.patch.object(ops, "read_crontab", return_value=""):
                        result = ops.update_daily_schedule("10:00-18:00/20m")
            persist_mock.assert_called_once_with("10:00-18:00/20m")
            self.assertEqual(result.returncode, 0)
            text = spool.read_text(encoding="utf-8")
            self.assertIn("main.py --doTask", text)
            self.assertIn(r">> logs\ops.log 2>&1", text)
        finally:
            _rmdir_tree_manual(tmp)

    def test_ops_log_file_windows_defaults_to_repo_logs(self):
        from webui import ops

        with mock.patch.object(
            ops, "get_app_settings", return_value={"ops_log_file": "/var/log/douyin-sparkflow.log"}
        ):
            path = ops._ops_log_file()
        self.assertEqual(path, str(ops.repo_root() / "logs" / "ops.log"))

    def test_ops_log_file_respects_configured_path_on_windows(self):
        from webui import ops

        with mock.patch.object(ops, "get_app_settings", return_value={"ops_log_file": "C:\\custom\\ops.log"}):
            path = ops._ops_log_file()
        self.assertEqual(path, "C:\\custom\\ops.log")

    def test_cron_runner_executes_commands_via_cmd_on_windows(self):
        import scripts.cron_runner as cron_runner

        with mock.patch.object(cron_runner.subprocess, "Popen") as popen_mock:
            with mock.patch.object(cron_runner, "read_crontab", return_value=["1 2 3 4 5 echo hi"]):
                with mock.patch.object(cron_runner, "line_should_run", return_value=(True, "echo hi")):
                    with mock.patch.object(cron_runner.time, "sleep", side_effect=KeyboardInterrupt):
                        with self.assertRaises(KeyboardInterrupt):
                            cron_runner.run_loop(Path("unused"))
        # cmd /c with the command passed verbatim (no argv joining, no
        # extra wrapping) so embedded quotes survive (see cron_runner.py).
        popen_mock.assert_called_once_with("cmd /c echo hi")

    def test_cron_runner_cmd_invocation_survives_embedded_quotes(self):
        import scripts.cron_runner as cron_runner

        with mock.patch.object(cron_runner.subprocess, "Popen") as popen_mock:
            with mock.patch.object(cron_runner, "read_crontab", return_value=["1 2 3 4 5 x"]):
                with mock.patch.object(
                    cron_runner,
                    "line_should_run",
                    return_value=(True, 'cd /d "C:\\some app" && "C:\\some app\\sparkflow.exe" --doTask'),
                ):
                    with mock.patch.object(cron_runner.time, "sleep", side_effect=KeyboardInterrupt):
                        with self.assertRaises(KeyboardInterrupt):
                            cron_runner.run_loop(Path("unused"))
        called = popen_mock.call_args.args[0]
        self.assertTrue(called.startswith("cmd /c "))
        self.assertIn('cd /d "C:\\some app"', called)
        self.assertNotIn("main.py", called)

    # ---- PACKED (PyInstaller portable build) task invocation regression ----
    # The packaged sparkflow.exe IS the main.py entry, so every generated
    # command must be "<exe> --doTask" -- never "<exe> main.py --doTask".

    def _packed(self):
        from utils.config import Environment
        from webui import ops as _ops

        return mock.patch.object(_ops, "get_environment", return_value=Environment.PACKED)

    def test_build_task_run_spec_packed_omits_main_py(self):
        from webui import ops

        with self._packed():
            command, cwd = ops.build_task_run_spec()
        self.assertEqual(command, [sys.executable, "--doTask"])
        self.assertNotIn("main.py", command)

    def test_build_scheduled_task_command_packed_omits_main_py(self):
        from webui import ops

        with self._packed():
            command = ops.build_scheduled_task_command()
        self.assertIn("--doTask", command)
        self.assertNotIn("main.py", command)
        self.assertNotRegex(command, r"sparkflow\.exe[^\n]*main\.py")

    def test_build_scheduled_task_command_packed_keeps_env_injection(self):
        from webui import ops

        with self._packed():
            command = ops.build_scheduled_task_command(extra_env={"SPARKFLOW_MANUAL_RUN": "1"})
        self.assertIn('set "SPARKFLOW_MANUAL_RUN=1"', command)
        self.assertNotIn("main.py", command)

    def test_source_mode_keeps_main_py_invocation(self):
        from webui import ops

        # Default environment (LOCAL) is the source-mode contract:
        # `python main.py --doTask` must stay untouched.
        command, _cwd = ops.build_task_run_spec()
        self.assertEqual(command, [sys.executable, "main.py", "--doTask"])
        scheduled = ops.build_scheduled_task_command()
        self.assertIn("main.py --doTask", scheduled)

    def test_task_schedule_markers_cover_packed_invocation(self):
        from webui import ops

        # replace_douyin_cron_schedule() must recognize BOTH spellings so the
        # spool never accumulates duplicate task lines after a mode switch.
        self.assertIn("--doTask", ops.TASK_SCHEDULE_MARKERS)
        for line in ("python main.py --doTask >> logs", "sparkflow.exe --doTask >> logs"):
            self.assertTrue(
                any(marker in line for marker in ops.TASK_SCHEDULE_MARKERS),
                f"marker set should match: {line}",
            )

    def test_replace_douyin_cron_schedule_packed_is_idempotent(self):
        from webui import ops

        with self._packed():
            first = ops.replace_douyin_cron_schedule("", "10:00-18:00/20m")
            second = ops.replace_douyin_cron_schedule(first, "10:00-18:00/20m")
        self.assertNotIn("main.py", first)
        self.assertNotIn("main.py", second)
        # Idempotent: replacing the previously generated spool yields the same
        # line count (old task lines are removed, not duplicated).
        first_lines = [line for line in first.splitlines() if line.strip()]
        second_lines = [line for line in second.splitlines() if line.strip()]
        self.assertEqual(len(first_lines), 3)
        self.assertEqual(len(second_lines), 3)

    # ---- PACKED data-root placement (spool/logs/locks next to the exe) ----

    def _exe_dir(self):
        return Path(sys.executable).resolve().parent

    def test_data_root_packed_points_to_exe_dir(self):
        from webui import ops

        with self._packed():
            root = ops._data_root()
        self.assertEqual(root, self._exe_dir())

    def test_data_root_source_mode_points_to_repo_root(self):
        from webui import ops

        # Default environment (LOCAL) keeps the source-mode contract.
        self.assertEqual(ops._data_root(), ops.repo_root())

    def test_windows_crontab_path_packed_lives_next_to_exe(self):
        from webui import ops

        with self._packed():
            path = ops.windows_crontab_path()
        self.assertEqual(path, self._exe_dir() / "state" / "cron" / "root")
        # It must NOT resolve into the bundled runtime dir (_internal).
        self.assertNotIn("_internal", str(path))

    def test_ops_log_file_packed_lives_next_to_exe(self):
        from webui import ops

        with mock.patch.object(
            ops, "get_app_settings", return_value={"ops_log_file": "/var/log/douyin-sparkflow.log"}
        ):
            with self._packed():
                path = ops._ops_log_file()
        self.assertEqual(path, str(self._exe_dir() / "logs" / "ops.log"))
        self.assertNotIn("_internal", path)

    def test_build_task_run_spec_packed_cwd_is_exe_dir(self):
        from webui import ops

        with self._packed():
            command, cwd = ops.build_task_run_spec()
        self.assertEqual(command, [sys.executable, "--doTask"])
        self.assertEqual(cwd, self._exe_dir())

    def test_build_scheduled_task_command_packed_cds_to_exe_dir(self):
        from webui import ops

        with self._packed():
            command = ops.build_scheduled_task_command()
        self.assertIn(f'cd /d "{self._exe_dir()}"', command)
        self.assertNotIn("_internal", command)

    def test_task_run_lock_status_packed_uses_exe_dir_lock(self):
        from webui import ops

        with self._packed():
            status = ops.task_run_lock_status()
        self.assertEqual(status["running"], False)
        self.assertTrue(str(status["path"]).startswith(str(self._exe_dir())))
        self.assertNotIn("_internal", str(status["path"]))


@unittest.skipUnless(os.name == "nt", "Windows-only: login desktop replacement")
class LoginDesktopWindowsTests(unittest.TestCase):
    """Module 3: login-desktop replacement on Windows Native mode."""

    def test_profile_dir_defaults_to_repo_state_on_windows(self):
        import login_desktop_server as lds
        from utils.config import repo_root

        with mock.patch.dict(os.environ, {}, clear=False):
            result = lds._default_profile_dir()
        self.assertEqual(result, repo_root() / "state" / "login-profile")

    def test_profile_dir_honors_logindesktop_profile_env(self):
        import login_desktop_server as lds

        with mock.patch.dict(os.environ, {"LOGIN_DESKTOP_PROFILE_DIR": "C:\\tmp\\prof"}, clear=False):
            result = lds._default_profile_dir()
        self.assertEqual(result, Path("C:\\tmp\\prof"))

    def test_login_desktop_server_serves_api(self):
        """Boot the login desktop server as a child process and probe its API.

        This is the Windows replacement for the X11/noVNC login desktop: the
        same FastAPI service runs natively (headful Chromium window on the
        local desktop) and the Web UI keeps talking to it on 127.0.0.1.
        """
        import urllib.request

        source_root = Path(__file__).resolve().parents[1]
        port = "18091"
        env = os.environ.copy()
        env["LOGIN_DESKTOP_API_PORT"] = port
        proc = subprocess.Popen(
            [sys.executable, "login_desktop_server.py"],
            cwd=str(source_root),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.time() + 30
            health_ok = False
            while time.time() < deadline:
                if proc.poll() is not None:
                    self.fail(f"login desktop server exited early rc={proc.returncode}")
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as resp:
                        if resp.status == 200:
                            health_ok = True
                            break
                except Exception:
                    time.sleep(0.5)
            self.assertTrue(health_ok, "login desktop server /health did not become ready")
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/status", timeout=5) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            self.assertIn("running", payload)
            self.assertFalse(payload.get("logged_in", False))
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()