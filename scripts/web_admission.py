#!/usr/bin/env python3
"""
文件: web_admission.py
所属目录: scripts/
文件用途: runner 侧网页准入进程; 在中继转发的字节流上完成 WebAuthn 挑战与断言验签, 通过后把字节流交给指定 tmux 会话.
架构定位: 脚本层进程, 上游是中继转发过来的双向字节流, 下游是本机 tmux 会话; 不反向调用入口层, 不修改中继行为.
核心功能: 帧重组; 一次性挑战(绑定 session_id 与有效期); authBegin/authChallenge/authAssertion/authResult 与注册链路;
          断言验签(origin/rpId/challenge/签名/凭据公钥); 准入前丢弃终端输入; 准入后桥接 tmux.
职责边界: 不持有私钥, 不落盘凭据, 不打印断言原文与公钥以外的密钥材料, 不做中继侧路由判定, 不做浏览器打洞.
运行环境: Python 3.10 以上, 依赖 fido2(验签与 COSE 公钥解析), 仅在 runner(POSIX) 上桥接 tmux; 核心状态机可在任意平台测试.
依赖关系: 依赖 fido2; 需求来源 .team/specs/项目设计书-20261109-v3.md 第 3.6/3.7 节与 web/README.md 第 6 节服务端对接清单.

运行形态:
  由中继桥接适配器以子进程方式拉起; stdin 承载浏览器方向字节流, stdout 承载返回浏览器的字节流,
  诊断日志按 10_日志 规范以 JSON Lines 写入 stderr(或 --log-dir 指定的 logs/<run_id>.jsonl).

命令行示例:
  python scripts/web_admission.py \\
      --session-id <session_id> \\
      --allowed-credentials /run/actssh/webauthn-allowed.json \\
      --tmux-session actssh

允许清单文件只允许公钥与凭据标识, 格式为 JSON 数组:
  [{"credential_id": "<base64url>", "public_key": "<base64url CBOR COSE 公钥>", "transports": ["internal"]}]
"""

from __future__ import annotations

import argparse
import base64
import binascii
import errno
import hashlib
import hmac
import json
import os
import re
import secrets
import selectors
import signal
import struct
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from typing import Any, Callable, Mapping, NamedTuple, Sequence, Union

# =========** 常量 =========**
# 帧格式与 web/src/protocol/frames.ts 保持一致, 不改动前端契约.
FRAME_MAGIC = 0xA1
FRAME_PROTOCOL_VERSION = 0x01
FRAME_HEADER_BYTES = 8
FRAME_MAX_PAYLOAD_BYTES = 1024 * 1024

FRAME_TERMINAL_DATA = 0x01
FRAME_RESIZE = 0x02
FRAME_AUTH_BEGIN = 0x10
FRAME_AUTH_CHALLENGE = 0x11
FRAME_AUTH_ASSERTION = 0x12
FRAME_AUTH_RESULT = 0x13
FRAME_REGISTRATION_OPTIONS = 0x14
FRAME_REGISTRATION = 0x15

# 只接受浏览器方向的两类数据帧与四类准入帧; 服务端方向帧若由浏览器发来视为方向错误.
_BROWSER_FRAME_TYPES = frozenset(
    {
        FRAME_TERMINAL_DATA,
        FRAME_RESIZE,
        FRAME_AUTH_BEGIN,
        FRAME_AUTH_ASSERTION,
        FRAME_REGISTRATION,
    }
)

DEFAULT_RP_ID = "wuge.fun"
DEFAULT_RP_NAME = "ActionSSHConnection"
CLIENT_VERSION = "0.1.0"
DEFAULT_CHALLENGE_TTL_SECONDS = 60.0
DEFAULT_AUTH_TIMEOUT_SECONDS = 120.0
DEFAULT_MAX_ATTEMPTS = 3
MIN_TIMEOUT_MS = 10_000
MAX_TIMEOUT_MS = 300_000
ALLOWED_COSE_ALGORITHMS = frozenset({-7, -257})  # ES256 与 RS256
LOGGER_NAME = "scripts.web_admission"
SESSION_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
BASE64URL_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")
MAX_LOG_TEXT = 500
MAX_STACK_TEXT = 4000

# 用户可见原因码; 前五个与 web/README.md 6.4 已映射的集合一致, 其余按原文展示且不含敏感信息.
REASON_ASSERTION_INVALID = "ASSERTION_INVALID"
REASON_CREDENTIAL_NOT_ALLOWED = "CREDENTIAL_NOT_ALLOWED"
REASON_CHALLENGE_EXPIRED = "CHALLENGE_EXPIRED"
REASON_CHALLENGE_REUSED = "CHALLENGE_REUSED"
REASON_BAD_CLIENT_VERSION = "BAD_CLIENT_VERSION"
REASON_REGISTRATION_CLOSED = "REGISTRATION_CLOSED"
REASON_REGISTRATION_INVALID = "REGISTRATION_INVALID"
REASON_TERMINAL_UNAVAILABLE = "TERMINAL_UNAVAILABLE"
REASON_AUTH_TIMEOUT = "AUTH_TIMEOUT"
REASON_PROTOCOL_ERROR = "PROTOCOL_ERROR"


# =========** 异常 =========**
class AdmissionError(Exception):
    """准入相关异常的基类; 子类用 reason 携带面向界面的原因码, 消息不得包含凭据."""


class ProtocolError(AdmissionError):
    """帧或控制负载不符合协议; 属于出错分支, 需要关闭连接."""


class FrameError(ProtocolError):
    """帧头或帧长度非法."""


class ConfigError(Exception):
    """启动配置不可用; 属于出错分支, 进程以退出码 2 结束."""


class TerminalError(Exception):
    """终端桥接不可用; 属于出错分支, 保留原始异常链后上抛."""


class AdmissionRejection(AdmissionError):
    """断言或注册材料被拒绝; reason 为原因码, detail 为可展示的中文说明."""

    def __init__(self, reason: str, detail: str) -> None:
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


# =========** 帧编解码 =========**
@dataclass(frozen=True)
class Frame:
    """一个完整帧; payload 不含 8 字节帧头."""

    type: int
    payload: bytes


def encode_frame(frame_type: int, payload: bytes) -> bytes:
    """
    编码一帧.

    :param frame_type: 帧类型编号, 必须是已知类型.
    :param payload: 负载字节, 不得超过 1 MiB.
    :return: 含帧头的完整字节串.
    :raises ValueError: 帧类型未知或负载超长, 属于调用方编程错误.
    """
    if frame_type not in {
        FRAME_TERMINAL_DATA,
        FRAME_RESIZE,
        FRAME_AUTH_BEGIN,
        FRAME_AUTH_CHALLENGE,
        FRAME_AUTH_ASSERTION,
        FRAME_AUTH_RESULT,
        FRAME_REGISTRATION_OPTIONS,
        FRAME_REGISTRATION,
    }:
        raise ValueError(f"未知帧类型 0x{frame_type:02x}")
    if len(payload) > FRAME_MAX_PAYLOAD_BYTES:
        raise ValueError(f"帧负载 {len(payload)} 字节超过上限 {FRAME_MAX_PAYLOAD_BYTES} 字节")
    return struct.pack(">BBBBI", FRAME_MAGIC, FRAME_PROTOCOL_VERSION, frame_type, 0, len(payload)) + payload


class FrameDecoder:
    """
    按「魔数 + 版本 + 类型 + 长度」从任意切分的字节流重组完整帧.

    中继允许合并或拆分帧边界, 这里保留残余字节, 直到凑满一帧再交付.
    """

    def __init__(self) -> None:
        self._buffer = bytearray()

    def feed(self, chunk: bytes) -> list[Frame]:
        """
        追加一段字节并取出其中所有完整帧.

        :param chunk: 新到达的字节, 可能只包含半个帧头或半个负载.
        :return: 本次可交付的完整帧, 按到达顺序排列.
        :raises FrameError: 魔数/版本/类型/保留位/长度任一不符时抛出.
        """
        self._buffer.extend(chunk)
        frames: list[Frame] = []
        while len(self._buffer) >= FRAME_HEADER_BYTES:
            magic, version, frame_type, reserved, length = struct.unpack(">BBBBI", self._buffer[:FRAME_HEADER_BYTES])
            if magic != FRAME_MAGIC:
                raise FrameError("帧魔数不匹配")
            if version != FRAME_PROTOCOL_VERSION:
                raise FrameError(f"帧版本 {version} 不受支持")
            if frame_type not in _BROWSER_FRAME_TYPES:
                raise FrameError(f"帧类型 0x{frame_type:02x} 不允许由浏览器发送")
            if reserved != 0:
                raise FrameError("帧保留位非 0")
            if length > FRAME_MAX_PAYLOAD_BYTES:
                raise FrameError(f"帧负载声明 {length} 字节超过上限")
            if len(self._buffer) < FRAME_HEADER_BYTES + length:
                break
            body_start = FRAME_HEADER_BYTES
            body_end = body_start + length
            frames.append(Frame(frame_type, bytes(self._buffer[body_start:body_end])))
            del self._buffer[:body_end]
        return frames


# =========** base64url 与 JSON 工具 =========**
def b64url_encode(data: bytes) -> str:
    """把字节编码为不带填充的 base64url; 只用于公钥侧材料与挑战展示."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text: Any) -> bytes:
    """
    严格解码 base64url; 拒绝空串、填充符与非法字符.

    :param text: 待解码值, 来源不可信.
    :return: 解码后的字节.
    :raises ValueError: 不是字符串、为空或含非法字符时抛出.
    """
    if not isinstance(text, str) or not BASE64URL_PATTERN.fullmatch(text):
        raise ValueError("不是合法的 base64url 字符串")
    padding = "=" * (-len(text) % 4)
    try:
        return base64.urlsafe_b64decode(text + padding)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("base64url 解码失败") from exc


def _parse_json_object(payload: bytes) -> dict[str, Any]:
    """
    把控制帧负载解析为 JSON 对象.

    :param payload: 帧负载, 来源不可信.
    :return: 键值对对象, 值仍为 unknown, 由调用方逐字段校验.
    :raises AdmissionRejection: 非 UTF-8、非 JSON 或顶层不是对象时抛出.
    """
    try:
        decoded = payload.decode("utf-8")
        parsed = json.loads(decoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AdmissionRejection(REASON_ASSERTION_INVALID, "控制帧不是合法 UTF-8 JSON") from exc
    if not isinstance(parsed, dict):
        raise AdmissionRejection(REASON_ASSERTION_INVALID, "控制帧顶层必须是 JSON 对象")
    return parsed


def _require_string(source: Mapping[str, Any], field_name: str) -> str:
    """
    读取必填字符串字段.

    :raises AdmissionRejection: 字段缺失或不是字符串时抛出.
    """
    value = source.get(field_name)
    if not isinstance(value, str):
        raise AdmissionRejection(REASON_ASSERTION_INVALID, f"断言字段 {field_name} 必须是字符串")
    return value


def _read_positive_int(source: Mapping[str, Any], field_name: str) -> int:
    """读取正整数; 非正整数视为负载非法, 返回 0 由调用方丢弃该帧."""
    value = source.get(field_name)
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return 0
    return value


# =========** fido2 延迟加载 =========**
class _Fido2Api(NamedTuple):
    """fido2 的四个入口; 延迟导入让 --help 与纯配置错误不依赖运行库."""

    cbor: Any
    cose_key: Any
    attestation_object: Any
    authenticator_data: Any
    collected_client_data: Any


@lru_cache(maxsize=1)
def _fido2_api() -> _Fido2Api:
    """
    导入 fido2; 缺失时给出可执行的安装指引.

    :raises ConfigError: 未安装 fido2 时抛出, 携带原始 ImportError 原因.
    """
    try:
        from fido2 import cbor as fido2_cbor
        from fido2.cose import CoseKey as fido2_cose_key
        from fido2.webauthn import AttestationObject as fido2_attestation_object
        from fido2.webauthn import AuthenticatorData as fido2_authenticator_data
        from fido2.webauthn import CollectedClientData as fido2_collected_client_data
    except ImportError as exc:
        raise ConfigError("缺少依赖 fido2, 请按 scripts/requirements-web-admission.txt 安装") from exc
    return _Fido2Api(
        cbor=fido2_cbor,
        cose_key=fido2_cose_key,
        attestation_object=fido2_attestation_object,
        authenticator_data=fido2_authenticator_data,
        collected_client_data=fido2_collected_client_data,
    )


# =========** 允许清单 =========**
@dataclass(frozen=True)
class AllowedCredential:
    """一条允许清单记录; 只保存凭据标识与公钥, 不含任何私钥材料."""

    credential_id: bytes
    public_key: Any  # fido2 CoseKey(dict 子类), 由 P-256/RSA 公钥参数构成
    transports: tuple[str, ...] = ()


def _parse_cose_public_key(cose_bytes: bytes) -> Any:
    """
    解析 CBOR 编码的 COSE 公钥.

    :raises ValueError: CBOR 或 COSE 结构非法时抛出, 但保留原始异常链.
    """
    api = _fido2_api()
    try:
        decoded = api.cbor.decode(cose_bytes)
        return api.cose_key.parse(decoded)
    except Exception as exc:  # crypto 库异常类型不稳定, 统一转为配置/断言层可判定的 ValueError
        raise ValueError("COSE 公钥无法解析") from exc


def load_allowed_credentials(path: str) -> dict[bytes, AllowedCredential]:
    """
    读取允许清单文件; 文件只允许公钥与凭据标识.

    :param path: 允许清单路径, 由 runner 侧在作业内生成, 随作业销毁.
    :return: 以凭据标识为键的允许清单.
    :raises ConfigError: 文件不可读、JSON 非法、为空、条目非法或凭据重复时抛出.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except OSError as exc:
        raise ConfigError(f"读取允许清单失败: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"允许清单不是合法 JSON: {path}") from exc
    if not isinstance(raw, list):
        raise ConfigError("允许清单顶层必须是数组")
    if not raw:
        raise ConfigError("允许清单为空, 无法受理任何凭据")

    credentials: dict[bytes, AllowedCredential] = {}
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise ConfigError(f"允许清单第 {index} 项不是对象")
        credential_id_text = item.get("credential_id")
        public_key_text = item.get("public_key")
        if not isinstance(credential_id_text, str) or not isinstance(public_key_text, str):
            raise ConfigError(f"允许清单第 {index} 项缺少 credential_id 或 public_key")
        transports = item.get("transports", [])
        if not isinstance(transports, list) or any(not isinstance(entry, str) for entry in transports):
            raise ConfigError(f"允许清单第 {index} 项 transports 必须是字符串数组")
        try:
            credential_id = b64url_decode(credential_id_text)
            public_key = _parse_cose_public_key(b64url_decode(public_key_text))
        except ValueError as exc:
            raise ConfigError(f"允许清单第 {index} 项编码或公钥无法解析") from exc
        if public_key.get(3) not in ALLOWED_COSE_ALGORITHMS:
            raise ConfigError(f"允许清单第 {index} 项公钥算法不受支持")
        if credential_id in credentials:
            raise ConfigError("允许清单存在重复凭据标识")
        credentials[credential_id] = AllowedCredential(credential_id, public_key, tuple(transports))
    return credentials


# =========** 日志 =========**
_LEVEL_ORDER = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40}


class JsonLogger:
    """
    JSON Lines 日志; 一行一个对象, 字段按 10_日志 基础字段加准入专用白名单.

    白名单字段: session_id, credential_id(公钥凭据标识, 属可公开项), reason, stage, attempt, duration_ms.
    断言原文、签名、挑战、公钥字节与私钥材料一律不进入日志.
    """

    def __init__(self, run_id: str, level: str = "INFO", log_file: str | None = None) -> None:
        self._run_id = run_id
        self._threshold = _LEVEL_ORDER.get(level, 20)
        self._handle: Any = None
        self._log_path: str | None = None
        self._warned = False
        if log_file is not None:
            self._open_file(log_file)

    def _open_file(self, path: str) -> None:
        """打开日志文件; 失败时只提示一次并继续用 stderr, 不影响主流程."""
        try:
            directory = os.path.dirname(path)
            if directory:
                os.makedirs(directory, exist_ok=True)
            self._handle = open(path, "a", encoding="utf-8", newline="\n")
            self._log_path = path
        except OSError as exc:
            self._warn_once(f"日志文件不可写: path={path} reason={exc}")

    def _warn_once(self, message: str) -> None:
        """日志降级提示; 每次运行最多输出一条, 避免刷屏."""
        if self._warned:
            return
        self._warned = True
        print(message, file=sys.stderr, flush=True)

    def log(self, level: str, event: str, msg: str, **fields: Any) -> None:
        """
        写一条日志.

        :param level: DEBUG/INFO/WARNING/ERROR.
        :param event: 固定点分事件名, 不得拼接变量.
        :param msg: 人类可读描述, 不得承载结构化数据与敏感内容.
        :param fields: 白名单上下文字段, 值为 None 时省略该字段.
        """
        if _LEVEL_ORDER.get(level, 20) < self._threshold:
            return
        record: dict[str, Any] = {
            "ts": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "level": level,
            "logger": LOGGER_NAME,
            "event": event,
            "msg": msg,
            "run_id": self._run_id,
        }
        for key, value in fields.items():
            if value is not None:
                record[key] = value
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        if self._handle is None:
            print(line, file=sys.stderr, flush=True)
            return
        try:
            self._handle.write(line + "\n")
            self._handle.flush()
        except OSError as exc:
            self._warn_once(f"日志写入失败: path={self._log_path} reason={exc}")

    def log_exception(self, level: str, event: str, msg: str, exc: BaseException, **fields: Any) -> None:
        """
        记录异常; 使用 exc_type/exc_msg/stack 三字段, 栈在 JSON 内保持单行.

        栈文本只包含文件、行号、函数与异常类型/消息, 不含帧负载; 超长时截断.
        """
        self.log(
            level,
            event,
            msg,
            exc_type=type(exc).__name__,
            exc_msg=str(exc)[:MAX_LOG_TEXT],
            stack="".join(traceback.format_exception(type(exc), exc, exc.__traceback__))[:MAX_STACK_TEXT],
            **fields,
        )

    def close(self) -> None:
        """关闭日志文件句柄; 重复调用安全."""
        if self._handle is not None:
            try:
                self._handle.close()
            except OSError as exc:
                self._warn_once(f"日志文件关闭失败: path={self._log_path} reason={exc}")
            self._handle = None


# =========** 准入动作 =========**
@dataclass(frozen=True)
class SendFrame:
    """向浏览器发送一帧."""

    frame_type: int
    payload: bytes


@dataclass(frozen=True)
class WriteTerminal:
    """把浏览器字节写入终端会话."""

    data: bytes


@dataclass(frozen=True)
class ResizeTerminal:
    """调整终端行列数."""

    cols: int
    rows: int


@dataclass(frozen=True)
class CloseConnection:
    """关闭本次网页入向连接; reason 为可展示的关闭原因."""

    reason: str


Action = Union[SendFrame, WriteTerminal, ResizeTerminal, CloseConnection]


def _auth_result(ok: bool, reason: str) -> SendFrame:
    """构造 authResult 帧; verifier 固定为 runner, 与前端区分模拟器."""
    body = json.dumps({"ok": ok, "verifier": "runner", "reason": reason}, ensure_ascii=False, separators=(",", ":"))
    return SendFrame(FRAME_AUTH_RESULT, body.encode("utf-8"))


# =========** 待处理挑战 =========**
@dataclass
class _PendingChallenge:
    """一次待消费的挑战; value 一次性, session_id 绑定, expires_at 为单调时钟秒."""

    value: bytes
    session_id: str
    intent: str
    expires_at: float
    issued_at: float


# =========** WebAuthn 验签 =========**
class WebAuthnVerifier:
    """
    断言与注册材料的验签器.

    显式校验项: clientData 类型、挑战、origin、crossOrigin、rpIdHash、用户在场标志、凭据白名单、
    COSE 公钥算法与签名. 签名运算交给 fido2(成熟库), 本类不与第三方异常类型耦合.
    """

    def __init__(
        self,
        rp_id: str,
        credentials: Mapping[bytes, AllowedCredential],
        user_verification: str = "preferred",
    ) -> None:
        self._rp_id = rp_id
        self._rp_id_hash = hashlib.sha256(rp_id.encode("utf-8")).digest()
        self._credentials = dict(credentials)
        self._user_verification = user_verification
        # 触发一次导入, 让缺少依赖在启动阶段暴露, 而不是等第一条断言
        _fido2_api()

    @property
    def credentials(self) -> dict[bytes, AllowedCredential]:
        """当前允许的凭据集合; 注册成功后由会话写入."""
        return self._credentials

    def allowed_credential_ids(self) -> list[str]:
        """返回允许清单中的凭据标识(base64url), 用于下发 allowCredentialIds."""
        return [b64url_encode(credential_id) for credential_id in self._credentials]

    def _verify_client_data(self, client_data: Any, expected_type: str, expected_challenge: bytes) -> None:
        """校验 clientDataJSON 的类型、挑战与 origin; 任一不符即拒绝."""
        if client_data.type != expected_type:
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "clientData.type 与操作类型不符")
        if not hmac.compare_digest(client_data.challenge, expected_challenge):
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "挑战与本次会话下发值不符")
        if bool(client_data.cross_origin):
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "不接受跨源准入")
        self._verify_origin(client_data.origin)

    def _verify_origin(self, origin: Any) -> None:
        """origin 必须是 https 且主机等于 rpId 或 rpId 的子域."""
        if not isinstance(origin, str) or origin == "":
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "clientData.origin 缺失")
        scheme, separator, remainder = origin.partition("://")
        if separator == "" or scheme.lower() != "https":
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "origin 必须使用 https")
        host = remainder.split("/", 1)[0]
        path = remainder[len(host):]
        if path not in ("", "/"):
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "origin 不得包含路径或参数")
        # 去掉端口后再比对主机; 只有默认端口可不写, 显式 443 也接受
        if ":" in host:
            host, _, port = host.partition(":")
            if port != "443":
                raise AdmissionRejection(REASON_ASSERTION_INVALID, "origin 端口必须是 443")
        host = host.lower()
        rp_id = self._rp_id.lower()
        if host != rp_id and not host.endswith("." + rp_id):
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "origin 与 rpId 不匹配")

    def _parse_authenticator_data(self, raw: bytes) -> Any:
        """解析 authenticatorData; 长度或结构非法即拒绝."""
        api = _fido2_api()
        try:
            return api.authenticator_data(raw)
        except (ValueError, TypeError) as exc:
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "authenticatorData 无法解析") from exc

    def verify_assertion(self, fields: Mapping[str, Any], expected_challenge: bytes) -> AllowedCredential:
        """
        校验一条断言.

        :param fields: authAssertion 负载对象, 值来源不可信.
        :param expected_challenge: 本次下发且已消费的挑战原文.
        :return: 命中的允许清单记录.
        :raises AdmissionRejection: 任一校验项不符时抛出, 原因码见 README 6.4.
        """
        api = _fido2_api()
        try:
            credential_id = b64url_decode(_require_string(fields, "credentialId"))
            client_data_raw = b64url_decode(_require_string(fields, "clientDataJSON"))
            authenticator_data_raw = b64url_decode(_require_string(fields, "authenticatorData"))
            signature = b64url_decode(_require_string(fields, "signature"))
        except ValueError as exc:
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "断言字段不是合法 base64url") from exc

        credential = self._credentials.get(credential_id)
        if credential is None:
            raise AdmissionRejection(REASON_CREDENTIAL_NOT_ALLOWED, "凭据不在允许清单内")

        try:
            client_data = api.collected_client_data(client_data_raw)
        except (ValueError, TypeError, KeyError) as exc:
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "clientDataJSON 无法解析") from exc
        self._verify_client_data(client_data, "webauthn.get", expected_challenge)

        authenticator_data = self._parse_authenticator_data(authenticator_data_raw)
        if not hmac.compare_digest(authenticator_data.rp_id_hash, self._rp_id_hash):
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "rpIdHash 与 wuge.fun 不符")
        if not authenticator_data.is_user_present():
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "缺少用户在场标志")
        if self._user_verification == "required" and not authenticator_data.is_user_verified():
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "缺少用户验证标志")

        signed_payload = authenticator_data_raw + hashlib.sha256(client_data_raw).digest()
        try:
            credential.public_key.verify(signed_payload, signature)
        except Exception as exc:  # crypto 库异常类型不稳定, 统一转为断言无效并保留原因链
            raise AdmissionRejection(REASON_ASSERTION_INVALID, "签名校验未通过") from exc
        return credential

    def verify_registration(self, fields: Mapping[str, Any], expected_challenge: bytes) -> AllowedCredential:
        """
        校验注册材料并提取公钥; 只接受公钥侧材料, 不保存证明链.

        注册本身是否开放由会话的注册开关决定, 且注册通道必须已受信; 这里不校验厂商证明链,
        因为信任来源是受信通道而不是认证器厂商, 证明链也无法据此提升本项目的准入强度.

        :param fields: registration 负载对象, 值来源不可信.
        :param expected_challenge: 本次下发的注册挑战原文.
        :return: 新登记的允许清单记录.
        :raises AdmissionRejection: 任一校验项不符时抛出.
        """
        api = _fido2_api()
        try:
            credential_id = b64url_decode(_require_string(fields, "credentialId"))
            client_data_raw = b64url_decode(_require_string(fields, "clientDataJSON"))
            attestation_raw = b64url_decode(_require_string(fields, "attestationObject"))
        except ValueError as exc:
            raise AdmissionRejection(REASON_REGISTRATION_INVALID, "注册字段不是合法 base64url") from exc

        try:
            client_data = api.collected_client_data(client_data_raw)
        except (ValueError, TypeError, KeyError) as exc:
            raise AdmissionRejection(REASON_REGISTRATION_INVALID, "clientDataJSON 无法解析") from exc
        self._verify_client_data(client_data, "webauthn.create", expected_challenge)

        try:
            attestation = api.attestation_object(attestation_raw)
        except (ValueError, TypeError, KeyError) as exc:
            raise AdmissionRejection(REASON_REGISTRATION_INVALID, "attestationObject 无法解析") from exc
        authenticator_data = attestation.auth_data
        if not hmac.compare_digest(authenticator_data.rp_id_hash, self._rp_id_hash):
            raise AdmissionRejection(REASON_REGISTRATION_INVALID, "rpIdHash 与 wuge.fun 不符")
        if not authenticator_data.is_user_present():
            raise AdmissionRejection(REASON_REGISTRATION_INVALID, "缺少用户在场标志")
        credential_data = authenticator_data.credential_data
        if credential_data is None:
            raise AdmissionRejection(REASON_REGISTRATION_INVALID, "注册材料缺少凭据公钥")
        if not hmac.compare_digest(credential_data.credential_id, credential_id):
            raise AdmissionRejection(REASON_REGISTRATION_INVALID, "凭据标识与认证器返回不一致")
        public_key = credential_data.public_key
        if public_key.get(3) not in ALLOWED_COSE_ALGORITHMS:
            raise AdmissionRejection(REASON_REGISTRATION_INVALID, "公钥算法不受支持")

        transports_value = fields.get("transports", [])
        transports: tuple[str, ...] = ()
        if isinstance(transports_value, list) and all(isinstance(entry, str) for entry in transports_value):
            transports = tuple(transports_value)
        return AllowedCredential(credential_id, public_key, transports)


# =========** 终端桥接 =========**
class TmuxTerminal:
    """
    通过 PTY 接入本机 tmux 会话; 只在 POSIX 且 tmux 可用时构造.

    说明: tmux 会话由工作流预先创建(见 .github/workflows/session.yml 的 actssh).
    接入的是同一终端进程, 与 SSH 通道共享会话路由; 客户端退出只 detach, 不销毁 tmux 会话.
    """

    def __init__(
        self,
        session_name: str,
        logger: JsonLogger,
        initial_cols: int = 80,
        initial_rows: int = 24,
    ) -> None:
        # PTY 与终端 ioctl 只在 POSIX 可用; 延迟导入让状态机可在 Windows 上自测
        import fcntl  # noqa: PLC0415 - 平台相关模块, 只在构造真实终端时导入
        import pty  # noqa: PLC0415
        import termios  # noqa: PLC0415

        if os.name != "posix":
            raise TerminalError("当前平台不支持 PTY, 无法桥接 tmux")
        self._logger = logger
        self._fcntl = fcntl
        self._termios = termios
        self._closed = False

        try:
            probe = subprocess.run(
                ["tmux", "has-session", "-t", session_name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=5,
            )
        except FileNotFoundError as exc:
            raise TerminalError("tmux 可执行文件不可用") from exc
        except subprocess.TimeoutExpired as exc:
            raise TerminalError("检查 tmux 会话超时") from exc
        if probe.returncode != 0:
            raise TerminalError(f"目标 tmux 会话不存在: {session_name}")

        master_fd, slave_fd = pty.openpty()
        # runner 上的 TERM 可能为空, 固定为 xterm-256color 以便 tmux 客户端正常工作
        environment = dict(os.environ)
        environment.setdefault("TERM", "xterm-256color")
        try:
            process = subprocess.Popen(
                ["tmux", "attach-session", "-t", session_name],
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
                start_new_session=True,
                env=environment,
            )
        except OSError as exc:
            os.close(master_fd)
            os.close(slave_fd)
            raise TerminalError("启动 tmux 客户端失败") from exc
        os.close(slave_fd)
        self._master_fd = master_fd
        self._process = process
        self.resize(initial_cols, initial_rows)

    def fileno(self) -> int:
        """返回可被选择器监听的 PTY 主端文件描述符."""
        return self._master_fd

    def write(self, data: bytes) -> None:
        """
        写入终端.

        :raises TerminalError: 终端已关闭或写入失败时抛出, 由调用方转为连接关闭.
        """
        if self._closed:
            raise TerminalError("终端已关闭")
        try:
            os.write(self._master_fd, data)
        except OSError as exc:
            raise TerminalError("写入终端失败") from exc

    def resize(self, cols: int, rows: int) -> None:
        """
        调整终端行列数并通知 tmux 客户端.

        :raises TerminalError: ioctl 失败时抛出, 属于可降级项, 由调用方记 WARNING 后继续.
        """
        if self._closed:
            raise TerminalError("终端已关闭")
        packed = struct.pack("HHHH", rows, cols, 0, 0)
        try:
            self._fcntl.ioctl(self._master_fd, self._termios.TIOCSWINSZ, packed)
            os.kill(self._process.pid, signal.SIGWINCH)
        except OSError as exc:
            raise TerminalError("调整终端尺寸失败") from exc

    def read_available(self) -> bytes:
        """
        读取终端输出; 无数据返回空字节, 终端关闭返回空字节并置关闭标志.

        :raises TerminalError: 非 EOF 的读取失败时抛出.
        """
        if self._closed:
            return b""
        try:
            return os.read(self._master_fd, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                # PTY 对端退出时 Linux 返回 EIO, 属正常结束分支
                self._closed = True
                return b""
            raise TerminalError("读取终端失败") from exc

    def close(self) -> None:
        """关闭 PTY 并结束 tmux 客户端; 重复调用安全, 不抛出异常."""
        if self._closed:
            return
        self._closed = True
        try:
            os.close(self._master_fd)
        except OSError as exc:
            # 句柄可能已被内核回收, 记账后继续做进程收尾
            self._logger.log("WARNING", "admission.terminal.close_failed", "关闭终端句柄失败", reason=str(exc)[:MAX_LOG_TEXT])
        if self._process.poll() is None:
            try:
                self._process.terminate()
                self._process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(timeout=2)
            except OSError as exc:
                self._logger.log("WARNING", "admission.terminal.close_failed", "结束 tmux 客户端失败", reason=str(exc)[:MAX_LOG_TEXT])

    @property
    def is_closed(self) -> bool:
        """终端是否已关闭或客户端已退出."""
        if self._closed:
            return True
        return self._process.poll() is not None


# =========** 准入状态机 =========**
@dataclass
class SessionOptions:
    """会话构造参数; 集中放在一个对象里, 避免构造参数散落."""

    session_id: str
    rp_id: str = DEFAULT_RP_ID
    rp_name: str = DEFAULT_RP_NAME
    allow_registration: bool = False
    challenge_ttl_seconds: float = DEFAULT_CHALLENGE_TTL_SECONDS
    auth_timeout_seconds: float = DEFAULT_AUTH_TIMEOUT_SECONDS
    max_attempts: int = DEFAULT_MAX_ATTEMPTS
    user_verification: str = "preferred"


class AdmissionSession:
    """
    单个网页连接上的准入状态机.

    状态: awaiting(未准入) -> admitted(已准入); 任一路径关闭后进入 closed, 之后不再接受任何帧.
    方法 handle/tick 只返回动作, 不直接读写流或终端, 便于自测与替换传输层.
    """

    def __init__(
        self,
        options: SessionOptions,
        verifier: WebAuthnVerifier,
        logger: JsonLogger,
        terminal_factory: Callable[[], Any],
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if not SESSION_ID_PATTERN.fullmatch(options.session_id):
            raise ConfigError("session_id 只允许字母、数字、下划线、连字符, 长度 1 到 128")
        self._options = options
        self._verifier = verifier
        self._logger = logger
        self._terminal_factory = terminal_factory
        self._clock = clock
        self._state = "awaiting"
        self._closed = False
        self._pending: _PendingChallenge | None = None
        self._consumed: dict[str, float] = {}
        self._failed_attempts = 0
        self._terminal: Any = None
        self._started_at = clock()

    # ---------- 只读属性 ----------
    @property
    def session_id(self) -> str:
        """本次会话标识; 挑战绑定该值."""
        return self._options.session_id

    @property
    def closed(self) -> bool:
        """连接是否已关闭."""
        return self._closed

    @property
    def authenticated(self) -> bool:
        """是否已通过准入."""
        return self._state == "admitted"

    @property
    def terminal(self) -> Any:
        """已打开的终端对象; 未准入时为 None."""
        return self._terminal

    # ---------- 帧入口 ----------
    def handle(self, frame: Frame, now: float | None = None) -> tuple[Action, ...]:
        """
        处理一个浏览器方向的帧.

        :param frame: 已重组的帧.
        :param now: 注入的单调时钟秒, 自测用; 缺省取构造时的 clock.
        :return: 需要执行的动作, 可能为空元组.
        """
        if self._closed:
            return ()
        current = self._clock() if now is None else now

        if frame.type == FRAME_TERMINAL_DATA:
            return self._handle_terminal_data(frame.payload)
        if frame.type == FRAME_RESIZE:
            return self._handle_resize(frame.payload)
        if self._state == "admitted":
            # 已准入后再次发起准入没有意义, 也不得重新签发挑战
            self._logger.log(
                "WARNING",
                "admission.frame.rejected",
                "已准入连接收到重复准入帧",
                session_id=self.session_id,
                stage="post-auth",
            )
            return ()
        if frame.type == FRAME_AUTH_BEGIN:
            return self._handle_auth_begin(frame.payload, current)
        if frame.type == FRAME_AUTH_ASSERTION:
            return self._handle_assertion(frame.payload, current)
        if frame.type == FRAME_REGISTRATION:
            return self._handle_registration(frame.payload, current)
        # 帧解码已限定类型, 走到这里说明协议实现不一致
        return self._protocol_error("收到未知帧类型")

    def tick(self, now: float | None = None) -> tuple[Action, ...]:
        """
        检查挑战过期与整体准入超时; 传输层在空闲循环里调用.

        :param now: 注入的单调时钟秒, 自测用.
        :return: 需要执行的动作.
        """
        if self._closed or self._state == "admitted":
            return ()
        current = self._clock() if now is None else now
        if current - self._started_at >= self._options.auth_timeout_seconds:
            self._logger.log(
                "ERROR",
                "admission.auth.timeout",
                "准入超时, 关闭连接",
                session_id=self.session_id,
                stage="auth",
            )
            return (self._send_auth_result(False, REASON_AUTH_TIMEOUT), self._close(REASON_AUTH_TIMEOUT))
        if self._pending is not None and current >= self._pending.expires_at:
            self._pending = None
            self._logger.log(
                "WARNING",
                "admission.challenge.expired",
                "挑战已过期, 已作废",
                session_id=self.session_id,
                reason=REASON_CHALLENGE_EXPIRED,
            )
            return (self._send_auth_result(False, REASON_CHALLENGE_EXPIRED),)
        return ()

    def shutdown(self, reason: str) -> None:
        """外部要求收尾; 释放终端并标记关闭, 重复调用安全."""
        self._close(reason)

    # ---------- 终端数据 ----------
    def _handle_terminal_data(self, payload: bytes) -> tuple[Action, ...]:
        """准入前丢弃终端输入; 准入后写入终端."""
        if self._state != "admitted" or self._terminal is None:
            self._logger.log(
                "DEBUG",
                "admission.input.dropped",
                "准入前收到终端输入, 已丢弃",
                session_id=self.session_id,
                stage="pre-auth",
            )
            return ()
        return (WriteTerminal(payload),)

    def _handle_resize(self, payload: bytes) -> tuple[Action, ...]:
        """准入前丢弃尺寸帧; 准入后按正整数调整终端, 非法值直接丢弃."""
        if self._state != "admitted" or self._terminal is None:
            self._logger.log(
                "DEBUG",
                "admission.input.dropped",
                "准入前收到尺寸帧, 已丢弃",
                session_id=self.session_id,
                stage="pre-auth",
            )
            return ()
        try:
            source = _parse_json_object(payload)
        except AdmissionRejection as exc:
            self._logger.log(
                "WARNING",
                "admission.frame.rejected",
                "尺寸帧不是合法 JSON, 已丢弃",
                session_id=self.session_id,
                reason=exc.reason,
            )
            return ()
        cols = _read_positive_int(source, "cols")
        rows = _read_positive_int(source, "rows")
        if cols == 0 or rows == 0:
            self._logger.log(
                "WARNING",
                "admission.frame.rejected",
                "尺寸帧行列数必须为正整数, 已丢弃",
                session_id=self.session_id,
                reason=REASON_ASSERTION_INVALID,
            )
            return ()
        return (ResizeTerminal(cols, rows),)

    # ---------- 准入开始 ----------
    def _handle_auth_begin(self, payload: bytes, now: float) -> tuple[Action, ...]:
        """处理 authBegin; 同一连接同时只允许一个待消费挑战."""
        try:
            source = _parse_json_object(payload)
        except AdmissionRejection as exc:
            return self._reject(exc.reason, exc.detail, now)

        client_version = source.get("clientVersion")
        if client_version != CLIENT_VERSION:
            return self._reject(
                REASON_BAD_CLIENT_VERSION,
                f"页面协议版本 {client_version!r} 不受支持",
                now,
            )
        intent = source.get("intent")
        if intent not in ("assert", "register"):
            return self._reject(REASON_ASSERTION_INVALID, "intent 只能是 assert 或 register", now)

        if self._pending is not None:
            # 不复用也不替换已有挑战, 防止客户端用重复 authBegin 重置挑战窗口
            self._logger.log(
                "WARNING",
                "admission.challenge.reused",
                "已有待消费挑战, 拒绝重复发起",
                session_id=self.session_id,
                reason=REASON_CHALLENGE_REUSED,
                stage="auth-begin",
            )
            return (self._send_auth_result(False, REASON_CHALLENGE_REUSED),)

        if intent == "register" and not self._options.allow_registration:
            # 注册必须发生在受信通道或 runner 本机, 默认关闭, 不能仅凭 authBegin 接受新公钥
            self._logger.log(
                "WARNING",
                "admission.registration.rejected",
                "注册入口未开放, 拒绝登记新凭据",
                session_id=self.session_id,
                reason=REASON_REGISTRATION_CLOSED,
                stage="registration",
            )
            return (self._send_auth_result(False, REASON_REGISTRATION_CLOSED),)

        challenge = secrets.token_bytes(32)
        self._pending = _PendingChallenge(
            value=challenge,
            session_id=self.session_id,
            intent=intent,
            expires_at=now + self._options.challenge_ttl_seconds,
            issued_at=now,
        )
        timeout_ms = max(MIN_TIMEOUT_MS, min(MAX_TIMEOUT_MS, int(self._options.challenge_ttl_seconds * 1000)))
        challenge_text = b64url_encode(challenge)

        if intent == "assert":
            body = {
                "challenge": challenge_text,
                "rpId": self._options.rp_id,
                "timeoutMs": timeout_ms,
                "userVerification": self._options.user_verification,
                "allowCredentialIds": self._verifier.allowed_credential_ids(),
            }
            self._logger.log(
                "DEBUG",
                "admission.challenge.issued",
                "已下发断言挑战",
                session_id=self.session_id,
                stage="auth",
            )
            return (SendFrame(FRAME_AUTH_CHALLENGE, _json_bytes(body)),)

        body = {
            "challenge": challenge_text,
            "rpId": self._options.rp_id,
            "rpName": self._options.rp_name,
            "userId": b64url_encode(secrets.token_bytes(16)),
            "userName": "user",
            "userDisplayName": "用户",
            "timeoutMs": timeout_ms,
            "userVerification": self._options.user_verification,
            "excludeCredentialIds": self._verifier.allowed_credential_ids(),
        }
        self._logger.log(
            "INFO",
            "admission.registration.requested",
            "注册入口已开放, 已下发注册选项",
            session_id=self.session_id,
            stage="registration",
        )
        return (SendFrame(FRAME_REGISTRATION_OPTIONS, _json_bytes(body)),)

    # ---------- 断言 ----------
    def _handle_assertion(self, payload: bytes, now: float) -> tuple[Action, ...]:
        """校验断言; 挑战先消费后验签, 失败不归还, 防止在同一挑战上反复尝试."""
        try:
            source = _parse_json_object(payload)
            challenge_text = _extract_challenge_text(source)
        except AdmissionRejection as exc:
            return self._reject(exc.reason, exc.detail, now)

        pending, rejection = self._consume_challenge(challenge_text, now, intent="assert")
        if rejection is not None:
            return self._reject(rejection.reason, rejection.detail, now)
        if pending is None:
            # 消费函数要么给出挑战, 要么给出拒绝原因, 两者同时为空属于实现错误
            return self._protocol_error("挑战消费状态不一致")

        try:
            credential = self._verifier.verify_assertion(source, pending.value)
        except AdmissionRejection as exc:
            return self._reject(exc.reason, exc.detail, now)

        self._logger.log(
            "INFO",
            "admission.assertion.accepted",
            "断言验签通过",
            session_id=self.session_id,
            credential_id=b64url_encode(credential.credential_id),
            stage="auth",
        )
        return self._admit(credential.credential_id, now)

    # ---------- 注册 ----------
    def _handle_registration(self, payload: bytes, now: float) -> tuple[Action, ...]:
        """校验注册材料, 只保存公钥与凭据标识; 注册成功后按受信通道直接准入."""
        if not self._options.allow_registration:
            self._logger.log(
                "WARNING",
                "admission.registration.rejected",
                "注册入口未开放, 丢弃注册材料",
                session_id=self.session_id,
                reason=REASON_REGISTRATION_CLOSED,
                stage="registration",
            )
            return (self._send_auth_result(False, REASON_REGISTRATION_CLOSED),)

        try:
            source = _parse_json_object(payload)
            challenge_text = _extract_challenge_text(source)
        except AdmissionRejection as exc:
            return self._reject(REASON_REGISTRATION_INVALID, exc.detail, now)

        pending, rejection = self._consume_challenge(challenge_text, now, intent="register")
        if rejection is not None:
            return self._reject(REASON_REGISTRATION_INVALID, rejection.detail, now)
        if pending is None:
            # 消费函数要么给出挑战, 要么给出拒绝原因, 两者同时为空属于实现错误
            return self._protocol_error("注册挑战消费状态不一致")

        try:
            credential = self._verifier.verify_registration(source, pending.value)
        except AdmissionRejection as exc:
            return self._reject(exc.reason, exc.detail, now)

        self._verifier.credentials[credential.credential_id] = credential
        self._logger.log(
            "INFO",
            "admission.registration.accepted",
            "已登记新凭据公钥",
            session_id=self.session_id,
            credential_id=b64url_encode(credential.credential_id),
            stage="registration",
        )
        return self._admit(credential.credential_id, now)

    # ---------- 挑战消费 ----------
    def _consume_challenge(
        self,
        challenge_text: str,
        now: float,
        intent: str,
    ) -> tuple[_PendingChallenge | None, AdmissionRejection | None]:
        """
        消费一次性挑战.

        :return: (挑战记录, None) 或 (None, 拒绝原因).
        """
        pending = self._pending
        if pending is None:
            if challenge_text in self._consumed:
                return None, AdmissionRejection(REASON_CHALLENGE_REUSED, "挑战已被使用")
            return None, AdmissionRejection(REASON_ASSERTION_INVALID, "没有待消费的挑战")
        if pending.intent != intent:
            return None, AdmissionRejection(REASON_ASSERTION_INVALID, "帧类型与准入意图不符")
        if not hmac.compare_digest(pending.session_id.encode("utf-8"), self.session_id.encode("utf-8")):
            # 挑战只在本会话内有效, 换会话后必须重新发起
            return None, AdmissionRejection(REASON_ASSERTION_INVALID, "挑战不属于本次会话")
        if now >= pending.expires_at:
            self._pending = None
            self._logger.log(
                "WARNING",
                "admission.challenge.expired",
                "挑战已过期, 已作废",
                session_id=self.session_id,
                reason=REASON_CHALLENGE_EXPIRED,
            )
            return None, AdmissionRejection(REASON_CHALLENGE_EXPIRED, "挑战已过期")
        try:
            submitted = b64url_decode(challenge_text)
        except ValueError:
            return None, AdmissionRejection(REASON_ASSERTION_INVALID, "挑战不是合法 base64url")
        if not hmac.compare_digest(submitted, pending.value):
            return None, AdmissionRejection(REASON_ASSERTION_INVALID, "挑战与本次会话下发值不符")

        # 先消费再验签: 验签失败也不归还挑战, 避免同一挑战被反复利用
        self._pending = None
        self._consumed[challenge_text] = now
        cutoff = now - self._options.auth_timeout_seconds
        self._consumed = {key: value for key, value in self._consumed.items() if value >= cutoff}
        return pending, None

    # ---------- 放行与拒绝 ----------
    def _admit(self, credential_id: bytes, now: float) -> tuple[Action, ...]:
        """打开终端并回复准入成功; 终端不可用时按失败关闭, 不放行."""
        if self._state == "admitted":
            return ()
        try:
            terminal = self._terminal_factory()
        except TerminalError as exc:
            self._logger.log_exception(
                "ERROR",
                "admission.terminal.failed",
                "终端会话不可用, 拒绝准入",
                exc,
                session_id=self.session_id,
                stage="terminal",
            )
            return (self._send_auth_result(False, REASON_TERMINAL_UNAVAILABLE), self._close(REASON_TERMINAL_UNAVAILABLE))

        self._terminal = terminal
        self._state = "admitted"
        self._failed_attempts = 0
        self._logger.log(
            "INFO",
            "admission.terminal.opened",
            "准入通过, 终端已交接",
            session_id=self.session_id,
            credential_id=b64url_encode(credential_id),
            stage="terminal",
            duration_ms=int((now - self._started_at) * 1000),
        )
        return (self._send_auth_result(True, ""),)

    def _reject(self, reason: str, detail: str, now: float) -> tuple[Action, ...]:
        """
        记录一次拒绝并累计失败次数; 超过上限时附带关闭连接.

        校验不通过属于出错分支(09 第 5 节), 按 ERROR 记录并带异常三字段;
        挑战过期属于合法的「取不到」分支, 按 WARNING 记录.
        """
        self._failed_attempts += 1
        level = "WARNING" if reason == REASON_CHALLENGE_EXPIRED else "ERROR"
        rejection = AdmissionRejection(reason, detail)
        self._logger.log_exception(
            level,
            "admission.assertion.rejected",
            f"准入被拒绝: {detail}",
            rejection,
            session_id=self.session_id,
            reason=reason,
            attempt=self._failed_attempts,
            stage="auth",
        )
        if self._failed_attempts >= self._options.max_attempts:
            self._logger.log(
                "ERROR",
                "admission.auth.failed",
                "准入失败次数达到上限, 关闭连接",
                session_id=self.session_id,
                reason=reason,
                attempt=self._failed_attempts,
                stage="auth",
                duration_ms=int((now - self._started_at) * 1000),
            )
            self._close(reason)
            return (self._send_auth_result(False, reason), CloseConnection("AUTH_ATTEMPTS_EXCEEDED"))
        return (self._send_auth_result(False, reason),)

    def _send_auth_result(self, ok: bool, reason: str) -> SendFrame:
        """构造认证结果帧."""
        return _auth_result(ok, reason)

    def _protocol_error(self, detail: str) -> tuple[Action, ...]:
        """协议实现级错误: 记录 ERROR 并关闭连接, 不静默继续."""
        rejection = AdmissionRejection(REASON_PROTOCOL_ERROR, detail)
        self._logger.log_exception(
            "ERROR",
            "admission.frame.rejected",
            detail,
            rejection,
            session_id=self.session_id,
            reason=REASON_PROTOCOL_ERROR,
            stage="frame",
        )
        return (self._close(REASON_PROTOCOL_ERROR),)

    def _close(self, reason: str) -> CloseConnection:
        """内部关闭: 释放终端并置 closed, 返回关闭动作."""
        if self._closed:
            return CloseConnection(reason)
        self._closed = True
        self._state = "closed"
        if self._terminal is not None:
            self._terminal.close()
            self._terminal = None
        self._logger.log(
            "INFO",
            "admission.connection.closed",
            "网页准入连接已关闭",
            session_id=self.session_id,
            reason=reason,
            stage="close",
        )
        return CloseConnection(reason)


def _extract_challenge_text(source: Mapping[str, Any]) -> str:
    """
    从断言或注册负载的 clientDataJSON 中取出挑战原文.

    这里只做解析, 不做判定; 校验在 WebAuthnVerifier 中统一执行.
    """
    client_data_raw = b64url_decode(_require_string(source, "clientDataJSON"))
    try:
        client_data = json.loads(client_data_raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AdmissionRejection(REASON_ASSERTION_INVALID, "clientDataJSON 不是合法 JSON") from exc
    if not isinstance(client_data, dict):
        raise AdmissionRejection(REASON_ASSERTION_INVALID, "clientDataJSON 顶层必须是对象")
    challenge = client_data.get("challenge")
    if not isinstance(challenge, str):
        raise AdmissionRejection(REASON_ASSERTION_INVALID, "clientDataJSON 缺少 challenge")
    return challenge


def _json_bytes(value: Mapping[str, Any]) -> bytes:
    """把对象编码为 UTF-8 JSON 字节, 用于控制帧负载."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


# =========** 传输层 =========**
class _ShutdownFlag:
    """信号触发的中止标志; 只由信号处理器写入, 主循环读取."""

    def __init__(self) -> None:
        self.triggered = False


def _install_signal_handlers(flag: _ShutdownFlag, logger: JsonLogger) -> None:
    """注册 SIGINT/SIGTERM 中止处理; 平台不支持时记录 WARNING 后继续."""
    def handler(_signum: int, _frame: Any) -> None:
        flag.triggered = True

    for name in ("SIGINT", "SIGTERM"):
        signum = getattr(signal, name, None)
        if signum is None:
            continue
        try:
            signal.signal(signum, handler)
        except (ValueError, OSError) as exc:
            logger.log(
                "WARNING",
                "admission.signal.unavailable",
                "信号处理器注册失败, 依赖默认行为收尾",
                stage="signal",
                reason=str(exc)[:MAX_LOG_TEXT],
            )


def run_stdio(session: AdmissionSession, logger: JsonLogger) -> int:
    """
    以 stdin/stdout 为字节流运行准入会话.

    :return: 0 表示会话正常结束; 非零表示运行期错误.
    """
    decoder = FrameDecoder()
    stdin_fd = sys.stdin.buffer.fileno()
    stdout = sys.stdout.buffer
    selector = selectors.DefaultSelector()
    selector.register(stdin_fd, selectors.EVENT_READ, "input")
    terminal_fd: int | None = None
    shutdown = _ShutdownFlag()
    _install_signal_handlers(shutdown, logger)

    try:
        while not session.closed and not shutdown.triggered:
            try:
                tick_actions = session.tick()
            except Exception as exc:  # 任务单元隔离: 单次定时检查失败不得拖垮整个进程
                logger.log_exception(
                    "ERROR",
                    "admission.tick.failed",
                    "准入定时检查异常, 关闭连接",
                    exc,
                    session_id=session.session_id,
                    stage="tick",
                )
                session.shutdown("PROTOCOL_ERROR")
                return 0
            for action in tick_actions:
                if _apply_action(action, session, stdout, logger) is False:
                    return 0

            terminal = session.terminal
            if terminal is not None and terminal_fd is None and terminal.fileno() >= 0:
                terminal_fd = terminal.fileno()
                selector.register(terminal_fd, selectors.EVENT_READ, "terminal")
                logger.log(
                    "DEBUG",
                    "admission.terminal.bridged",
                    "终端输出已接入选择器",
                    session_id=session.session_id,
                    stage="terminal",
                )

            for key, _events in selector.select(timeout=0.5):
                if key.data == "input":
                    chunk = os.read(stdin_fd, 65536)
                    if not chunk:
                        logger.log(
                            "INFO",
                            "admission.connection.closed",
                            "上游字节流已结束",
                            session_id=session.session_id,
                            reason="INPUT_CLOSED",
                            stage="close",
                        )
                        return 0
                    try:
                        frames = decoder.feed(chunk)
                    except FrameError as exc:
                        logger.log_exception(
                            "ERROR",
                            "admission.frame.rejected",
                            "帧解码失败, 关闭连接",
                            exc,
                            session_id=session.session_id,
                            reason=REASON_PROTOCOL_ERROR,
                            stage="frame",
                        )
                        session.shutdown(REASON_PROTOCOL_ERROR)
                        return 0
                    for frame in frames:
                        try:
                            frame_actions = session.handle(frame)
                        except Exception as exc:  # 任务单元隔离: 单帧处理失败只关闭本连接, 进程不崩
                            logger.log_exception(
                                "ERROR",
                                "admission.frame.failed",
                                "处理帧发生未预期异常, 关闭连接",
                                exc,
                                session_id=session.session_id,
                                reason=REASON_PROTOCOL_ERROR,
                                stage="frame",
                            )
                            session.shutdown(REASON_PROTOCOL_ERROR)
                            return 0
                        for action in frame_actions:
                            if _apply_action(action, session, stdout, logger) is False:
                                return 0
                        if session.closed:
                            return 0
                else:
                    if terminal is None:
                        continue
                    try:
                        output = terminal.read_available()
                    except TerminalError as exc:
                        logger.log_exception(
                            "ERROR",
                            "admission.terminal.failed",
                            "读取终端失败, 关闭连接",
                            exc,
                            session_id=session.session_id,
                            stage="terminal",
                        )
                        session.shutdown("ROUTE_GONE")
                        return 0
                    if output:
                        stdout.write(encode_frame(FRAME_TERMINAL_DATA, output))
                        stdout.flush()
                    elif terminal.is_closed and not output:
                        logger.log(
                            "INFO",
                            "admission.terminal.closed",
                            "终端已结束, 关闭连接",
                            session_id=session.session_id,
                            reason="ROUTE_GONE",
                            stage="close",
                        )
                        session.shutdown("ROUTE_GONE")
                        return 0
        return 0
    except OSError as exc:
        logger.log_exception(
            "ERROR",
            "admission.io.failed",
            "读写上游字节流失败",
            exc,
            session_id=session.session_id,
            stage="io",
        )
        session.shutdown("IO_ERROR")
        return 2
    finally:
        selector.close()
        session.shutdown("PROCESS_EXIT")
        logger.log("INFO", "admission.shutdown", "准入进程收尾完成", session_id=session.session_id, stage="shutdown")


def _apply_action(action: Action, session: AdmissionSession, stdout: Any, logger: JsonLogger) -> bool:
    """
    执行一个动作.

    :return: False 表示连接应结束; True 表示继续.
    """
    if isinstance(action, SendFrame):
        stdout.write(encode_frame(action.frame_type, action.payload))
        stdout.flush()
        return True
    if isinstance(action, WriteTerminal):
        terminal = session.terminal
        if terminal is None:
            return True
        try:
            terminal.write(action.data)
        except TerminalError as exc:
            logger.log_exception(
                "ERROR",
                "admission.terminal.failed",
                "写入终端失败, 关闭连接",
                exc,
                session_id=session.session_id,
                stage="terminal",
            )
            session.shutdown("ROUTE_GONE")
            return False
        return True
    if isinstance(action, ResizeTerminal):
        terminal = session.terminal
        if terminal is None:
            return True
        try:
            terminal.resize(action.cols, action.rows)
        except TerminalError as exc:
            # 尺寸同步失败不影响已建立的会话, 记 WARNING 后继续
            logger.log(
                "WARNING",
                "admission.terminal.resize_failed",
                "调整终端尺寸失败, 继续会话",
                session_id=session.session_id,
                reason=str(exc)[:MAX_LOG_TEXT],
                stage="terminal",
            )
        return True
    # CloseConnection
    return False


# =========** 命令行入口 =========**
def _build_parser() -> argparse.ArgumentParser:
    """构造命令行解析器; 帮助文本只描述参数, 不涉及凭据."""
    parser = argparse.ArgumentParser(
        prog="web_admission.py",
        description="runner 侧网页准入进程: WebAuthn 验签通过后把字节流交给 tmux 会话",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--session-id", required=True, help="本次会话标识, 挑战绑定该值")
    parser.add_argument("--tmux-session", default="actssh", help="目标 tmux 会话名")
    parser.add_argument("--allowed-credentials", required=True, help="允许清单 JSON 路径, 仅含公钥与凭据标识")
    parser.add_argument("--allow-registration", action="store_true", help="开放注册入口, 仅限受信通道使用")
    parser.add_argument("--rp-id", default=DEFAULT_RP_ID, help="WebAuthn 依赖方标识")
    parser.add_argument("--rp-name", default=DEFAULT_RP_NAME, help="依赖方展示名")
    parser.add_argument(
        "--user-verification",
        choices=("required", "preferred", "discouraged"),
        default="preferred",
        help="用户验证强度",
    )
    parser.add_argument("--challenge-ttl", type=float, default=DEFAULT_CHALLENGE_TTL_SECONDS, help="挑战有效期秒数")
    parser.add_argument("--auth-timeout", type=float, default=DEFAULT_AUTH_TIMEOUT_SECONDS, help="整体准入超时秒数")
    parser.add_argument("--max-attempts", type=int, default=DEFAULT_MAX_ATTEMPTS, help="同一连接允许的失败次数上限")
    parser.add_argument("--run-id", default=None, help="日志 run_id, 缺省取 GITHUB_RUN_ID 或时间戳")
    parser.add_argument("--log-level", choices=("DEBUG", "INFO", "WARNING", "ERROR"), default="INFO", help="日志级别")
    parser.add_argument("--log-dir", default=None, help="日志目录; 缺省写 stderr, 指定后写 <log-dir>/<run_id>.jsonl")
    return parser


def _build_logger(args: argparse.Namespace) -> JsonLogger:
    """按参数构造日志器; run_id 缺省取运行环境或时间戳."""
    run_id = args.run_id or os.environ.get("GITHUB_RUN_ID") or datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = os.path.join(args.log_dir, f"{run_id}.jsonl") if args.log_dir else None
    return JsonLogger(run_id, level=args.log_level, log_file=log_file)


def _validate_args(args: argparse.Namespace) -> None:
    """校验数值参数; 非法值按配置错误处理, 不退化为不安全默认."""
    if not SESSION_ID_PATTERN.fullmatch(args.session_id):
        raise ConfigError("session_id 只允许字母、数字、下划线、连字符, 长度 1 到 128")
    if not args.tmux_session:
        raise ConfigError("tmux 会话名不能为空")
    if args.challenge_ttl <= 0:
        raise ConfigError("挑战有效期必须大于 0")
    if args.auth_timeout <= 0:
        raise ConfigError("整体准入超时必须大于 0")
    if args.max_attempts < 1:
        raise ConfigError("失败次数上限必须大于等于 1")
    if not args.rp_id:
        raise ConfigError("rpId 不能为空")


def _make_terminal_factory(session_name: str, logger: JsonLogger) -> Callable[[], Any]:
    """构造终端工厂; 每次准入成功时新建一个 tmux 客户端, 与会话一一对应."""
    def factory() -> Any:
        return TmuxTerminal(session_name, logger)

    return factory


def run(args: argparse.Namespace, logger: JsonLogger) -> int:
    """
    启动并运行准入进程.

    :return: 进程退出码; 0 正常结束, 2 配置或运行错误.
    """
    _validate_args(args)
    credentials = load_allowed_credentials(args.allowed_credentials)
    logger.log(
        "INFO",
        "admission.credentials.loaded",
        "允许清单已载入",
        session_id=args.session_id,
        credential_count=len(credentials),
        stage="startup",
    )
    verifier = WebAuthnVerifier(
        rp_id=args.rp_id,
        credentials=credentials,
        user_verification=args.user_verification,
    )
    options = SessionOptions(
        session_id=args.session_id,
        rp_id=args.rp_id,
        rp_name=args.rp_name,
        allow_registration=bool(args.allow_registration),
        challenge_ttl_seconds=args.challenge_ttl,
        auth_timeout_seconds=args.auth_timeout,
        max_attempts=args.max_attempts,
        user_verification=args.user_verification,
    )
    session = AdmissionSession(
        options=options,
        verifier=verifier,
        logger=logger,
        terminal_factory=_make_terminal_factory(args.tmux_session, logger),
    )
    logger.log(
        "INFO",
        "admission.start",
        "网页准入进程已启动",
        session_id=args.session_id,
        stage="startup",
    )
    return run_stdio(session, logger)


def main(argv: Sequence[str] | None = None) -> int:
    """
    进程入口; 执行入口兜底与配置错误转换.

    :return: 0 正常结束; 1 未处理异常; 2 配置或运行错误.
    """
    parser = _build_parser()
    args = parser.parse_args(argv)
    logger = _build_logger(args)
    try:
        return run(args, logger)
    except KeyboardInterrupt:
        logger.log("INFO", "admission.shutdown", "收到中断, 正常收尾", session_id=args.session_id, stage="shutdown")
        return 130
    except (ConfigError, OSError) as exc:
        logger.log_exception("ERROR", "admission.failed", "准入进程配置或运行错误", exc, session_id=args.session_id)
        return 2
    except Exception as exc:  # 入口兜底: 记录完整栈后以非零码结束, 不裸奔
        logger.log_exception("ERROR", "admission.failed", "准入进程发生未处理异常", exc, session_id=args.session_id)
        return 1
    finally:
        logger.close()


if __name__ == "__main__":
    sys.exit(main())
