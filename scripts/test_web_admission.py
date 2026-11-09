#!/usr/bin/env python3
"""
文件: test_web_admission.py
所属目录: scripts/
文件用途: web_admission.py 的最小自测; 用假凭据与内存终端覆盖握手、放行与各类拒绝路径, 不接触真实设备.
架构定位: 脚本层测试, 只调用被测算法的公开边界(Frame/AdmissionSession/WebAuthnVerifier), 不启动 tmux, 不读写网络.
核心功能: 构造可控的 WebAuthn 断言/注册材料; 校验挑战一次性、有效期、会话绑定; 校验 origin/rpId/签名/白名单;
          校验准入前终端输入丢弃、失败次数上限、整体超时、注册默认关闭; 校验日志字段与敏感值不落日志.
职责边界: 不验证真实认证器的签名计数器与厂商证明链; 不验证中继到 runner 的实际桥接; 不验证 tmux 会话行为.
运行环境: Python 3.10 以上; 需要 fido2 与 cryptography, 按 scripts/requirements-web-admission.txt 安装.
依赖关系: 依赖 web_admission.py; 测试材料全部在内存中生成, 私钥只用一次即丢弃.

运行方式:
  python scripts/test_web_admission.py -v

真机与真实浏览器才能验证的部分(本文件无法覆盖):
  1. 真实认证器(平台或安全密钥)生成的断言与注册材料, 含 ES256/RS256 编码与签名计数器行为.
  2. 浏览器对 authChallenge/registrationOptions 的接受度、origin 实际取值、WebAuthn 可用性提示.
  3. 中继把网页字节流转发到 runner 准入进程 stdin/stdout 的桥接链路(设计书标注为待真机确认).
  4. tmux attach 的 PTY 尺寸同步、退出 detach 行为与多客户端共享会话的表现.
  5. 通过中继连接时 origin 是否仍为 https://wuge.fun(反向代理不得改写 Origin).
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import struct
import sys
import tempfile
import unittest
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from fido2 import cbor
    from fido2.cose import ES256
except ImportError as import_error:  # 依赖缺失时明确跳过, 不用假实现冒充通过
    TEST_DEPENDENCIES_AVAILABLE = False
    TEST_DEPENDENCY_ERROR = import_error
else:
    TEST_DEPENDENCIES_AVAILABLE = True
    TEST_DEPENDENCY_ERROR = None

from web_admission import (  # noqa: E402 - 先修正 sys.path 再导入被测模块
    CLIENT_VERSION,
    DEFAULT_RP_ID,
    FRAME_AUTH_ASSERTION,
    FRAME_AUTH_BEGIN,
    FRAME_AUTH_CHALLENGE,
    FRAME_AUTH_RESULT,
    FRAME_REGISTRATION,
    FRAME_REGISTRATION_OPTIONS,
    FRAME_RESIZE,
    FRAME_TERMINAL_DATA,
    AdmissionSession,
    AllowedCredential,
    ConfigError,
    Frame,
    FrameDecoder,
    FrameError,
    JsonLogger,
    SendFrame,
    SessionOptions,
    WebAuthnVerifier,
    b64url_decode,
    b64url_encode,
    encode_frame,
    load_allowed_credentials,
)


# =========** 测试替身 =========**
class FakeTerminal:
    """内存终端; 只记录写入与尺寸, 不产生外部副作用."""

    def __init__(self) -> None:
        self.written: list[bytes] = []
        self.resizes: list[tuple[int, int]] = []
        self.closed = False

    def write(self, data: bytes) -> None:
        """记录写入字节."""
        self.written.append(data)

    def resize(self, cols: int, rows: int) -> None:
        """记录尺寸变化."""
        self.resizes.append((cols, rows))

    def read_available(self) -> bytes:
        """内存终端没有输出."""
        return b""

    def fileno(self) -> int:
        """返回 -1, 表示不能被选择器监听."""
        return -1

    def close(self) -> None:
        """标记关闭."""
        self.closed = True

    @property
    def is_closed(self) -> bool:
        """是否已关闭."""
        return self.closed


class FakeClock:
    """可控单调时钟; 用于确定性地推进挑战有效期与准入超时."""

    def __init__(self, start: float = 1000.0) -> None:
        self.value = start

    def __call__(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        """向未来推进指定秒数."""
        self.value += seconds


# =========** 材料构造 =========**
@unittest.skipUnless(TEST_DEPENDENCIES_AVAILABLE, f"缺少测试依赖: {TEST_DEPENDENCY_ERROR}")
class AdmissionTestCase(unittest.TestCase):
    """准入状态机与验签的共用夹具."""

    def setUp(self) -> None:
        self.private_key = ec.generate_private_key(ec.SECP256R1())
        self.credential_id = b"credential-1"
        self.credential = AllowedCredential(
            credential_id=self.credential_id,
            public_key=ES256.from_cryptography_key(self.private_key.public_key()),
        )
        self.clock = FakeClock()
        self.terminals: list[FakeTerminal] = []
        self.logger = JsonLogger("test-run", level="ERROR")

    def make_session(
        self,
        *,
        credentials: list[AllowedCredential] | None = None,
        allow_registration: bool = False,
        challenge_ttl: float = 60.0,
        auth_timeout: float = 120.0,
        max_attempts: int = 3,
        logger: JsonLogger | None = None,
    ) -> AdmissionSession:
        """构造会话; 终端工厂记录每次打开的内存终端."""
        selected = credentials if credentials is not None else [self.credential]
        verifier = WebAuthnVerifier(DEFAULT_RP_ID, {item.credential_id: item for item in selected})
        options = SessionOptions(
            session_id="session-1",
            allow_registration=allow_registration,
            challenge_ttl_seconds=challenge_ttl,
            auth_timeout_seconds=auth_timeout,
            max_attempts=max_attempts,
        )

        def factory() -> FakeTerminal:
            terminal = FakeTerminal()
            self.terminals.append(terminal)
            return terminal

        return AdmissionSession(
            options=options,
            verifier=verifier,
            logger=logger or self.logger,
            terminal_factory=factory,
            clock=self.clock,
        )

    def begin(
        self,
        session: AdmissionSession,
        *,
        intent: str = "assert",
        client_version: str = CLIENT_VERSION,
    ) -> tuple[Any, ...]:
        """发送 authBegin 并返回动作序列."""
        body = json.dumps({"clientVersion": client_version, "intent": intent}).encode("utf-8")
        return session.handle(Frame(FRAME_AUTH_BEGIN, body), now=self.clock.value)

    def challenge_from(self, actions: tuple[Any, ...]) -> bytes:
        """从 authChallenge/registrationOptions 动作中取出挑战原文."""
        for action in actions:
            if isinstance(action, SendFrame) and action.frame_type in (FRAME_AUTH_CHALLENGE, FRAME_REGISTRATION_OPTIONS):
                return b64url_decode(json.loads(action.payload)["challenge"])
        self.fail("动作序列中没有挑战帧")

    def result_from(self, actions: tuple[Any, ...]) -> dict[str, Any]:
        """取出最后一个 authResult 并解析."""
        results = [
            action
            for action in actions
            if isinstance(action, SendFrame) and action.frame_type == FRAME_AUTH_RESULT
        ]
        self.assertTrue(results, "动作序列中没有 authResult")
        return json.loads(results[-1].payload)

    def build_assertion(
        self,
        challenge: bytes,
        *,
        credential_id: bytes | None = None,
        rp_id: str = DEFAULT_RP_ID,
        origin: str = "https://wuge.fun",
        signing_key: Any | None = None,
        user_present: bool = True,
    ) -> dict[str, str]:
        """构造一条 WebAuthn 断言; 默认用夹具私钥签名."""
        client_data = {
            "type": "webauthn.get",
            "challenge": b64url_encode(challenge),
            "origin": origin,
            "crossOrigin": False,
        }
        client_data_raw = json.dumps(client_data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        flags = 0x01 if user_present else 0x00
        authenticator_data = (
            hashlib.sha256(rp_id.encode("utf-8")).digest() + bytes([flags]) + struct.pack(">I", 0)
        )
        key = signing_key or self.private_key
        signature = key.sign(
            authenticator_data + hashlib.sha256(client_data_raw).digest(),
            ec.ECDSA(hashes.SHA256()),
        )
        return {
            "credentialId": b64url_encode(credential_id or self.credential_id),
            "clientDataJSON": b64url_encode(client_data_raw),
            "authenticatorData": b64url_encode(authenticator_data),
            "signature": b64url_encode(signature),
            "userHandle": "",
        }

    def submit_assertion(
        self,
        session: AdmissionSession,
        assertion: dict[str, str],
    ) -> tuple[Any, ...]:
        """发送 authAssertion 并返回动作序列."""
        payload = json.dumps(assertion, separators=(",", ":")).encode("utf-8")
        return session.handle(Frame(FRAME_AUTH_ASSERTION, payload), now=self.clock.value)

    def build_registration(
        self,
        challenge: bytes,
        *,
        credential_id: bytes = b"registered-credential",
        rp_id: str = DEFAULT_RP_ID,
        origin: str = "https://wuge.fun",
        key: Any | None = None,
    ) -> dict[str, str]:
        """构造一份 fmt=none 的注册材料, 只携带公钥与凭据标识."""
        client_data = {
            "type": "webauthn.create",
            "challenge": b64url_encode(challenge),
            "origin": origin,
            "crossOrigin": False,
        }
        client_data_raw = json.dumps(client_data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        public_key = ES256.from_cryptography_key((key or self.private_key).public_key())
        cose_bytes = cbor.encode(public_key)
        authenticator_data = (
            hashlib.sha256(rp_id.encode("utf-8")).digest()
            + bytes([0x41])  # UP + AT
            + struct.pack(">I", 0)
            + b"\x00" * 16
            + struct.pack(">H", len(credential_id))
            + credential_id
            + cose_bytes
        )
        attestation_object = cbor.encode({"fmt": "none", "attStmt": {}, "authData": authenticator_data})
        return {
            "credentialId": b64url_encode(credential_id),
            "clientDataJSON": b64url_encode(client_data_raw),
            "attestationObject": b64url_encode(attestation_object),
            "transports": ["internal"],
        }

    # ---------- 放行路径 ----------
    def test_valid_assertion_admits_and_forwards_terminal_data(self) -> None:
        """合法断言应放行, 并把后续终端输入交给终端."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))

        actions = self.submit_assertion(session, self.build_assertion(challenge))
        result = self.result_from(actions)
        self.assertTrue(result["ok"])
        self.assertEqual(result["verifier"], "runner")
        self.assertTrue(session.authenticated)
        self.assertEqual(len(self.terminals), 1)

        forwarded = session.handle(Frame(FRAME_TERMINAL_DATA, b"ls -al\n"), now=self.clock.value)
        self.assertEqual(len(forwarded), 1)
        self.assertEqual(forwarded[0].data, b"ls -al\n")

        resized = session.handle(
            Frame(FRAME_RESIZE, json.dumps({"cols": 120, "rows": 40}).encode("utf-8")),
            now=self.clock.value,
        )
        self.assertEqual(len(resized), 1)
        self.assertEqual((resized[0].cols, resized[0].rows), (120, 40))

    def test_terminal_input_dropped_before_auth(self) -> None:
        """准入前终端输入与尺寸帧必须丢弃, 不产生写终端动作."""
        session = self.make_session()
        self.assertEqual(session.handle(Frame(FRAME_TERMINAL_DATA, b"id\n"), now=self.clock.value), ())
        self.assertEqual(
            session.handle(Frame(FRAME_RESIZE, b'{"cols":80,"rows":24}'), now=self.clock.value),
            (),
        )
        self.assertEqual(self.terminals, [])

    # ---------- 挑战约束 ----------
    def test_challenge_is_single_use(self) -> None:
        """同一挑战第二次提交必须按已使用拒绝."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))
        bad_signature = ec.generate_private_key(ec.SECP256R1())
        first = self.submit_assertion(session, self.build_assertion(challenge, signing_key=bad_signature))
        self.assertFalse(self.result_from(first)["ok"])

        second = self.submit_assertion(session, self.build_assertion(challenge))
        self.assertEqual(self.result_from(second)["reason"], "CHALLENGE_REUSED")
        self.assertFalse(session.authenticated)

    def test_expired_challenge_rejected(self) -> None:
        """超过有效期后提交断言必须按过期拒绝."""
        session = self.make_session(challenge_ttl=5.0)
        challenge = self.challenge_from(self.begin(session))
        self.clock.advance(6.0)
        actions = self.submit_assertion(session, self.build_assertion(challenge))
        self.assertEqual(self.result_from(actions)["reason"], "CHALLENGE_EXPIRED")

    def test_challenge_mismatch_rejected(self) -> None:
        """挑战与本次下发值不符必须拒绝."""
        session = self.make_session()
        self.challenge_from(self.begin(session))
        actions = self.submit_assertion(session, self.build_assertion(b"x" * 32))
        self.assertEqual(self.result_from(actions)["reason"], "ASSERTION_INVALID")

    def test_challenge_is_bound_to_session(self) -> None:
        """A 会话的断言不能用于 B 会话."""
        session_a = self.make_session()
        challenge_a = self.challenge_from(self.begin(session_a))

        session_b = self.make_session()
        self.challenge_from(self.begin(session_b))
        actions = self.submit_assertion(session_b, self.build_assertion(challenge_a))
        self.assertEqual(self.result_from(actions)["reason"], "ASSERTION_INVALID")
        self.assertFalse(session_b.authenticated)

    def test_duplicate_auth_begin_does_not_reset_challenge(self) -> None:
        """重复 authBegin 必须拒绝, 且原挑战仍然有效."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))
        duplicate = self.begin(session)
        self.assertEqual(self.result_from(duplicate)["reason"], "CHALLENGE_REUSED")

        accepted = self.submit_assertion(session, self.build_assertion(challenge))
        self.assertTrue(self.result_from(accepted)["ok"])

    # ---------- 断言校验项 ----------
    def test_unknown_credential_rejected(self) -> None:
        """不在允许清单内的凭据必须拒绝."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))
        actions = self.submit_assertion(session, self.build_assertion(challenge, credential_id=b"unknown"))
        self.assertEqual(self.result_from(actions)["reason"], "CREDENTIAL_NOT_ALLOWED")

    def test_wrong_origin_rejected(self) -> None:
        """origin 不是 https 或主机不匹配时必须拒绝."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))
        actions = self.submit_assertion(session, self.build_assertion(challenge, origin="https://evil.example"))
        self.assertEqual(self.result_from(actions)["reason"], "ASSERTION_INVALID")

        session_http = self.make_session()
        challenge_http = self.challenge_from(self.begin(session_http))
        http_actions = self.submit_assertion(
            session_http,
            self.build_assertion(challenge_http, origin="http://wuge.fun"),
        )
        self.assertEqual(self.result_from(http_actions)["reason"], "ASSERTION_INVALID")

    def test_wrong_rp_id_rejected(self) -> None:
        """rpIdHash 与 wuge.fun 不符时必须拒绝."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))
        actions = self.submit_assertion(session, self.build_assertion(challenge, rp_id="evil.example"))
        self.assertEqual(self.result_from(actions)["reason"], "ASSERTION_INVALID")

    def test_bad_signature_rejected(self) -> None:
        """签名与凭据公钥不匹配时必须拒绝."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))
        other_key = ec.generate_private_key(ec.SECP256R1())
        actions = self.submit_assertion(session, self.build_assertion(challenge, signing_key=other_key))
        self.assertEqual(self.result_from(actions)["reason"], "ASSERTION_INVALID")
        self.assertFalse(session.authenticated)

    def test_missing_user_presence_rejected(self) -> None:
        """缺少用户在场标志时必须拒绝."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))
        actions = self.submit_assertion(session, self.build_assertion(challenge, user_present=False))
        self.assertEqual(self.result_from(actions)["reason"], "ASSERTION_INVALID")

    def test_bad_client_version_rejected(self) -> None:
        """页面协议版本不符时必须拒绝, 且不下发挑战."""
        session = self.make_session()
        actions = self.begin(session, client_version="0.0.1")
        self.assertEqual(self.result_from(actions)["reason"], "BAD_CLIENT_VERSION")

    def test_attempt_limit_closes_connection(self) -> None:
        """失败次数达到上限时必须关闭连接."""
        session = self.make_session(max_attempts=2)
        challenge = self.challenge_from(self.begin(session))
        other_key = ec.generate_private_key(ec.SECP256R1())
        self.submit_assertion(session, self.build_assertion(challenge, signing_key=other_key))

        challenge = self.challenge_from(self.begin(session))
        actions = self.submit_assertion(session, self.build_assertion(challenge, signing_key=other_key))
        reasons = [action.reason for action in actions if hasattr(action, "reason")]
        self.assertIn("AUTH_ATTEMPTS_EXCEEDED", reasons)
        self.assertTrue(session.closed)

    def test_auth_timeout_closes_connection(self) -> None:
        """整体准入超时后必须拒绝并关闭连接."""
        session = self.make_session(auth_timeout=30.0)
        self.begin(session)
        self.clock.advance(31.0)
        actions = session.tick()
        self.assertEqual(self.result_from(actions)["reason"], "AUTH_TIMEOUT")
        self.assertTrue(session.closed)

    # ---------- 注册链路 ----------
    def test_registration_closed_by_default(self) -> None:
        """默认关闭注册入口, 不能仅凭 authBegin 接受新公钥."""
        session = self.make_session()
        actions = self.begin(session, intent="register")
        self.assertEqual(self.result_from(actions)["reason"], "REGISTRATION_CLOSED")
        self.assertFalse(session.authenticated)

    def test_registration_succeeds_when_explicitly_opened(self) -> None:
        """显式开放注册时, 合法注册材料应登记公钥并放行."""
        session = self.make_session(allow_registration=True)
        actions = self.begin(session, intent="register")
        challenge = self.challenge_from(actions)
        self.assertFalse(session.authenticated)

        registration = self.build_registration(challenge)
        result = self.result_from(session.handle(Frame(FRAME_REGISTRATION, json.dumps(registration).encode("utf-8")), now=self.clock.value))
        self.assertTrue(result["ok"])
        self.assertTrue(session.authenticated)
        self.assertEqual(len(self.terminals), 1)

    def test_registration_with_tampered_credential_id_rejected(self) -> None:
        """注册材料中的凭据标识与认证器返回不一致时必须拒绝."""
        session = self.make_session(allow_registration=True)
        challenge = self.challenge_from(self.begin(session, intent="register"))
        registration = self.build_registration(challenge)
        registration["credentialId"] = b64url_encode(b"another-credential")
        actions = session.handle(Frame(FRAME_REGISTRATION, json.dumps(registration).encode("utf-8")), now=self.clock.value)
        self.assertEqual(self.result_from(actions)["reason"], "REGISTRATION_INVALID")
        self.assertFalse(session.authenticated)

    def test_registration_materials_rejected_when_closed(self) -> None:
        """注册入口关闭时, 即使收到注册材料也只回复关闭原因."""
        session = self.make_session()
        challenge = self.challenge_from(self.begin(session))
        registration = self.build_registration(challenge)
        actions = session.handle(Frame(FRAME_REGISTRATION, json.dumps(registration).encode("utf-8")), now=self.clock.value)
        self.assertEqual(self.result_from(actions)["reason"], "REGISTRATION_CLOSED")

    # ---------- 日志 ----------
    def test_logs_follow_whitelist_and_carry_no_assertion_material(self) -> None:
        """日志必须是带基础字段的 JSON 行, 且不含断言原文、签名或挑战."""
        buffer = io.StringIO()
        assertion: dict[str, str] = {}
        challenge = b""
        with contextlib.redirect_stderr(buffer):
            logger = JsonLogger("run-check", level="DEBUG")
            session = self.make_session(logger=logger)
            challenge = self.challenge_from(self.begin(session))
            other_key = ec.generate_private_key(ec.SECP256R1())
            assertion = self.build_assertion(challenge, signing_key=other_key)
            self.submit_assertion(session, assertion)
            logger.close()

        output = buffer.getvalue()
        records = [json.loads(line) for line in output.splitlines() if line.strip()]
        self.assertTrue(records)
        for record in records:
            for key in ("ts", "level", "logger", "event", "msg", "run_id"):
                self.assertIn(key, record)
            if record["level"] == "ERROR":
                for key in ("exc_type", "exc_msg", "stack"):
                    self.assertIn(key, record)
        self.assertNotIn(assertion["clientDataJSON"], output)
        self.assertNotIn(assertion["signature"], output)
        self.assertNotIn(assertion["authenticatorData"], output)
        self.assertNotIn(b64url_encode(challenge), output)


@unittest.skipUnless(TEST_DEPENDENCIES_AVAILABLE, f"缺少测试依赖: {TEST_DEPENDENCY_ERROR}")
class FrameDecoderTestCase(unittest.TestCase):
    """帧重组与协议边界测试."""

    def test_split_and_merged_frames(self) -> None:
        """任意切分与合并都应还原为原始帧序列."""
        stream = (
            encode_frame(FRAME_TERMINAL_DATA, b"hello")
            + encode_frame(FRAME_RESIZE, b'{"cols":80,"rows":24}')
            + encode_frame(FRAME_AUTH_BEGIN, b"{}")
        )
        decoder = FrameDecoder()
        frames: list[Frame] = []
        for index in range(len(stream)):
            frames.extend(decoder.feed(stream[index:index + 1]))
        self.assertEqual([(frame.type, frame.payload) for frame in frames], [
            (FRAME_TERMINAL_DATA, b"hello"),
            (FRAME_RESIZE, b'{"cols":80,"rows":24}'),
            (FRAME_AUTH_BEGIN, b"{}"),
        ])

    def test_bad_magic_rejected(self) -> None:
        """魔数不符必须抛出 FrameError."""
        decoder = FrameDecoder()
        with self.assertRaises(FrameError):
            decoder.feed(bytes([0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]))

    def test_server_direction_frame_rejected(self) -> None:
        """浏览器发来服务端方向帧必须按协议错误拒绝."""
        decoder = FrameDecoder()
        with self.assertRaises(FrameError):
            decoder.feed(encode_frame(FRAME_AUTH_CHALLENGE, b"{}"))

    def test_oversize_length_rejected(self) -> None:
        """声明长度超上限必须拒绝, 不等待负载到达."""
        decoder = FrameDecoder()
        header = struct.pack(">BBBBI", 0xA1, 0x01, FRAME_TERMINAL_DATA, 0, 1024 * 1024 + 1)
        with self.assertRaises(FrameError):
            decoder.feed(header)


@unittest.skipUnless(TEST_DEPENDENCIES_AVAILABLE, f"缺少测试依赖: {TEST_DEPENDENCY_ERROR}")
class AllowedCredentialsTestCase(unittest.TestCase):
    """允许清单读取测试; 只校验公钥侧材料."""

    def test_load_roundtrip(self) -> None:
        """合法清单应读出凭据标识与公钥."""
        private_key = ec.generate_private_key(ec.SECP256R1())
        entry = {
            "credential_id": b64url_encode(b"credential-1"),
            "public_key": b64url_encode(cbor.encode(ES256.from_cryptography_key(private_key.public_key()))),
            "transports": ["internal"],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "allowed.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump([entry], handle)
            credentials = load_allowed_credentials(path)
        self.assertIn(b"credential-1", credentials)
        self.assertEqual(credentials[b"credential-1"].transports, ("internal",))

    def test_missing_file_is_config_error(self) -> None:
        """清单文件不可读属于配置错误."""
        with self.assertRaises(ConfigError):
            load_allowed_credentials(os.path.join(tempfile.gettempdir(), "definitely-missing-allowed.json"))

    def test_empty_list_is_config_error(self) -> None:
        """空清单无法受理任何凭据, 属于配置错误."""
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "allowed.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump([], handle)
            with self.assertRaises(ConfigError):
                load_allowed_credentials(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
