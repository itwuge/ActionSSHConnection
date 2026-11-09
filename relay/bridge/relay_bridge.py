#!/usr/bin/env python3
"""
文件: relay_bridge.py
所属目录: relay/bridge/
文件用途: 中继侧无状态网页桥接服务; 按 session_id 把浏览器 WS 与 runner 反连 WS 配对并原样转发二进制帧.
架构定位: 中继端进程; 上游是 nginx 的浏览器入口与 runner 反连两个 location(默认 /ws/ 与 /runner/), 下游是 runner 主动反连的 WS.
核心功能: 两条 WS 端点, 内存配对, 单帧上限 1 MiB, 每会话浏览器上限 2, 重复 runner 注册拒绝,
          只透传帧字节, 不解析业务帧, 不打印负载, 不写任何帧内容到磁盘或日志.
职责边界: 不做 WebAuthn 验签, 不做准入判定, 不持有用户私钥或口令, 不落盘会话状态, 不监听公网地址.
运行环境: Ubuntu 20.04 / Python 3.8 及以上; 依赖 websockets==10.4.
依赖关系: 复用同目录 jsonl_logger.py; 由 systemd 单元 actssh-web-bridge.service 拉起.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import signal
import sys
from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple

import websockets
from websockets.exceptions import ConnectionClosed

try:  # 作为包导入时用相对导入, 直接执行脚本时退化为同目录导入
    from .jsonl_logger import JsonLogger
except ImportError:  # pragma: no cover - 取决于启动方式
    from jsonl_logger import JsonLogger

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8081

# 单帧上限 1 MiB; 与前端帧协议的单帧上限一致, 超出由 websockets 以 1009 关闭.
MAX_FRAME_BYTES = 1024 * 1024
# 每会话浏览器连接上限; 第三路以 ROUTE_CONFLICT 拒绝.
MAX_BROWSERS_PER_SESSION = 2
# 单连接待处理队列帧数; 与 MemoryMax=128M 一起兜住内存.
MAX_QUEUE_FRAMES = 16

# WebSocket 关闭码: 1008 策略违规, 1001 对端离开, 1003 不支持的数据类型(文本帧).
CLOSE_POLICY_VIOLATION = 1008
CLOSE_GOING_AWAY = 1001
CLOSE_UNSUPPORTED_DATA = 1003

# 关闭原因令牌, 与设计更正的三个令牌一致; 前端按该令牌提示「会话已结束或不存在」.
REASON_ROUTE_CONFLICT = "ROUTE_CONFLICT"
REASON_ROUTE_GONE = "ROUTE_GONE"
REASON_UNKNOWN_SESSION = "UNKNOWN_SESSION"
# 文本帧不是业务协议的一部分; 仅用于关闭原因, 不属于设计更正的三个路由令牌.
REASON_TEXT_FRAME = "PROTOCOL_TEXT_FRAME"

_SESSION_ID_MIN = 8
_SESSION_ID_MAX = 128
_SESSION_ID_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")


@dataclass
class BridgeConfig:
    """桥接进程运行参数; 除 host/port 外都有安全默认值."""

    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT
    max_frame_bytes: int = MAX_FRAME_BYTES
    max_browsers: int = MAX_BROWSERS_PER_SESSION
    ping_interval: float = 20.0
    ping_timeout: float = 20.0
    run_id: str = ""
    log_level: str = "INFO"
    browser_prefix: str = "/ws"
    runner_prefix: str = "/runner"


@dataclass
class Route:
    """一条会话路由; 只存内存, 进程退出即丢弃."""

    session_id: str
    runner: object
    browsers: List[object] = field(default_factory=list)
    bytes_runner_to_browsers: int = 0
    bytes_browsers_to_runner: int = 0


def _is_valid_session_id(session_id: str) -> bool:
    """只接受受限字符集与长度, 避免把路径片段当路由键滥用."""
    if not _SESSION_ID_MIN <= len(session_id) <= _SESSION_ID_MAX:
        return False
    return all(ch in _SESSION_ID_CHARS for ch in session_id)


def _parse_route(
    path: str,
    browser_prefix: str = "/ws",
    runner_prefix: str = "/runner",
) -> Optional[Tuple[str, str]]:
    """
    解析 WS 请求路径.

    :param path: 请求路径, 可带查询串.
    :param browser_prefix: 浏览器入口前缀, 默认 /ws.
    :param runner_prefix: runner 反连前缀, 默认 /runner.
    :return: (kind, session_id), kind 为 runner 或 browser; 非法路径返回 None.
    """
    raw = path.split("?", 1)[0]
    parts = [p for p in raw.split("/") if p]
    browser_parts = [p for p in browser_prefix.split("/") if p]
    runner_parts = [p for p in runner_prefix.split("/") if p]
    if len(parts) == len(browser_parts) + 1 and parts[: len(browser_parts)] == browser_parts:
        kind_token, session_id = "browser", parts[-1]
    elif len(parts) == len(runner_parts) + 1 and parts[: len(runner_parts)] == runner_parts:
        kind_token, session_id = "runner", parts[-1]
    else:
        return None
    if not _is_valid_session_id(session_id):
        return None
    return (kind_token, session_id)


def _peer(websocket: object) -> Optional[str]:
    """取对端地址; 只用于连接元数据日志."""
    address = getattr(websocket, "remote_address", None)
    if not address:
        return None
    try:
        return str(address[0]) + ":" + str(address[1])
    except (IndexError, TypeError):
        return None


class Bridge:
    """内存配对 + 字节转发的桥接服务."""

    def __init__(self, config: BridgeConfig, logger: JsonLogger) -> None:
        self._config = config
        self._logger = logger
        self._routes: dict = {}
        self._server: Optional[object] = None
        self._port: int = config.port

    @property
    def port(self) -> int:
        """实际监听端口; 端口传 0 时由内核分配, 用于自测."""
        return self._port

    @property
    def active_routes(self) -> int:
        """当前已注册 runner 的会话数; 健康检查与重启取证都用它."""
        return len(self._routes)

    def browser_count(self, session_id: str) -> int:
        """某会话当前挂接的浏览器数; 只读, 用于自测与诊断."""
        route = self._routes.get(session_id)
        return len(route.browsers) if route is not None else 0

    async def start(self) -> None:
        """绑定并开始接受 WS 连接; 只监听配置给出的地址."""
        self._server = await websockets.serve(
            self._dispatch,
            self._config.host,
            self._config.port,
            max_size=self._config.max_frame_bytes,
            max_queue=MAX_QUEUE_FRAMES,
            ping_interval=self._config.ping_interval,
            ping_timeout=self._config.ping_timeout,
        )
        sockets = getattr(self._server, "sockets", None) or []
        if sockets:
            self._port = sockets[0].getsockname()[1]

    async def stop(self) -> None:
        """停服: 先断开全部连接, 再关闭监听; 不保留任何配对."""
        for route in list(self._routes.values()):
            await self._safe_close(route.runner, CLOSE_GOING_AWAY, "SHUTDOWN")
            for browser in list(route.browsers):
                await self._safe_close(browser, CLOSE_GOING_AWAY, "SHUTDOWN")
        self._routes.clear()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        self._logger.log("INFO", "bridge.stopped", "桥接进程已停止, 配对已清空", active_routes=0)

    async def _dispatch(self, websocket: object, path: str) -> None:
        """按路径分流到 runner 注册或浏览器接入."""
        parsed = _parse_route(path, self._config.browser_prefix, self._config.runner_prefix)
        if parsed is None:
            self._logger.log(
                "WARNING",
                "bridge.protocol.rejected",
                f"WS 路径不属于 {self._config.browser_prefix}/<session_id> 或 {self._config.runner_prefix}/<session_id>, 拒绝连接",
                route_path_kind="invalid",
                remote=_peer(websocket),
                close_reason=REASON_UNKNOWN_SESSION,
            )
            await self._safe_close(websocket, CLOSE_POLICY_VIOLATION, REASON_UNKNOWN_SESSION)
            return
        kind, session_id = parsed
        if kind == "runner":
            await self._handle_runner(websocket, session_id)
        else:
            await self._handle_browser(websocket, session_id)

    async def _handle_runner(self, websocket: object, session_id: str) -> None:
        """runner 反连注册; 同会话只允许一条, 后来者以 ROUTE_CONFLICT 拒绝."""
        existing = self._routes.get(session_id)
        if existing is not None:
            self._logger.log(
                "WARNING",
                "bridge.runner.rejected",
                "同一会话已有 runner 注册, 拒绝后来的注册",
                session_id=session_id,
                remote=_peer(websocket),
                close_reason=REASON_ROUTE_CONFLICT,
            )
            await self._safe_close(websocket, CLOSE_POLICY_VIOLATION, REASON_ROUTE_CONFLICT)
            return

        route = Route(session_id=session_id, runner=websocket)
        self._routes[session_id] = route
        self._logger.log(
            "INFO",
            "bridge.runner.connected",
            "runner 反连已注册",
            session_id=session_id,
            remote=_peer(websocket),
            browsers=0,
            active_routes=len(self._routes),
        )
        protocol_error = ""
        try:
            async for message in websocket:
                if not isinstance(message, (bytes, bytearray)):
                    protocol_error = REASON_TEXT_FRAME
                    self._logger.log(
                        "WARNING",
                        "bridge.protocol.rejected",
                        "runner 发送文本帧, 只接受二进制帧",
                        session_id=session_id,
                        frame_kind="text",
                        close_reason=REASON_TEXT_FRAME,
                    )
                    break
                route.bytes_runner_to_browsers += len(message)
                dead: List[object] = []
                for browser in route.browsers:
                    try:
                        await browser.send(message)
                    except ConnectionClosed:
                        dead.append(browser)
                for browser in dead:
                    if browser in route.browsers:
                        route.browsers.remove(browser)
        except ConnectionClosed:
            pass
        finally:
            if self._routes.get(session_id) is route:
                del self._routes[session_id]
            browsers = list(route.browsers)
            route.browsers.clear()
            for browser in browsers:
                await self._safe_close(browser, CLOSE_GOING_AWAY, REASON_ROUTE_GONE)
            code = getattr(getattr(websocket, "close_code", None), "value", None)
            self._logger.log(
                "INFO",
                "bridge.runner.closed",
                "runner 反连已断开, 会话路由已清理",
                session_id=session_id,
                browsers_closed=len(browsers),
                bytes_from_runner=route.bytes_runner_to_browsers,
                bytes_to_runner=route.bytes_browsers_to_runner,
                close_code=code,
                close_reason=protocol_error or REASON_ROUTE_GONE,
                active_routes=len(self._routes),
            )
            if protocol_error:
                await self._safe_close(websocket, CLOSE_UNSUPPORTED_DATA, protocol_error)

    async def _handle_browser(self, websocket: object, session_id: str) -> None:
        """浏览器接入; 无 runner 时 UNKNOWN_SESSION, 超出上限时 ROUTE_CONFLICT."""
        route = self._routes.get(session_id)
        if route is None:
            self._logger.log(
                "WARNING",
                "bridge.browser.rejected",
                "会话不存在或 runner 尚未注册, 拒绝浏览器接入",
                session_id=session_id,
                remote=_peer(websocket),
                close_reason=REASON_UNKNOWN_SESSION,
            )
            await self._safe_close(websocket, CLOSE_POLICY_VIOLATION, REASON_UNKNOWN_SESSION)
            return
        if len(route.browsers) >= self._config.max_browsers:
            self._logger.log(
                "WARNING",
                "bridge.browser.rejected",
                "同一会话浏览器连接已达上限, 拒绝接入",
                session_id=session_id,
                remote=_peer(websocket),
                browsers=len(route.browsers),
                max_browsers=self._config.max_browsers,
                close_reason=REASON_ROUTE_CONFLICT,
            )
            await self._safe_close(websocket, CLOSE_POLICY_VIOLATION, REASON_ROUTE_CONFLICT)
            return

        route.browsers.append(websocket)
        self._logger.log(
            "INFO",
            "bridge.browser.connected",
            "浏览器已接入会话",
            session_id=session_id,
            remote=_peer(websocket),
            browsers=len(route.browsers),
        )
        protocol_error = ""
        try:
            async for message in websocket:
                if not isinstance(message, (bytes, bytearray)):
                    protocol_error = REASON_TEXT_FRAME
                    self._logger.log(
                        "WARNING",
                        "bridge.protocol.rejected",
                        "浏览器发送文本帧, 只接受二进制帧",
                        session_id=session_id,
                        frame_kind="text",
                        close_reason=REASON_TEXT_FRAME,
                    )
                    break
                route.bytes_browsers_to_runner += len(message)
                try:
                    await route.runner.send(message)
                except ConnectionClosed:
                    break
        except ConnectionClosed:
            pass
        finally:
            if websocket in route.browsers:
                route.browsers.remove(websocket)
            code = getattr(getattr(websocket, "close_code", None), "value", None)
            self._logger.log(
                "INFO",
                "bridge.browser.closed",
                "浏览器连接已断开",
                session_id=session_id,
                browsers=len(route.browsers),
                close_code=code,
                close_reason=protocol_error or None,
            )
            if protocol_error:
                await self._safe_close(websocket, CLOSE_UNSUPPORTED_DATA, protocol_error)

    async def _safe_close(self, websocket: Optional[object], code: int, reason: str) -> None:
        """关闭连接并吞掉重复关闭; 关闭原因只用令牌, 不带负载."""
        if websocket is None:
            return
        try:
            await websocket.close(code, reason)
        except (ConnectionClosed, OSError, RuntimeError):
            pass


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="ActSSH 中继网页桥接服务(无状态字节转发)")
    parser.add_argument("--host", default=os.environ.get("BRIDGE_LISTEN_HOST", DEFAULT_HOST), help="监听地址, 只允许回环或 docker 网桥")
    parser.add_argument("--port", type=int, default=int(os.environ.get("BRIDGE_LISTEN_PORT", DEFAULT_PORT)), help="监听端口")
    parser.add_argument("--max-frame-bytes", type=int, default=MAX_FRAME_BYTES, help="单帧上限字节数")
    parser.add_argument("--max-browsers", type=int, default=MAX_BROWSERS_PER_SESSION, help="每会话浏览器上限")
    parser.add_argument("--browser-prefix", default=os.environ.get("BRIDGE_BROWSER_PREFIX", "/ws"), help="浏览器 WS 入口前缀, 默认 /ws")
    parser.add_argument("--runner-prefix", default=os.environ.get("BRIDGE_RUNNER_PREFIX", "/runner"), help="runner 反连 WS 前缀, 默认 /runner")
    parser.add_argument("--run-id", default=None, help="日志 run_id, 缺省取 GITHUB_RUN_ID 或时间戳")
    parser.add_argument("--log-level", choices=("DEBUG", "INFO", "WARNING", "ERROR"), default="INFO", help="日志级别")
    return parser


def _warn(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def main(argv: Optional[Sequence[str]] = None) -> int:
    """
    进程入口.

    :return: 0 正常退出; 2 配置错误; 130 被 SIGINT 中断.
    """
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.host in ("", "0.0.0.0", "::", "[::]"):
        _warn("监听地址不允许为空或通配地址; 只允许回环或 docker 网桥地址")
        return 2
    if not 1 <= args.port <= 65535:
        _warn("端口必须在 1..65535 之间")
        return 2
    if args.max_frame_bytes <= 0 or args.max_browsers <= 0:
        _warn("帧上限与会话浏览器上限必须为正数")
        return 2

    run_id = args.run_id or os.environ.get("GITHUB_RUN_ID") or os.environ.get("BRIDGE_RUN_ID") or f"pid{os.getpid()}"
    logger = JsonLogger(run_id, "scripts.bridge.relay_bridge", args.log_level, stream=sys.stdout)
    config = BridgeConfig(
        host=args.host,
        port=args.port,
        max_frame_bytes=args.max_frame_bytes,
        max_browsers=args.max_browsers,
        run_id=run_id,
        log_level=args.log_level,
        browser_prefix=args.browser_prefix,
        runner_prefix=args.runner_prefix,
    )

    async def _serve() -> None:
        bridge = Bridge(config, logger)
        stop_event = asyncio.Event()
        loop = asyncio.get_event_loop()
        for sig_name in ("SIGINT", "SIGTERM"):
            sig = getattr(signal, sig_name, None)
            if sig is None:
                continue
            try:
                loop.add_signal_handler(sig, stop_event.set)
            except (NotImplementedError, RuntimeError):
                # Windows 与本机调试环境没有 POSIX 信号; 由调用方直接 stop.
                pass
        await bridge.start()
        logger.log(
            "INFO",
            "bridge.started",
            "桥接服务已监听, 当前无任何配对",
            listen_host=config.host,
            listen_port=bridge.port,
            max_frame_bytes=config.max_frame_bytes,
            max_browsers=config.max_browsers,
            active_routes=0,
        )
        try:
            await stop_event.wait()
        finally:
            await bridge.stop()

    try:
        asyncio.run(_serve())
    except KeyboardInterrupt:
        _warn("桥接服务被中断")
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
