#!/usr/bin/env python3
"""
文件: test_start_web_bridge.py
所属目录: scripts/
文件用途: runner 侧桥接客户端的本地自测; 用真桥接 + 假准入子进程验证反连、透传、退出码与五字段输出.
架构定位: 单元/集成测试; 不覆盖真机 wss、Actions 网络策略与真实 WebAuthn.
核心功能: 地址拼接、参数校验、连接失败映射、注册被拒映射、准入子进程启动失败、端到端字节回环、子进程非零退出.
职责边界: 不启动 systemd, 不访问公网, 不落盘凭据.
运行环境: Python 3.8 及以上; 需先安装 scripts/requirements-web-bridge.txt.
依赖关系: 被测对象为 start_web_bridge.py; 中继侧复用 scripts/bridge/relay_bridge.py.
"""

from __future__ import annotations

import asyncio
import io
import json
import os
import socket
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import List

import websockets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import start_web_bridge as swb
from bridge.jsonl_logger import JsonLogger
from bridge.relay_bridge import Bridge, BridgeConfig

SESSION = "sess-runner-0001"

ECHO_SCRIPT = (
    "import sys\n"
    "data = sys.stdin.buffer.read1(65536)\n"
    "if data:\n"
    "    sys.stdout.buffer.write(data)\n"
    "    sys.stdout.buffer.flush()\n"
)


def _write_echo_script(directory: Path) -> str:
    path = directory / "echo_admission.py"
    path.write_text(ECHO_SCRIPT, encoding="utf-8")
    return str(path)


def _free_port() -> int:
    """取一个刚释放的端口, 用于连接失败用例."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def _silent_logger() -> JsonLogger:
    return JsonLogger("test-run", "scripts.start_web_bridge", "DEBUG", stream=io.StringIO())


class RunnerUrlTestCase(unittest.TestCase):
    def test_build_url_appends_single_slash(self) -> None:
        self.assertEqual(
            swb._build_runner_url(SESSION, "wss://wuge.fun/runner/"),
            f"wss://wuge.fun/runner/{SESSION}",
        )
        self.assertEqual(
            swb._build_runner_url(SESSION, "ws://172.17.0.1:8081/runner"),
            f"ws://172.17.0.1:8081/runner/{SESSION}",
        )

    def test_build_url_rejects_bad_base(self) -> None:
        for base in ("https://wuge.fun/runner", "wss://", "wss://user:pass@wuge.fun/runner", "wss://wuge.fun/runner?x=1"):
            with self.assertRaises(ValueError):
                swb._build_runner_url(SESSION, base)

    def test_session_id_validation(self) -> None:
        self.assertTrue(swb._is_valid_session_id(SESSION))
        for bad in ("short", "with space", "bad/slash", "a" * 129, ""):
            self.assertFalse(swb._is_valid_session_id(bad))


class PrecheckExitTestCase(unittest.TestCase):
    """main() 的参数阶段失败必须输出一行五字段 JSON 并以 2 退出."""

    def _run(self, argv: List[str]):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = swb.main(argv)
        lines = [line for line in out.getvalue().splitlines() if line.strip()]
        self.assertEqual(len(lines), 1, "stdout 必须恰好一行")
        record = json.loads(lines[0])
        self.assertEqual(set(record.keys()), {"ok", "message", "error_code", "data", "confirm"})
        return code, record

    def test_missing_arguments(self) -> None:
        code, record = self._run([])
        self.assertEqual(code, 2)
        self.assertFalse(record["ok"])
        self.assertEqual(record["error_code"], "ARGUMENT_INVALID")
        self.assertEqual(record["data"]["stage"], "precheck")

    def test_invalid_session_id(self) -> None:
        code, record = self._run(["short", "wss://wuge.fun/runner", "python3 x.py"])
        self.assertEqual(code, 2)
        self.assertEqual(record["error_code"], "SESSION_ID_INVALID")

    def test_invalid_bridge_url(self) -> None:
        code, record = self._run([SESSION, "https://wuge.fun/runner", "python3 x.py"])
        self.assertEqual(code, 2)
        self.assertEqual(record["error_code"], "BRIDGE_URL_INVALID")

    def test_empty_admission_command(self) -> None:
        code, record = self._run([SESSION, "wss://wuge.fun/runner", "   "])
        self.assertEqual(code, 2)
        self.assertEqual(record["error_code"], "ADMISSION_CMD_INVALID")


class ConnectFailureTestCase(unittest.TestCase):
    def test_connect_refused_returns_one(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        port = _free_port()
        with redirect_stdout(out), redirect_stderr(err):
            code = swb.main([SESSION, f"ws://127.0.0.1:{port}/runner", "python3 x.py"])
        self.assertEqual(code, 1)
        record = json.loads(out.getvalue().strip())
        self.assertFalse(record["ok"])
        self.assertEqual(record["error_code"], "BRIDGE_CONNECT_FAILED")
        self.assertEqual(record["data"]["stage"], "connect")
        self.assertEqual(record["confirm"], "")
        self.assertNotIn("x.py", out.getvalue())


class BridgeFlowTestCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.config = BridgeConfig(host="127.0.0.1", port=0, ping_interval=None, ping_timeout=None)
        self.bridge = Bridge(self.config, JsonLogger("test-run", "scripts.bridge.relay_bridge", "DEBUG", stream=io.StringIO()))
        await self.bridge.start()
        self.base = f"ws://127.0.0.1:{self.bridge.port}"
        self.temp_dir = tempfile.TemporaryDirectory()
        self.echo_path = _write_echo_script(Path(self.temp_dir.name))

    async def asyncTearDown(self) -> None:
        await self.bridge.stop()
        self.temp_dir.cleanup()

    def _runner_config(self, admission_argv: List[str]) -> swb.BridgeConfig:
        return swb.BridgeConfig(
            session_id=SESSION,
            bridge_url=f"{self.base}/runner/{SESSION}",
            admission_argv=admission_argv,
            connect_timeout=5.0,
            ping_interval=None,
            ping_timeout=None,
        )

    async def test_end_to_end_bytes_reach_admission(self) -> None:
        """浏览器 -> 桥接 -> runner 客户端 -> 准入门 -> 回程."""
        task = asyncio.ensure_future(
            swb.run_bridge(self._runner_config([sys.executable, self.echo_path]), _silent_logger())
        )
        deadline = asyncio.get_running_loop().time() + 5
        while self.bridge.active_routes != 1 and asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(0.01)
        self.assertEqual(self.bridge.active_routes, 1)

        browser = await websockets.connect(f"{self.base}/ws/{SESSION}", max_size=2 * 1024 * 1024)
        try:
            await browser.send(b"ping-through-bridge")
            self.assertEqual(await asyncio.wait_for(browser.recv(), timeout=10), b"ping-through-bridge")
            result = await asyncio.wait_for(task, timeout=20)
        finally:
            await browser.close()

        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.stage, "admission-exit")
        self.assertEqual(result.data["admission_exit"], 0)
        self.assertEqual(result.data["bytes_from_bridge"], len(b"ping-through-bridge"))
        self.assertEqual(result.data["bytes_to_bridge"], len(b"ping-through-bridge"))

    async def test_register_conflict_maps_to_exit_one(self) -> None:
        async def conflict_handler(websocket, path):
            await websocket.close(1008, "ROUTE_CONFLICT")

        server = await websockets.serve(conflict_handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        try:
            config = swb.BridgeConfig(
                session_id=SESSION,
                bridge_url=f"ws://127.0.0.1:{port}/runner/{SESSION}",
                admission_argv=[sys.executable, self.echo_path],
                connect_timeout=5.0,
                ping_interval=None,
                ping_timeout=None,
            )
            result = await asyncio.wait_for(swb.run_bridge(config, _silent_logger()), timeout=20)
        finally:
            server.close()
            await server.wait_closed()

        self.assertEqual(result.exit_code, 1)
        self.assertEqual(result.stage, "register-rejected")
        self.assertEqual(result.error_code, "ROUTE_CONFLICT")
        self.assertEqual(result.data["close_reason"], "ROUTE_CONFLICT")

    async def test_admission_spawn_failure_maps_to_exit_two(self) -> None:
        result = await asyncio.wait_for(
            swb.run_bridge(self._runner_config(["definitely-not-a-real-executable-xyz"]), _silent_logger()),
            timeout=20,
        )
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(result.stage, "admission-start")
        self.assertEqual(result.error_code, "ADMISSION_SPAWN_FAILED")

    async def test_admission_nonzero_exit_maps_to_exit_two(self) -> None:
        script = Path(self.temp_dir.name) / "fail_admission.py"
        script.write_text("raise SystemExit(3)\n", encoding="utf-8")
        result = await asyncio.wait_for(
            swb.run_bridge(self._runner_config([sys.executable, str(script)]), _silent_logger()),
            timeout=20,
        )
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(result.stage, "admission-exit")
        self.assertEqual(result.error_code, "ADMISSION_EXITED")
        self.assertEqual(result.data["admission_exit"], 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
