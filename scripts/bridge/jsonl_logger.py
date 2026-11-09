#!/usr/bin/env python3
"""
文件: jsonl_logger.py
所属目录: scripts/bridge/
文件用途: 桥接服务与 runner 侧桥接客户端共用的 JSON Lines 日志器; 只允许元数据字段, 不落盘, 不打印帧内容.
架构定位: 桥接进程内部基础设施; 上游是连接事件与字节计数, 下游是 journal 或 stderr.
核心功能: 按 10_日志 的基础字段输出单行 JSON; 提供异常三字段; 字段采用 snake_case; 不写文件.
职责边界: 不负责日志轮转与持久化; 不接受任意负载字段; 不感知业务帧协议.
运行环境: Python 3.8 及以上; 仅依赖标准库.
依赖关系: 无第三方依赖; 由 relay_bridge.py 与 start_web_bridge.py 共同引用.
"""

from __future__ import annotations

import json
import sys
import traceback
from datetime import datetime, timezone
from typing import Any, Dict, Optional, TextIO

_LEVEL_ORDER = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40}
MAX_TEXT = 500
MAX_STACK = 4000


class JsonLogger:
    """单行 JSON 日志器; 默认写 stderr, 由调用方显式指定输出流."""

    def __init__(
        self,
        run_id: str,
        logger_name: str,
        level: str = "INFO",
        stream: Optional[TextIO] = None,
    ) -> None:
        """
        :param run_id: 本次进程实例标识; 服务进程可用启动时间与 PID 组合.
        :param logger_name: 与代码目录一致的 logger 名称.
        :param level: DEBUG/INFO/WARNING/ERROR.
        :param stream: 日志输出流; 桥接服务用 stdout(journal), runner 客户端用 stderr.
        """
        self._run_id = run_id
        self._logger_name = logger_name
        self._threshold = _LEVEL_ORDER.get(level, 20)
        self._stream = stream if stream is not None else sys.stderr

    def log(self, level: str, event: str, msg: str, **fields: Any) -> None:
        """
        写一条日志.

        :param level: 日志级别, 非法值按 INFO 处理.
        :param event: 固定点分事件名, 不拼接变量.
        :param msg: 中文描述, 不得承载帧内容或凭据.
        :param fields: 白名单元数据字段, 值为 None 时省略.
        """
        if _LEVEL_ORDER.get(level, 20) < self._threshold:
            return
        record: Dict[str, Any] = {
            "ts": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "level": level,
            "logger": self._logger_name,
            "event": event,
            "msg": msg,
            "run_id": self._run_id,
        }
        for key, value in fields.items():
            if value is not None:
                record[key] = value
        try:
            self._stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            self._stream.flush()
        except (OSError, ValueError) as exc:
            # 日志通道坏了也不能拖垮数据面; 只向 stderr 提示一次, 不重试覆盖主流程
            print(f"日志写入失败: reason={exc}", file=sys.stderr, flush=True)

    def log_exception(self, level: str, event: str, msg: str, exc: BaseException, **fields: Any) -> None:
        """记录异常; 附带 exc_type/exc_msg/stack 三字段, 栈在单行 JSON 内转义."""
        self.log(
            level,
            event,
            msg,
            exc_type=type(exc).__name__,
            exc_msg=str(exc)[:MAX_TEXT],
            stack="".join(traceback.format_exception(type(exc), exc, exc.__traceback__))[:MAX_STACK],
            **fields,
        )
