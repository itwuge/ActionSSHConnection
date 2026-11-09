#!/usr/bin/env python3
"""
文件: start_web_bridge.py
所属目录: scripts/
文件用途: runner 侧网页桥接客户端; 主动出站反连中继桥接, 把 WS 字节流接到 web_admission.py 的 stdin/stdout.
架构定位: runner 端入口进程; 上游是工作流里的 start_web_bridge 步骤, 下游是中继 ws(s)://.../runner/<session_id> 与准入子进程.
核心功能: 解析三个位置参数, 建立反连, 启动准入子进程, 双向原样搬运字节, 按失败阶段显式非零退出,
          标准输出恰好一行五字段 JSON, 日志一律写 stderr.
职责边界: 不监听任何入站端口, 不解析业务帧, 不做 WebAuthn 验签, 不改 web_admission.py 的命令行契约, 不落盘凭据.
运行环境: Ubuntu 20.04 / Python 3.8 及以上; 依赖 websockets==10.4.
依赖关系: 复用 relay/bridge/jsonl_logger.py; 与 scripts/web_admission.py 通过管道协作.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence
from urllib.parse import urlsplit

import websockets
from websockets.exceptions import ConnectionClosed, InvalidHandshake, InvalidURI

_BRIDGE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "relay", "bridge")
if _BRIDGE_DIR not in sys.path:
    sys.path.insert(0, _BRIDGE_DIR)

from jsonl_logger import JsonLogger  # noqa: E402  (路径修正后导入)

DEFAULT_MAX_FRAME_BYTES = 1024 * 1024
DEFAULT_CONNECT_TIMEOUT = 10.0
DEFAULT_PING_INTERVAL = 20.0
DEFAULT_PING_TIMEOUT = 20.0

# 失败阶段名: 与日志 event 和 JSON data.stage 使用同一套值, 便于按阶段检索.
STAGE_PRECHECK = "precheck"
STAGE_CONNECT = "connect"
STAGE_REGISTER_REJECTED = "register-rejected"
STAGE_ADMISSION_START = "admission-start"
STAGE_BRIDGE = "bridge"
STAGE_ADMISSION_EXIT = "admission-exit"

_SESSION_ID_MIN = 8
_SESSION_ID_MAX = 128
_SESSION_ID_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

CONFIRM_TEXT = (
    "本进程只证明本地配对与双向字节透传可用; 真机 wss 可达、nginx Upgrade 与 WebAuthn 真实域名验签均待确认."
)


class BridgeProtocolError(Exception):
    """对端发送了协议外的帧类型; 只携带关闭原因令牌, 不携带帧内容."""


@dataclass
class BridgeConfig:
    """runner 侧客户端参数."""

    session_id: str
    bridge_url: str
    admission_argv: List[str]
    max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES
    connect_timeout: float = DEFAULT_CONNECT_TIMEOUT
    ping_interval: float = DEFAULT_PING_INTERVAL
    ping_timeout: float = DEFAULT_PING_TIMEOUT
    run_id: str = ""


@dataclass
class Counters:
    """只统计字节数, 不保留任何帧内容."""

    bytes_from_bridge: int = 0
    bytes_to_bridge: int = 0


@dataclass
class BridgeResult:
    """进程结果; 直接映射到五字段 JSON 与退出码."""

    exit_code: int
    stage: str
    message: str
    error_code: str = ""
    data: Dict[str, object] = field(default_factory=dict)


def _is_valid_session_id(session_id: str) -> bool:
    if not _SESSION_ID_MIN <= len(session_id) <= _SESSION_ID_MAX:
        return False
    return all(ch in _SESSION_ID_CHARS for ch in session_id)


def _build_runner_url(session_id: str, bridge_ws_base: str) -> str:
    """
    把 bridge_ws_base 与 session_id 拼成 runner 反连地址.

    :raises ValueError: 协议不是 ws/wss, 缺少主机, 带凭据或查询串.
    """
    parts = urlsplit(bridge_ws_base)
    if parts.scheme not in ("ws", "wss"):
        raise ValueError("bridge_ws_base 必须是 ws:// 或 wss://")
    if not parts.netloc:
        raise ValueError("bridge_ws_base 缺少主机")
    if parts.username or parts.password:
        raise ValueError("bridge_ws_base 不允许携带凭据")
    if parts.query or parts.fragment:
        raise ValueError("bridge_ws_base 不允许携带查询串或片段")
    path = parts.path.rstrip("/")
    return f"{parts.scheme}://{parts.netloc}{path}/{session_id}"


def _write_all(stream: object, data: bytes) -> None:
    """阻塞写满整段字节; 供线程池调用, 不解析内容."""
    view = memoryview(data)
    while view:
        written = stream.write(view)  # type: ignore[attr-defined]
        if not written:
            raise BrokenPipeError("准入子进程 stdin 已关闭")
        view = view[written:]


async def _pump_ws_to_child(websocket: object, child: "subprocess.Popen", counters: Counters) -> None:
    """WS -> 准入子进程 stdin; 只接受二进制帧."""
    loop = asyncio.get_running_loop()
    try:
        async for message in websocket:
            if not isinstance(message, (bytes, bytearray)):
                raise BridgeProtocolError("对端发送文本帧")
            counters.bytes_from_bridge += len(message)
            await loop.run_in_executor(None, _write_all, child.stdin, bytes(message))
    finally:
        try:
            child.stdin.close()  # type: ignore[union-attr]
        except (OSError, ValueError):
            pass


async def _pump_child_to_ws(child: "subprocess.Popen", websocket: object, counters: Counters) -> None:
    """准入子进程 stdout -> WS; 按块搬运, 不缓存整段会话."""
    loop = asyncio.get_running_loop()
    while True:
        chunk = await loop.run_in_executor(None, child.stdout.read, 65536)  # type: ignore[union-attr]
        if not chunk:
            return
        counters.bytes_to_bridge += len(chunk)
        await websocket.send(chunk)


async def _terminate_child(child: "subprocess.Popen") -> Optional[int]:
    """优雅终止子进程, 超时则强杀; 返回退出码."""
    if child.poll() is not None:
        return child.returncode
    try:
        child.terminate()
    except OSError:
        pass
    loop = asyncio.get_running_loop()
    try:
        return await asyncio.wait_for(loop.run_in_executor(None, child.wait), timeout=5.0)
    except asyncio.TimeoutError:
        try:
            child.kill()
        except OSError:
            pass
        try:
            return await asyncio.wait_for(loop.run_in_executor(None, child.wait), timeout=5.0)
        except asyncio.TimeoutError:
            return None


async def _silent_close(websocket: object, code: int, reason: str) -> None:
    try:
        await websocket.close(code, reason)
    except (ConnectionClosed, OSError, RuntimeError):
        pass


def _close_reason(exc: ConnectionClosed) -> str:
    """取对端关闭原因令牌; 没有原因时返回空串."""
    frame = getattr(exc, "rcvd", None)
    reason = getattr(frame, "reason", "") if frame is not None else ""
    return reason or ""


def _close_code(exc: ConnectionClosed) -> Optional[int]:
    frame = getattr(exc, "rcvd", None)
    code = getattr(frame, "code", None) if frame is not None else None
    return getattr(code, "value", code)


def _result(exit_code: int, stage: str, message: str, error_code: str, data: Dict[str, object]) -> BridgeResult:
    data = dict(data)
    data["stage"] = stage
    return BridgeResult(exit_code=exit_code, stage=stage, message=message, error_code=error_code, data=data)


def _closed_result(
    exc: ConnectionClosed,
    data: Dict[str, object],
    logger: JsonLogger,
    session_id: str,
) -> BridgeResult:
    """把桥接关闭原因令牌映射成退出码与阶段名; 不把任何负载写进结果."""
    code = _close_code(exc)
    reason = _close_reason(exc)
    data = dict(data)
    data["close_code"] = code
    data["close_reason"] = reason or None
    if reason == "ROUTE_CONFLICT":
        logger.log("ERROR", "bridge.register.rejected", "同一会话已有 runner 注册, 本连接被拒", session_id=session_id, close_code=code)
        return _result(1, STAGE_REGISTER_REJECTED, "注册被拒: 同一会话已有 runner", "ROUTE_CONFLICT", data)
    if reason == "ROUTE_GONE":
        logger.log("WARNING", "bridge.route.gone", "会话已结束, 反连被关闭", session_id=session_id, close_code=code)
        return _result(1, STAGE_BRIDGE, "会话已结束, 反连被关闭", "ROUTE_GONE", data)
    if reason == "UNKNOWN_SESSION":
        logger.log("WARNING", "bridge.route.unknown", "桥接不认识该会话标识", session_id=session_id, close_code=code)
        return _result(1, STAGE_BRIDGE, "桥接不认识该会话标识", "UNKNOWN_SESSION", data)
    logger.log("ERROR", "bridge.closed", "桥接连接被关闭", session_id=session_id, close_code=code, close_reason=reason or None)
    return _result(1, STAGE_BRIDGE, "桥接连接被关闭", "BRIDGE_CLOSED", data)


async def run_bridge(config: BridgeConfig, logger: JsonLogger) -> BridgeResult:
    """
    建立反连并驱动准入子进程, 返回结果而不直接退出进程.

    :return: exit_code 0 正常结束; 1 连不上或被拒; 2 运行期错误.
    """
    counters = Counters()
    base_data: Dict[str, object] = {
        "session_id": config.session_id,
        "bridge_host": urlsplit(config.bridge_url).netloc,
        "bytes_from_bridge": 0,
        "bytes_to_bridge": 0,
    }

    try:
        websocket = await websockets.connect(
            config.bridge_url,
            max_size=config.max_frame_bytes,
            ping_interval=config.ping_interval,
            ping_timeout=config.ping_timeout,
            open_timeout=config.connect_timeout,
            close_timeout=5.0,
        )
    except (InvalidURI, InvalidHandshake) as exc:
        logger.log_exception("ERROR", "bridge.connect.failed", "反连地址被拒绝或握手失败", exc, session_id=config.session_id)
        return _result(1, STAGE_CONNECT, "无法连接桥接服务: 地址非法或握手失败", "BRIDGE_CONNECT_FAILED", base_data)
    except ConnectionClosed as exc:
        return _closed_result(exc, base_data, logger, config.session_id)
    except (OSError, asyncio.TimeoutError) as exc:
        logger.log_exception("ERROR", "bridge.connect.failed", "反连桥接失败", exc, session_id=config.session_id)
        return _result(1, STAGE_CONNECT, "无法连接桥接服务: 网络不可达或超时", "BRIDGE_CONNECT_FAILED", base_data)

    logger.log(
        "INFO",
        "bridge.connected",
        "runner 反连已建立",
        session_id=config.session_id,
        bridge_host=base_data["bridge_host"],
    )

    try:
        child = subprocess.Popen(
            config.admission_argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            bufsize=0,
        )
    except (OSError, ValueError) as exc:
        logger.log_exception("ERROR", "admission.spawn.failed", "准入子进程启动失败", exc, argv0=config.admission_argv[0])
        await _silent_close(websocket, 1011, "ADMISSION_SPAWN_FAILED")
        return _result(2, STAGE_ADMISSION_START, "准入子进程启动失败", "ADMISSION_SPAWN_FAILED", base_data)

    logger.log("INFO", "admission.started", "准入子进程已启动", pid=child.pid, argv0=config.admission_argv[0])

    ws_task = asyncio.ensure_future(_pump_ws_to_child(websocket, child, counters))
    child_task = asyncio.ensure_future(_pump_child_to_ws(child, websocket, counters))
    result: Optional[BridgeResult] = None
    try:
        done, pending = await asyncio.wait(
            {ws_task, child_task},
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)

        ws_error: Optional[BaseException] = None
        if ws_task.done() and not ws_task.cancelled():
            ws_error = ws_task.exception()

        if child_task in done:
            returncode = child.poll()
            if returncode is None:
                returncode = await _terminate_child(child)
            data = dict(base_data)
            data.update(
                {
                    "bytes_from_bridge": counters.bytes_from_bridge,
                    "bytes_to_bridge": counters.bytes_to_bridge,
                    "admission_exit": returncode,
                }
            )
            if isinstance(ws_error, BridgeProtocolError):
                logger.log("ERROR", "bridge.protocol.rejected", "对端发送文本帧, 只接受二进制帧", session_id=config.session_id)
                await _silent_close(websocket, 1003, "PROTOCOL_TEXT_FRAME")
                result = _result(2, STAGE_BRIDGE, "桥接对端发送了协议外的帧类型", "PROTOCOL_TEXT_FRAME", data)
            elif ws_error is not None and not isinstance(ws_error, (ConnectionClosed, OSError)):
                logger.log_exception("ERROR", "bridge.runtime.failed", "桥接转发异常", ws_error, session_id=config.session_id)
                result = _result(2, STAGE_BRIDGE, "桥接转发异常, 数据面已中止", "BRIDGE_TRANSFER_FAILED", data)
            elif returncode == 0:
                logger.log("INFO", "bridge.finished", "准入子进程正常结束", session_id=config.session_id, admission_exit=0)
                result = _result(0, STAGE_ADMISSION_EXIT, "会话正常结束", "", data)
            else:
                logger.log(
                    "ERROR",
                    "admission.exited",
                    "准入子进程非零退出, 不降级",
                    session_id=config.session_id,
                    admission_exit=returncode,
                )
                result = _result(2, STAGE_ADMISSION_EXIT, "准入子进程异常退出", "ADMISSION_EXITED", data)
        else:
            data = dict(base_data)
            data.update(
                {
                    "bytes_from_bridge": counters.bytes_from_bridge,
                    "bytes_to_bridge": counters.bytes_to_bridge,
                }
            )
            if isinstance(ws_error, BridgeProtocolError):
                logger.log("ERROR", "bridge.protocol.rejected", "对端发送文本帧, 只接受二进制帧", session_id=config.session_id)
                await _silent_close(websocket, 1003, "PROTOCOL_TEXT_FRAME")
                result = _result(2, STAGE_BRIDGE, "桥接对端发送了协议外的帧类型", "PROTOCOL_TEXT_FRAME", data)
            elif isinstance(ws_error, ConnectionClosed):
                result = _closed_result(ws_error, data, logger, config.session_id)
            elif ws_error is not None:
                logger.log_exception("ERROR", "bridge.runtime.failed", "反连读循环异常", ws_error, session_id=config.session_id)
                result = _result(2, STAGE_BRIDGE, "反连读循环异常", "BRIDGE_TRANSFER_FAILED", data)
            else:
                logger.log("WARNING", "bridge.closed", "桥接连接已关闭", session_id=config.session_id)
                result = _result(1, STAGE_BRIDGE, "桥接连接已关闭", "BRIDGE_CLOSED", data)
    finally:
        for task in (ws_task, child_task):
            if not task.done():
                task.cancel()
        await asyncio.gather(ws_task, child_task, return_exceptions=True)
        if child.poll() is None:
            await _terminate_child(child)
        for stream in (child.stdin, child.stdout):
            try:
                stream.close()  # type: ignore[union-attr]
            except (OSError, ValueError):
                pass
        await _silent_close(websocket, 1000, "ADMISSION_DONE")
        logger.log(
            "INFO",
            "bridge.session.closed",
            "反连已收尾, 本次会话结束",
            session_id=config.session_id,
            bytes_from_bridge=counters.bytes_from_bridge,
            bytes_to_bridge=counters.bytes_to_bridge,
        )

    assert result is not None
    result.data["bytes_from_bridge"] = counters.bytes_from_bridge
    result.data["bytes_to_bridge"] = counters.bytes_to_bridge
    return result


def _emit(result: BridgeResult) -> None:
    """标准输出恰好一行五字段 JSON; 失败时 confirm 为空."""
    record = {
        "ok": result.exit_code == 0,
        "message": result.message,
        "error_code": result.error_code or None,
        "data": result.data,
        "confirm": CONFIRM_TEXT if result.exit_code == 0 else "",
    }
    sys.stdout.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="start_web_bridge",
        description="runner 侧网页桥接客户端: 主动反连中继桥接, 字节流转给 web_admission.py",
    )
    parser.add_argument("session_id", help="会话标识, 与 SSH 入口共用")
    parser.add_argument("bridge_ws_base", help="桥接基地址, 例如 wss://wuge.fun/runner")
    parser.add_argument("admission_cmd", help="准入进程命令行, 例如 'python3 scripts/web_admission.py --session-id s1 ...'")
    parser.add_argument("--connect-timeout", type=float, default=DEFAULT_CONNECT_TIMEOUT, help="反连超时秒数")
    parser.add_argument("--max-frame-bytes", type=int, default=DEFAULT_MAX_FRAME_BYTES, help="单帧上限字节数")
    parser.add_argument("--run-id", default=None, help="日志 run_id, 缺省取 GITHUB_RUN_ID 或时间戳")
    parser.add_argument("--log-level", choices=("DEBUG", "INFO", "WARNING", "ERROR"), default="INFO", help="日志级别")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    """
    进程入口; 所有失败路径都显式非零退出, 不静默降级.

    :return: 0 正常结束; 1 连不上或被拒; 2 参数或运行错误.
    """
    parser = _build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        if exc.code in (0, None):
            raise
        _emit(BridgeResult(2, STAGE_PRECHECK, "参数不完整或格式错误", "ARGUMENT_INVALID", {"stage": STAGE_PRECHECK}))
        return 2

    run_id = args.run_id or os.environ.get("GITHUB_RUN_ID") or f"pid{os.getpid()}"
    logger = JsonLogger(run_id, "scripts.start_web_bridge", args.log_level)

    if not _is_valid_session_id(args.session_id):
        logger.log("ERROR", "bridge.precheck.failed", "会话标识为空或含非法字符")
        _emit(
            BridgeResult(
                2,
                STAGE_PRECHECK,
                "会话标识非法: 只允许 8..128 位字母数字与 ._-",
                "SESSION_ID_INVALID",
                {"stage": STAGE_PRECHECK},
            )
        )
        return 2

    try:
        runner_url = _build_runner_url(args.session_id, args.bridge_ws_base)
    except ValueError as exc:
        logger.log("ERROR", "bridge.precheck.failed", "桥接基地址非法", reason=str(exc))
        _emit(
            BridgeResult(
                2,
                STAGE_PRECHECK,
                f"桥接基地址非法: {exc}",
                "BRIDGE_URL_INVALID",
                {"stage": STAGE_PRECHECK},
            )
        )
        return 2

    try:
        admission_argv = shlex.split(args.admission_cmd, posix=os.name != "nt")
    except ValueError as exc:
        logger.log("ERROR", "bridge.precheck.failed", "准入命令无法解析", reason=str(exc))
        _emit(
            BridgeResult(
                2,
                STAGE_PRECHECK,
                "准入命令无法解析: 引号不匹配",
                "ADMISSION_CMD_INVALID",
                {"stage": STAGE_PRECHECK},
            )
        )
        return 2
    if not admission_argv:
        logger.log("ERROR", "bridge.precheck.failed", "准入命令为空")
        _emit(
            BridgeResult(
                2,
                STAGE_PRECHECK,
                "准入命令为空",
                "ADMISSION_CMD_INVALID",
                {"stage": STAGE_PRECHECK},
            )
        )
        return 2

    config = BridgeConfig(
        session_id=args.session_id,
        bridge_url=runner_url,
        admission_argv=admission_argv,
        max_frame_bytes=args.max_frame_bytes,
        connect_timeout=args.connect_timeout,
        run_id=run_id,
    )
    try:
        result = asyncio.run(run_bridge(config, logger))
    except KeyboardInterrupt:
        _emit(BridgeResult(2, STAGE_BRIDGE, "被中断, 数据面已中止", "INTERRUPTED", {"stage": STAGE_BRIDGE}))
        return 2
    _emit(result)
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main())
