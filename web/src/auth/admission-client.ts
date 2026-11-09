/**
 * 文件: admission-client.ts
 * 所属目录: web/src/auth/
 * 文件用途: 在浏览器侧驱动 WebAuthn 准入状态机, 按服务端下发的挑战完成签名并提交断言.
 * 架构定位: 前端层认证协调模块, 上游是 app-controller.ts, 下游是 webauthn-client.ts 与帧发送函数, 不直接持有连接对象.
 * 核心功能: 发起准入; 等待挑战; 处理注册选项; 提交断言或注册结果; 维护准入阶段与超时; 上报未对接状态.
 * 职责边界: 不验签, 不存凭据, 不决定谁可进入, 不发送终端数据; 服务端验签实现尚不存在时只上报未对接, 不伪造通过.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 依赖浏览器 WebAuthn 能力.
 * 依赖关系: 依赖 protocol/frames.ts, protocol/control.ts, webauthn-client.ts; 被 app-controller.ts 调用.
 */

import { FRAME_TYPE } from '../protocol/frames'; // 项目内模块: 帧类型编号
import {
  ControlPayloadError,
  encodeJson,
  parseAuthChallenge,
  parseAuthResult,
  parseRegistrationOptions
} from '../protocol/control'; // 项目内模块: 控制负载编解码与校验
import { createAssertion, createPasskey, WebAuthnClientError } from './webauthn-client'; // 项目内模块: 设备内签名

import type { Frame, FrameType } from '../protocol/frames'; // 项目内类型: 帧结构
import type { AdmissionIntent, AuthBeginPayload } from '../protocol/control'; // 项目内类型: 准入意图

// =========** 常量 =========**
/**
 * 等待服务端下发挑战的上限 8 秒; 取值依据是本地调试时人工可接受的最长空等,
 * runner 侧实现后应以实测往返时间为准调整, 当前值未在真机验证.
 */
const CHALLENGE_TIMEOUT_MS = 8_000;

/** 前端协议版本, 随帧格式变化递增; 服务端可据此拒绝过旧页面. */
const CLIENT_VERSION = '0.1.0';

/**
 * 准入失败原因码到中文提示的映射; 与 README 服务端对接清单中的错误码语义一一对应.
 * 未列出的原因按服务端原文展示, 因此服务端不得在 reason 中放置凭据或内部细节.
 */
const AUTH_FAILURE_TEXT: Readonly<Record<string, string>> = {
  ASSERTION_INVALID: '断言验签失败: 签名无效或挑战与本次会话不符, 请重新连接后重试.',
  CREDENTIAL_NOT_ALLOWED: '该设备凭据不在允许清单内, 请使用已登记的设备或先行注册.',
  CHALLENGE_EXPIRED: '准入挑战已过期, 请重新连接以获取新挑战.',
  CHALLENGE_REUSED: '准入挑战已被使用, 请重新连接以获取新挑战.',
  BAD_CLIENT_VERSION: '页面协议版本过旧, 请刷新页面或更新前端.'
};

// =========** 类型 =========**
/**
 * 准入阶段; 每个阶段对应界面上一句明确状态, 不使用布尔值压缩状态.
 */
export type AdmissionPhase =
  | 'idle'
  | 'awaiting-challenge'
  | 'awaiting-result'
  | 'admitted'
  | 'denied'
  | 'not-integrated'
  | 'error';

/**
 * 准入状态快照, 供界面渲染.
 */
export interface AdmissionSnapshot {
  /** 当前阶段. */
  phase: AdmissionPhase;
  /** 面向界面的补充说明, 不含凭据. */
  detail: string;
  /** 验签方标识; 仅 admitted 阶段有值, mock 表示本地模拟器放行. */
  verifier: string | null;
  /** 准入失败原因码; 仅 denied 阶段有值, 用于界面决定是否引导重新登记. */
  failureReason?: string;
}

/**
 * 帧发送函数; 由控制器注入, 本模块不感知连接细节.
 */
export type FrameSend = (type: FrameType, payload: Uint8Array) => void;

/**
 * 状态变化回调; 控制器据此更新界面与终端锁定.
 */
export type AdmissionListener = (snapshot: AdmissionSnapshot) => void;

/**
 * 注册成功回调; 只在服务端确认注册结果后触发, 参数为凭据标识.
 */
export type RegisteredListener = (credentialId: string) => void;

// =========** 类 =========**
/**
 * WebAuthn 准入客户端状态机.
 *
 * 方法一览:
 *   begin(intent) -> void: 发送准入开始帧并开始等待挑战.
 *   handleFrame(frame) -> Promise<void>: 处理挑战, 注册选项与结果帧.
 *   reset() -> void: 复位到空闲并清空计时器.
 *   isAdmitted -> boolean: 当前是否已准入.
 *   dispose() -> void: 释放计时器.
 */
export class AdmissionClient {
  private readonly listener: AdmissionListener;

  private readonly onRegistered: RegisteredListener;

  private readonly send: FrameSend;

  private snapshot: AdmissionSnapshot = { phase: 'idle', detail: '未开始', verifier: null };

  private intent: AdmissionIntent = 'assert';

  private preferredCredentialId: string | null = null;

  private pendingRegistrationId: string | null = null;

  private timer: number | null = null;

  private disposed = false;

  /**
   * @param listener 状态变化回调, 调用方保证不抛异常.
   * @param send 帧发送函数, 连接未打开时应抛错, 由本模块转为 error 状态.
   * @param onRegistered 注册成功回调; 传入凭据标识用于本机记忆, 不传则不记录.
   */
  constructor(listener: AdmissionListener, send: FrameSend, onRegistered: RegisteredListener = () => undefined) {
    this.listener = listener;
    this.send = send;
    this.onRegistered = onRegistered;
  }

  /** 当前是否已准入; 控制器用它决定终端输入是否上送. */
  get isAdmitted(): boolean {
    return this.snapshot.phase === 'admitted';
  }

  /**
   * 发起准入.
   *
   * @param intent assert 表示日常进入, register 表示登记本设备通行密钥.
   * @param preferredCredentialId 本机已登记的凭据标识; 服务端未限定允许清单时用它缩小选择范围.
   * @returns 无; 结果通过状态回调上报.
   * @throws {Error} 发送失败时抛错, 触发条件是连接已关闭.
   */
  begin(intent: AdmissionIntent, preferredCredentialId: string | null = null): void {
    if (this.disposed) {
      return;
    }
    this.clearTimer();
    this.intent = intent;
    this.preferredCredentialId = preferredCredentialId;
    this.pendingRegistrationId = null;
    this.update({ phase: 'awaiting-challenge', detail: '正在验证设备', verifier: null });
    const payload: AuthBeginPayload = { intent, clientVersion: CLIENT_VERSION };
    this.send(FRAME_TYPE.authBegin, encodeJson(payload));
    this.timer = window.setTimeout(() => {
      this.timer = null;
      // 没收到挑战说明服务端准入尚未就绪, 照实上报, 不把终端当作已放行
      this.update({
        phase: 'not-integrated',
        detail: '会话服务尚未就绪, 暂时无法进入; 请稍后重试.',
        verifier: null
      });
    }, CHALLENGE_TIMEOUT_MS);
  }

  /**
   * 处理一帧准入相关负载; 非准入帧直接忽略.
   *
   * @param frame 已解码帧.
   * @returns 异步完成; 认证器交互期间状态保持等待.
   */
  async handleFrame(frame: Frame): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      if (frame.type === FRAME_TYPE.authChallenge) {
        await this.handleChallenge(frame.payload);
        return;
      }
      if (frame.type === FRAME_TYPE.registrationOptions) {
        await this.handleRegistrationOptions(frame.payload);
        return;
      }
      if (frame.type === FRAME_TYPE.authResult) {
        this.handleResult(frame.payload);
      }
    } catch (error) {
      this.clearTimer();
      this.update({ phase: 'error', detail: describeError(error), verifier: null });
    }
  }

  /**
   * 复位到空闲; 用于断开连接或用户重新发起会话.
   *
   * @returns 无.
   */
  reset(): void {
    this.clearTimer();
    this.preferredCredentialId = null;
    this.pendingRegistrationId = null;
    this.update({ phase: 'idle', detail: '未开始', verifier: null });
  }

  /**
   * 释放计时器; 页面卸载时调用.
   *
   * @returns 无.
   */
  dispose(): void {
    this.disposed = true;
    this.clearTimer();
  }

  /**
   * 处理断言挑战: 在设备内签名后提交断言.
   *
   * @param payload 挑战帧负载, 来源不可信.
   * @returns 异步完成; 失败抛错由 handleFrame 统一转为 error 状态.
   * @throws {ControlPayloadError} 负载字段不合法时抛出.
   * @throws {WebAuthnClientError} 认证器不可用或用户取消时抛出.
   */
  private async handleChallenge(payload: Uint8Array): Promise<void> {
    if (this.intent !== 'assert') {
      throw new ControlPayloadError('注册流程收到断言挑战, 与当前意图不符');
    }
    this.clearTimer();
    const challenge = parseAuthChallenge(payload);
    const preferred = this.preferredCredentialId;
    if (preferred !== null && challenge.allowCredentialIds.length > 0 && !challenge.allowCredentialIds.includes(preferred)) {
      throw new WebAuthnClientError('CREDENTIAL_NOT_ALLOWED', '本机登记的凭据不在服务端允许清单内, 需要重新登记本设备.');
    }
    const effective =
      preferred !== null && challenge.allowCredentialIds.length === 0
        ? { ...challenge, allowCredentialIds: [preferred] }
        : challenge;
    this.update({ phase: 'awaiting-result', detail: '请在设备上确认', verifier: null });
    const assertion = await createAssertion(effective);
    this.send(FRAME_TYPE.authAssertion, encodeJson(assertion));
  }

  /**
   * 处理注册选项: 在设备内创建通行密钥后提交公钥侧材料.
   *
   * @param payload 注册选项帧负载, 来源不可信.
   * @returns 异步完成; 失败抛错由 handleFrame 统一转为 error 状态.
   * @throws {ControlPayloadError} 负载字段不合法时抛出.
   * @throws {WebAuthnClientError} 认证器不可用或用户取消时抛出.
   */
  private async handleRegistrationOptions(payload: Uint8Array): Promise<void> {
    if (this.intent !== 'register') {
      throw new ControlPayloadError('断言流程收到注册选项, 与当前意图不符');
    }
    this.clearTimer();
    const options = parseRegistrationOptions(payload);
    this.update({ phase: 'awaiting-result', detail: '正在登记本设备', verifier: null });
    const registration = await createPasskey(options);
    this.pendingRegistrationId = registration.credentialId;
    this.send(FRAME_TYPE.registration, encodeJson(registration));
  }

  /**
   * 处理服务端准入结果.
   *
   * @param payload 结果帧负载, 来源不可信.
   * @returns 无.
   * @throws {ControlPayloadError} 负载字段不合法时抛出.
   */
  private handleResult(payload: Uint8Array): void {
    this.clearTimer();
    const result = parseAuthResult(payload);
    if (result.ok) {
      const registeredId = this.pendingRegistrationId;
      this.pendingRegistrationId = null;
      if (registeredId !== null && this.intent === 'register') {
        this.onRegistered(registeredId);
      }
      this.update({
        phase: 'admitted',
        detail: result.reason.length > 0 ? result.reason : '已进入会话',
        verifier: result.verifier
      });
      return;
    }
    this.update({
      phase: 'denied',
      detail: describeFailure(result.reason),
      verifier: result.verifier.length > 0 ? result.verifier : null,
      failureReason: result.reason
    });
  }

  /**
   * 更新快照并通知界面; 内容只写状态文本, 不写凭据.
   *
   * @param snapshot 新快照.
   * @returns 无.
   */
  private update(snapshot: AdmissionSnapshot): void {
    this.snapshot = snapshot;
    this.listener(snapshot);
  }

  /**
   * 清除等待计时器; 重复调用安全.
   *
   * @returns 无.
   */
  private clearTimer(): void {
    if (this.timer !== null) {
      window.clearTimeout(this.timer);
      this.timer = null;
    }
  }
}

/**
 * 把准入失败原因码转为中文提示; 未登记的原因原样返回, 由服务端保证内容可展示.
 *
 * @param reason 服务端返回的原因码或说明.
 * @returns 面向界面的中文提示.
 */
function describeFailure(reason: string): string {
  if (reason.length === 0) {
    return '准入被拒绝.';
  }
  return AUTH_FAILURE_TEXT[reason] ?? reason;
}

/**
 * 把准入过程中的异常转为面向界面的中文原因.
 *
 * @param error 捕获到的异常, 类型未知.
 * @returns 中文原因; 已知类型给出具体提示, 未知类型只给出错误名.
 */
function describeError(error: unknown): string {
  if (error instanceof WebAuthnClientError) {
    return error.message;
  }
  if (error instanceof ControlPayloadError) {
    return `准入帧格式不符: ${error.message}`;
  }
  if (error instanceof Error) {
    return `准入流程失败: ${error.name}`;
  }
  return '准入流程失败: 未知错误';
}
