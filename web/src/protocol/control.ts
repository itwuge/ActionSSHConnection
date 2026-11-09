/**
 * 文件: control.ts
 * 所属目录: web/src/protocol/
 * 文件用途: 定义终端尺寸帧与 WebAuthn 准入控制帧的 JSON 负载结构, 并对服务端下发的负载做运行时校验.
 * 架构定位: 前端层协议模块, 上游是 relay-client.ts 解出的帧, 下游是 admission-client.ts 与 app-controller.ts, 只向内提供类型与解析函数.
 * 核心功能: 控制负载类型定义; JSON 编解码; 逐字段校验; 把不可信的 unknown 收窄为明确类型.
 * 职责边界: 不做 WebAuthn 签名与验签, 不生成挑战, 不保存任何凭据; 服务端是否按本契约实现由开发线确认.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 依赖浏览器 TextEncoder 与 TextDecoder.
 * 依赖关系: 无外部依赖; 被 admission-client.ts, relay-client.ts 与 app-controller.ts 调用.
 */

// =========** 类型 =========**
/**
 * WebAuthn 用户验证强度; 与浏览器 PublicKeyCredentialRequestOptions.userVerification 取值一致.
 */
export type UserVerification = 'required' | 'preferred' | 'discouraged';

/**
 * 客户端发起准入时发送的意图; assert 用于日常进入, register 用于登记本设备通行密钥.
 */
export type AdmissionIntent = 'assert' | 'register';

/**
 * 客户端发往服务端的准入开始帧负载.
 */
export interface AuthBeginPayload {
  /** 准入意图, 只允许 assert 或 register. */
  intent: AdmissionIntent;
  /** 前端协议版本, 便于服务端拒绝过旧页面. */
  clientVersion: string;
}

/**
 * 服务端下发的断言挑战; 挑战由 runner 侧生成, 中继不参与.
 */
export interface AuthChallengePayload {
  /** base64url 编码的挑战字节, 必须非空. */
  challenge: string;
  /** WebAuthn 依赖方标识, 必须是当前页面主机名或其上级域. */
  rpId: string;
  /** 浏览器等待认证器的超时毫秒数, 允许范围 10000 到 300000. */
  timeoutMs: number;
  /** 用户验证强度, 缺省按 preferred 处理. */
  userVerification: UserVerification;
  /** 允许的凭据标识列表, base64url; 空数组表示不限定. */
  allowCredentialIds: string[];
}

/**
 * 客户端提交的断言; 全部为 base64url, 私钥始终在设备内, 本结构不含私钥.
 */
export interface AuthAssertionPayload {
  /** 凭据标识, base64url. */
  credentialId: string;
  /** 认证器数据, base64url. */
  authenticatorData: string;
  /** 客户端数据 JSON, base64url. */
  clientDataJSON: string;
  /** 签名值, base64url. */
  signature: string;
  /** 用户句柄, 无则省略该字段, 不写空字符串. */
  userHandle?: string;
}

/**
 * 服务端下发的注册选项; 公钥登记由 runner 侧完成, 中继不存私钥.
 */
export interface RegistrationOptionsPayload {
  /** base64url 编码的挑战字节, 必须非空. */
  challenge: string;
  /** WebAuthn 依赖方标识. */
  rpId: string;
  /** 依赖方展示名, 仅用于认证器提示. */
  rpName: string;
  /** 用户句柄, base64url, 由服务端生成. */
  userId: string;
  /** 用户名, 仅用于认证器提示. */
  userName: string;
  /** 用户展示名, 仅用于认证器提示. */
  userDisplayName: string;
  /** 浏览器等待认证器的超时毫秒数, 允许范围 10000 到 300000. */
  timeoutMs: number;
  /** 用户验证强度. */
  userVerification: UserVerification;
  /** 需要排除的已有凭据标识列表, base64url. */
  excludeCredentialIds: string[];
}

/**
 * 客户端提交的注册结果; attestationObject 与 clientDataJSON 均为公钥侧材料, 不含私钥.
 */
export interface RegistrationPayload {
  /** 凭据标识, base64url. */
  credentialId: string;
  /** 客户端数据 JSON, base64url. */
  clientDataJSON: string;
  /** 认证器证明对象, base64url, 内含公钥. */
  attestationObject: string;
  /** 认证器报告的传输方式, 供服务端记录, 不做判定. */
  transports: string[];
}

/**
 * 服务端返回的准入结果.
 */
export interface AuthResultPayload {
  /** 是否准入通过. */
  ok: boolean;
  /** 验签方标识; 真实实现应填 runner, 页面据此区分本地模拟环境. */
  verifier: string;
  /** 失败或提示原因, 面向界面展示, 不得含凭据. */
  reason: string;
}

/**
 * 终端尺寸帧负载.
 */
export interface ResizePayload {
  /** 列数, 必须为正整数. */
  cols: number;
  /** 行数, 必须为正整数. */
  rows: number;
}

/**
 * 控制负载解析失败; 消息面向界面, 不包含原始负载内容, 避免把未知数据回显到页面.
 */
export class ControlPayloadError extends Error {
  /**
   * @param message 解析失败原因, 面向界面展示.
   */
  constructor(message: string) {
    super(message);
    this.name = 'ControlPayloadError';
  }
}

// =========** 常量 =========**
/** 超时下限 10 秒, 低于此值认证器来不及弹出, 只会制造无谓失败. */
const MIN_TIMEOUT_MS = 10_000;

/** 超时上限 300 秒, 高于此值浏览器与用户都不可控, 统一截断. */
const MAX_TIMEOUT_MS = 300_000;

// =========** 函数 =========**
/**
 * 把对象编码为 UTF-8 JSON 字节.
 *
 * @param value 可序列化对象, 不得含 undefined 字段以外的不可序列化值.
 * @returns UTF-8 编码的 JSON 字节.
 * @throws {TypeError} 对象含循环引用或 BigInt 时由 JSON.stringify 抛出.
 */
export function encodeJson(value: unknown): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(value));
}

/**
 * 读取一个 JSON 对象, 拒绝数组与 null.
 *
 * @param payload 帧负载字节, 来源不可信.
 * @returns 键值对对象, 值仍为 unknown, 需要在调用处逐字段收窄.
 * @throws {ControlPayloadError} 非 UTF-8, 非 JSON 或顶层不是对象时抛出.
 */
export function decodeJsonObject(payload: Uint8Array): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(payload)) as unknown;
  } catch (error) {
    throw new ControlPayloadError(`控制帧不是合法 UTF-8 JSON: ${String(error)}`);
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new ControlPayloadError('控制帧顶层必须是 JSON 对象');
  }
  return parsed as Record<string, unknown>;
}

/**
 * 读取必填字符串字段.
 *
 * @param source 源对象, 来源不可信.
 * @param field 字段名, 用于错误提示.
 * @returns 非空字符串.
 * @throws {ControlPayloadError} 字段缺失或不是字符串时抛出.
 */
function readString(source: Record<string, unknown>, field: string): string {
  const value = source[field];
  if (typeof value !== 'string') {
    throw new ControlPayloadError(`控制帧字段 ${field} 必须是字符串`);
  }
  return value;
}

/**
 * 读取必填布尔字段.
 *
 * @param source 源对象, 来源不可信.
 * @param field 字段名, 用于错误提示.
 * @returns 布尔值.
 * @throws {ControlPayloadError} 字段缺失或不是布尔值时抛出.
 */
function readBoolean(source: Record<string, unknown>, field: string): boolean {
  const value = source[field];
  if (typeof value !== 'boolean') {
    throw new ControlPayloadError(`控制帧字段 ${field} 必须是布尔值`);
  }
  return value;
}

/**
 * 读取超时字段并截断到允许范围.
 *
 * @param source 源对象, 来源不可信.
 * @param field 字段名, 用于错误提示.
 * @returns 截断后的毫秒数, 范围 10000 到 300000.
 * @throws {ControlPayloadError} 字段不是有限数值时抛出.
 */
function readTimeout(source: Record<string, unknown>, field: string): number {
  const value = source[field];
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new ControlPayloadError(`控制帧字段 ${field} 必须是有限数值`);
  }
  return Math.min(MAX_TIMEOUT_MS, Math.max(MIN_TIMEOUT_MS, Math.trunc(value)));
}

/**
 * 读取用户验证强度, 缺省 preferred.
 *
 * @param source 源对象, 来源不可信.
 * @param field 字段名.
 * @returns 合法取值之一.
 * @throws {ControlPayloadError} 字段存在但不是三个合法取值时抛出.
 */
function readUserVerification(source: Record<string, unknown>, field: string): UserVerification {
  const value = source[field];
  if (value === undefined) {
    return 'preferred';
  }
  if (value === 'required' || value === 'preferred' || value === 'discouraged') {
    return value;
  }
  throw new ControlPayloadError(`控制帧字段 ${field} 取值不合法`);
}

/**
 * 读取字符串数组字段, 缺省空数组.
 *
 * @param source 源对象, 来源不可信.
 * @param field 字段名.
 * @returns 字符串数组副本, 调用方可安全修改.
 * @throws {ControlPayloadError} 字段存在但不是字符串数组时抛出.
 */
function readStringArray(source: Record<string, unknown>, field: string): string[] {
  const value = source[field];
  if (value === undefined) {
    return [];
  }
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
    throw new ControlPayloadError(`控制帧字段 ${field} 必须是字符串数组`);
  }
  return [...value];
}

/**
 * 解析服务端下发的断言挑战.
 *
 * @param payload 帧负载字节, 来源不可信.
 * @returns 校验后的挑战结构.
 * @throws {ControlPayloadError} 任一字段缺失或类型不符时抛出.
 */
export function parseAuthChallenge(payload: Uint8Array): AuthChallengePayload {
  const source = decodeJsonObject(payload);
  const challenge = readString(source, 'challenge');
  if (challenge.length === 0) {
    throw new ControlPayloadError('挑战不能为空');
  }
  return {
    challenge,
    rpId: readString(source, 'rpId'),
    timeoutMs: readTimeout(source, 'timeoutMs'),
    userVerification: readUserVerification(source, 'userVerification'),
    allowCredentialIds: readStringArray(source, 'allowCredentialIds')
  };
}

/**
 * 解析服务端下发的注册选项.
 *
 * @param payload 帧负载字节, 来源不可信.
 * @returns 校验后的注册选项结构.
 * @throws {ControlPayloadError} 任一字段缺失或类型不符时抛出.
 */
export function parseRegistrationOptions(payload: Uint8Array): RegistrationOptionsPayload {
  const source = decodeJsonObject(payload);
  const challenge = readString(source, 'challenge');
  const userId = readString(source, 'userId');
  if (challenge.length === 0 || userId.length === 0) {
    throw new ControlPayloadError('挑战与用户句柄都不能为空');
  }
  return {
    challenge,
    rpId: readString(source, 'rpId'),
    rpName: readString(source, 'rpName'),
    userId,
    userName: readString(source, 'userName'),
    userDisplayName: readString(source, 'userDisplayName'),
    timeoutMs: readTimeout(source, 'timeoutMs'),
    userVerification: readUserVerification(source, 'userVerification'),
    excludeCredentialIds: readStringArray(source, 'excludeCredentialIds')
  };
}

/**
 * 解析服务端返回的准入结果.
 *
 * @param payload 帧负载字节, 来源不可信.
 * @returns 校验后的结果结构.
 * @throws {ControlPayloadError} 任一字段缺失或类型不符时抛出.
 */
export function parseAuthResult(payload: Uint8Array): AuthResultPayload {
  const source = decodeJsonObject(payload);
  return {
    ok: readBoolean(source, 'ok'),
    verifier: readString(source, 'verifier'),
    reason: readString(source, 'reason')
  };
}

/**
 * 解析终端尺寸帧, 拒绝非正整数.
 *
 * @param payload 帧负载字节, 来源不可信.
 * @returns 校验后的行列数.
 * @throws {ControlPayloadError} 数值缺失, 非整数或非正数时抛出.
 */
export function parseResize(payload: Uint8Array): ResizePayload {
  const source = decodeJsonObject(payload);
  const cols = source['cols'];
  const rows = source['rows'];
  if (typeof cols !== 'number' || !Number.isInteger(cols) || cols <= 0) {
    throw new ControlPayloadError('cols 必须是正整数');
  }
  if (typeof rows !== 'number' || !Number.isInteger(rows) || rows <= 0) {
    throw new ControlPayloadError('rows 必须是正整数');
  }
  return { cols, rows };
}
