#!/usr/bin/env python3
"""
文件: test_relay_bridge.py
所属目录: scripts/bridge/
文件用途: 中继桥接服务的本地自测; 用真实 WS 客户端模拟 runner 与浏览器.
架构定位: 单元测试; 只验证配对、透传、拒绝、清理、帧上限与日志白名单, 不验证真机 nginx 与 wss.
核心功能: 未知会话拒绝、配对双向透传、重复 runner 拒绝、第三路浏览器拒绝、双浏览器广播、
          runner 断开清理、重启清空映射、1 MiB 边界、文本帧拒绝、日志无负载.
职责边界: 不启动 systemd, 不访问网络, 不读取任何凭据文件.
运行环境: Python 3.8 及以上; 需先安装 scripts/requirements-web-bridge.txt.
依赖关系: 被测对象为同目录 relay_bridge.py; 客户端使用 websockets.
"""

from __future__ import annotations

import asyncio
import io
import unittest
from typing import Callable

import websockets
from websockets.exceptions import ConnectionClosed

try:
    from .relay_bridge import Bridge, BridgeConfig
    from .jsonl_logger import JsonLogger
except ImportError:  # 直接以脚本方式运行时走同目录导入
    from relay_bridge import Bridge, BridgeConfig  # type: ignore[no-redef]
    from jsonl_logger import JsonLogger  # type: ignore[no-redef]

SESSION = "sess-bridge-0001"
SESSION_B = "sess-bridge-0002"
MI_B = 1024 * 1024


async def _wait_until(predicate: Callable[[], bool], timeout: float = 5.0) -> None:
    """轮询等待条件成立; 避免依赖事件循环的内部调度顺序."""
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if predicate():
            return
        await asyncio.sleep(0.01)
    raise AssertionError("等待条件超时")


class BridgeTestCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.log_stream = io.StringIO()
        self.logger = JsonLogger("test-run", "scripts.bridge.relay_bridge", "DEBUG", stream=self.log_stream)
        self.config = BridgeConfig(host="127.0.0.1", port=0, ping_interval=None, ping_timeout=None)
        self.bridge = Bridge(self.config, self.logger)
        await self.bridge.start()
        self.base = f"ws://127.0.0.1:{self.bridge.port}"
        self._clients = []

    async def asyncTearDown(self) -> None:
        for client in self._clients:
            try:
                await client.close()
            except Exception:
                pass
        await self.bridge.stop()

    async def connect(self, path: str):
        client = await websockets.connect(self.base + path, max_size=2 * MI_B, close_timeout=2)
        self._clients.append(client)
        return client

    async def expect_closed(self, client, code: int, reason: str) -> None:
        with self.assertRaises(ConnectionClosed) as ctx:
            await asyncio.wait_for(client.recv(), timeout=5)
        frame = getattr(ctx.exception, "rcvd", None)
        self.assertIsNotNone(frame)
        self.assertEqual(frame.code, code)
        self.assertEqual(frame.reason, reason)

    async def test_unknown_session_rejected(self) -> None:
        browser = await self.connect("/ws/" + SESSION)
        await self.expect_closed(browser, 1008, "UNKNOWN_SESSION")

    async def test_invalid_path_rejected(self) -> None:
        for path in ("/bad", "/ws/", "/ws/short", "/other/" + SESSION, "//" + SESSION):
            client = await self.connect(path)
            await self.expect_closed(client, 1008, "UNKNOWN_SESSION")

    async def test_pairing_and_passthrough(self) -> None:
        runner = await self.connect("/runner/" + SESSION)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        browser = await self.connect("/ws/" + SESSION)
        await _wait_until(lambda: self.bridge.browser_count(SESSION) == 1)

        marker = b"SECRET-PAYLOAD-MARKER"
        await browser.send(marker)
        self.assertEqual(await asyncio.wait_for(runner.recv(), timeout=5), marker)

        await runner.send(b"\x00\x01binary-frame-payload")
        self.assertEqual(await asyncio.wait_for(browser.recv(), timeout=5), b"\x00\x01binary-frame-payload")

        await runner.close()
        await _wait_until(lambda: self.bridge.active_routes == 0)
        self.assertNotIn("SECRET-PAYLOAD-MARKER", self.log_stream.getvalue())
        self.assertNotIn("binary-frame-payload", self.log_stream.getvalue())
        log_text = self.log_stream.getvalue()
        self.assertIn("bridge.runner.connected", log_text)
        self.assertIn("bridge.browser.connected", log_text)

    async def test_duplicate_runner_rejected(self) -> None:
        first = await self.connect("/runner/" + SESSION)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        second = await self.connect("/runner/" + SESSION)
        await self.expect_closed(second, 1008, "ROUTE_CONFLICT")

        # 首个注册仍然有效, 没有被静默顶替
        self.assertEqual(self.bridge.active_routes, 1)
        browser = await self.connect("/ws/" + SESSION)
        await _wait_until(lambda: self.bridge.browser_count(SESSION) == 1)
        await browser.send(b"still-first")
        self.assertEqual(await asyncio.wait_for(first.recv(), timeout=5), b"still-first")

    async def test_third_browser_rejected_and_broadcast(self) -> None:
        runner = await self.connect("/runner/" + SESSION)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        b1 = await self.connect("/ws/" + SESSION)
        b2 = await self.connect("/ws/" + SESSION)
        await _wait_until(lambda: self.bridge.browser_count(SESSION) == 2)
        b3 = await self.connect("/ws/" + SESSION)
        await self.expect_closed(b3, 1008, "ROUTE_CONFLICT")

        await runner.send(b"broadcast")
        self.assertEqual(await asyncio.wait_for(b1.recv(), timeout=5), b"broadcast")
        self.assertEqual(await asyncio.wait_for(b2.recv(), timeout=5), b"broadcast")

    async def test_runner_disconnect_cleans_route(self) -> None:
        runner = await self.connect("/runner/" + SESSION_B)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        browser = await self.connect("/ws/" + SESSION_B)
        await _wait_until(lambda: self.bridge.browser_count(SESSION_B) == 1)

        await runner.close()
        await self.expect_closed(browser, 1001, "ROUTE_GONE")
        await _wait_until(lambda: self.bridge.active_routes == 0)
        self.assertEqual(self.bridge.browser_count(SESSION_B), 0)

        again = await self.connect("/ws/" + SESSION_B)
        await self.expect_closed(again, 1008, "UNKNOWN_SESSION")

    async def test_restart_clears_mapping(self) -> None:
        await self.connect("/runner/" + SESSION)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        await self.bridge.stop()
        self.assertEqual(self.bridge.active_routes, 0)
        self.assertEqual(self.bridge.browser_count(SESSION), 0)

    async def test_one_mib_frame_passes(self) -> None:
        runner = await self.connect("/runner/" + SESSION)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        browser = await self.connect("/ws/" + SESSION)
        await _wait_until(lambda: self.bridge.browser_count(SESSION) == 1)

        payload = b"x" * MI_B
        await browser.send(payload)
        received = await asyncio.wait_for(runner.recv(), timeout=10)
        self.assertEqual(len(received), MI_B)

    async def test_frame_over_one_mib_rejected(self) -> None:
        runner = await self.connect("/runner/" + SESSION)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        browser = await self.connect("/ws/" + SESSION)
        await _wait_until(lambda: self.bridge.browser_count(SESSION) == 1)

        closed: ConnectionClosed
        try:
            await browser.send(b"y" * (MI_B + 1))
            await asyncio.wait_for(browser.recv(), timeout=10)
        except ConnectionClosed as exc:
            closed = exc
        else:
            self.fail("超过 1 MiB 的帧未被拒绝")
        frame = getattr(closed, "rcvd", None)
        self.assertIsNotNone(frame)
        self.assertEqual(frame.code, 1009)

    async def test_text_frame_rejected(self) -> None:
        runner = await self.connect("/runner/" + SESSION)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        browser = await self.connect("/ws/" + SESSION)
        await _wait_until(lambda: self.bridge.browser_count(SESSION) == 1)

        await browser.send("text-frame")
        await self.expect_closed(browser, 1003, "PROTOCOL_TEXT_FRAME")

    async def test_runner_text_frame_rejected(self) -> None:
        runner = await self.connect("/runner/" + SESSION)
        await _wait_until(lambda: self.bridge.active_routes == 1)
        browser = await self.connect("/ws/" + SESSION)
        await _wait_until(lambda: self.bridge.browser_count(SESSION) == 1)

        await runner.send("text-frame")
        await self.expect_closed(runner, 1003, "PROTOCOL_TEXT_FRAME")
        await self.expect_closed(browser, 1001, "ROUTE_GONE")
        await _wait_until(lambda: self.bridge.active_routes == 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
