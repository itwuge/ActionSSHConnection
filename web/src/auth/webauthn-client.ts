/**
 * 文件: webauthn-client.ts
 * 所属目录: web/src/auth/
 * 文件用途: 在浏览器内完成 WebAuthn 注册与断言的客户端部分, 私钥由认证器保管, 页面只接触公钥侧材料.
 * 架构定位: 前端层认证模块, 上游是 admission-client.ts, 下游是浏览器 credential management API, 依赖方向单向调用.
 * 核心功能: 能力与安全上下文检测; 依赖方标识校验; 注册凭据; 生成断言; base64url 与字节互转.
 * 职责边界: 不做验签, 不生成挑战, 不保存凭据, 不输出任何密钥材料到页面或控制台; 验签与允许清单在 runner 侧.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 需安全上下文 HTTPS 或 localhost, 浏览器需支持 WebAuthn.
 * 依赖关系: 依赖 protocol/control.ts 的负载类型; 被 admission-client.ts 调用.
 */

import { classifyPageHost, describePageHostNotice, WEB_RP_ID } from '../config'; // 项目内模块: 部署域名与依赖方标识

import type {
  AuthChallengePayload,
  AuthAssertionPayload,
  RegistrationOptionsPayload,
  RegistrationPayload,
  UserVerification
} from '../protocol/control'; // 项目内类型: 准入负载结构

// =========** 常量 =========**
/**
 * base64url 字符集; 解码前必须校验, 避免把任意字符串交给 atob 后得到静默错误的字节.
 */
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;

/** 允许的签名算法: ES256 与 RS256, 覆盖平台认证器与常见安全密钥. */
const PUB_KEY_CRED_PARAMS: PublicKeyCredentialParameters[] = [
  { type: 'public-key', alg: -7 },
  { type: 'public-key', alg: -257 }
];

// =========** 类型 =========**
/**
 * WebAuthn 客户端错误码, 用于界面区分能力缺失, 安全上下文不符与用户取消.
 */
export type WebAuthnErrorCode =
  | 'NOT_SUPPORTED'
  | 'NOT_SECURE_CONTEXT'
  | 'RP_ID_MISMATCH'
  | 'INVALID_PAYLOAD'
  | 'CREDENTIAL_NOT_ALLOWED'
  | 'CREDENTIAL_FAILED';

/**
 * WebAuthn 客户端错误; 消息面向界面, 不含任何密钥材料.
 */
export class WebAuthnClientError extends Error {
  /** 错误码, 供界面决定提示方式. */
  readonly code: WebAuthnErrorCode;

  /**
   * @param code 错误码.
   * @param message 面向界面的中文原因.
   */
  constructor(code: WebAuthnErrorCode, message: string) {
    super(message);
    this.name = 'WebAuthnClientError';
    this.code = code;
  }
}

// =========** 函数 =========**
/**
 * 把二进制数据编码为 base64url, 不带填充.
 *
 * @param source ArrayBuffer 或 Uint8Array.
 * @returns base64url 字符串, 字符集 A-Z a-z 0-9 - _.
 */
function toBase64Url(source: ArrayBuffer | Uint8Array): string {
  const bytes = source instanceof Uint8Array ? source : new Uint8Array(source);
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

/**
 * 把 base64url 解码为字节; 允许尾部填充.
 *
 * @param value base64url 字符串, 不得为空.
 * @param field 字段名, 用于错误提示.
 * @returns 解码后的字节.
 * @throws {WebAuthnClientError} 字符集不合法或解码失败时抛出.
 */
function fromBase64Url(value: string, field: string): Uint8Array<ArrayBuffer> {
  const normalized = value.replace(/=+$/g, '');
  if (!BASE64URL_PATTERN.test(normalized)) {
    throw new WebAuthnClientError('INVALID_PAYLOAD', `字段 ${field} 不是合法的 base64url`);
  }
  const padded = normalized.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (normalized.length % 4)) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  } catch {
    throw new WebAuthnClientError('INVALID_PAYLOAD', `字段 ${field} 解码失败`);
  }
}

/**
 * 检测浏览器是否具备 WebAuthn 能力.
 *
 * @returns 支持返回 true; 不支持时界面应禁用注册与准入按钮.
 */
export function isWebAuthnSupported(): boolean {
  return typeof PublicKeyCredential === 'function';
}

/**
 * 断言当前页面处于安全上下文; WebAuthn 在非 HTTPS 且非 localhost 时不可用.
 *
 * @returns 无.
 * @throws {WebAuthnClientError} 非安全上下文时抛出, 原因是浏览器会直接拒绝 credential 调用.
 */
export function assertSecureContext(): void {
  if (!window.isSecureContext) {
    throw new WebAuthnClientError(
      'NOT_SECURE_CONTEXT',
      '当前页面不是安全上下文, 通行密钥只能在 HTTPS 或 localhost 下使用'
    );
  }
}

/**
 * 校验服务端下发的依赖方标识与页面部署口径.
 *
 * @param rpId 服务端下发的依赖方标识.
 * @returns 无.
 * @throws {WebAuthnClientError} 依赖方标识为空, 与 wuge.fun 不一致, 或页面不在 wuge.fun 域下时抛出.
 */
export function assertRpIdCompatible(rpId: string): void {
  if (rpId.length === 0) {
    throw new WebAuthnClientError('INVALID_PAYLOAD', '服务端未给出依赖方标识');
  }
  if (rpId !== WEB_RP_ID) {
    throw new WebAuthnClientError(
      'RP_ID_MISMATCH',
      `服务端下发的依赖方标识 ${rpId} 与本项目固定的 ${WEB_RP_ID} 不一致; 请按部署口径修正 runner 侧配置`
    );
  }
  const mode = classifyPageHost(window.location.hostname);
  if (mode !== 'deployment') {
    // 非部署域先给出域名层面提示, 比浏览器的 SecurityError 更能说明该改哪里
    throw new WebAuthnClientError('RP_ID_MISMATCH', describePageHostNotice(mode, window.location.hostname));
  }
  const hostname = window.location.hostname.toLowerCase();
  if (hostname === rpId || hostname.endsWith(`.${rpId}`)) {
    return;
  }
  throw new WebAuthnClientError(
    'RP_ID_MISMATCH',
    `依赖方标识 ${rpId} 与当前页面主机 ${hostname} 不匹配; 页面必须部署在 wuge.fun 或其子域下`
  );
}

/**
 * 把用户验证强度映射为 WebAuthn 选项值; 取值已由控制帧解析器收窄, 这里只做同义转发.
 *
 * @param value 已校验的强度值.
 * @returns 浏览器可直接使用的强度值.
 */
function toUserVerification(value: UserVerification): UserVerification {
  return value;
}

/**
 * 在设备内创建通行密钥, 并把公钥侧材料交给调用方.
 *
 * @param options 服务端下发的注册选项, 挑战与用户句柄必须是 base64url.
 * @returns 注册结果, 字段均为 base64url; 私钥不出认证器, 本函数无法读取.
 * @throws {WebAuthnClientError} 能力缺失, 安全上下文不符, 依赖方标识不匹配, 负载非法或认证器失败时抛出.
 */
export async function createPasskey(options: RegistrationOptionsPayload): Promise<RegistrationPayload> {
  if (!isWebAuthnSupported()) {
    throw new WebAuthnClientError('NOT_SUPPORTED', '当前浏览器不支持 WebAuthn');
  }
  assertSecureContext();
  assertRpIdCompatible(options.rpId);
  const publicKey: PublicKeyCredentialCreationOptions = {
    challenge: fromBase64Url(options.challenge, 'challenge'),
    rp: { id: options.rpId, name: options.rpName },
    user: {
      id: fromBase64Url(options.userId, 'userId'),
      name: options.userName,
      displayName: options.userDisplayName
    },
    pubKeyCredParams: PUB_KEY_CRED_PARAMS,
    timeout: options.timeoutMs,
    attestation: 'none', // 服务端只需要公钥做验签, 不索取可识别设备身份的证明
    excludeCredentials: options.excludeCredentialIds.map((id: string) => ({
      type: 'public-key',
      id: fromBase64Url(id, 'excludeCredentialIds')
    })),
    authenticatorSelection: {
      residentKey: 'discouraged', // 会话由 session_id 定位, 不需要常驻凭据, 也不做无用户名登录
      userVerification: toUserVerification(options.userVerification)
    }
  };
  let credential: Credential | null;
  try {
    credential = await navigator.credentials.create({ publicKey });
  } catch (error) {
    throw new WebAuthnClientError('CREDENTIAL_FAILED', describeCredentialError(error));
  }
  if (!(credential instanceof PublicKeyCredential)) {
    throw new WebAuthnClientError('CREDENTIAL_FAILED', '认证器未返回公钥凭据');
  }
  const response = credential.response;
  if (!(response instanceof AuthenticatorAttestationResponse)) {
    throw new WebAuthnClientError('CREDENTIAL_FAILED', '认证器返回的注册响应类型不符');
  }
  const transports = typeof response.getTransports === 'function' ? response.getTransports() : [];
  return {
    credentialId: toBase64Url(credential.rawId),
    clientDataJSON: toBase64Url(response.clientDataJSON),
    attestationObject: toBase64Url(response.attestationObject),
    transports
  };
}

/**
 * 在设备内生成断言, 由认证器用私钥签名; 本函数不接触私钥本身.
 *
 * @param options 服务端下发的断言挑战.
 * @returns 断言结果, 字段均为 base64url; userHandle 为空时省略.
 * @throws {WebAuthnClientError} 能力缺失, 安全上下文不符, 依赖方标识不匹配, 负载非法或用户取消时抛出.
 */
export async function createAssertion(options: AuthChallengePayload): Promise<AuthAssertionPayload> {
  if (!isWebAuthnSupported()) {
    throw new WebAuthnClientError('NOT_SUPPORTED', '当前浏览器不支持 WebAuthn');
  }
  assertSecureContext();
  assertRpIdCompatible(options.rpId);
  const publicKey: PublicKeyCredentialRequestOptions = {
    challenge: fromBase64Url(options.challenge, 'challenge'),
    rpId: options.rpId,
    timeout: options.timeoutMs,
    userVerification: toUserVerification(options.userVerification),
    allowCredentials: options.allowCredentialIds.map((id: string) => ({
      type: 'public-key',
      id: fromBase64Url(id, 'allowCredentialIds')
    }))
  };
  let credential: Credential | null;
  try {
    credential = await navigator.credentials.get({ publicKey });
  } catch (error) {
    throw new WebAuthnClientError('CREDENTIAL_FAILED', describeCredentialError(error));
  }
  if (!(credential instanceof PublicKeyCredential)) {
    throw new WebAuthnClientError('CREDENTIAL_FAILED', '认证器未返回公钥凭据');
  }
  const response = credential.response;
  if (!(response instanceof AuthenticatorAssertionResponse)) {
    throw new WebAuthnClientError('CREDENTIAL_FAILED', '认证器返回的断言响应类型不符');
  }
  const userHandle = response.userHandle;
  return {
    credentialId: toBase64Url(credential.rawId),
    authenticatorData: toBase64Url(response.authenticatorData),
    clientDataJSON: toBase64Url(response.clientDataJSON),
    signature: toBase64Url(response.signature),
    ...(userHandle === null ? {} : { userHandle: toBase64Url(userHandle) }) // 空句柄不写空串, 避免服务端把空串当有效值
  };
}

/**
 * 把认证器异常转换为面向用户的中文原因; 只保留错误名, 不拼接可能含敏感细节的原始消息.
 *
 * @param error 捕获到的异常, 类型未知.
 * @returns 中文原因; 已知取消场景给出明确说明.
 */
function describeCredentialError(error: unknown): string {
  const name = error instanceof DOMException ? error.name : 'UnknownError';
  if (name === 'NotAllowedError') {
    return '通行密钥操作被取消或超时; 请重试并在系统提示中确认';
  }
  if (name === 'SecurityError') {
    return '浏览器因安全策略拒绝了通行密钥操作; 请确认页面来源与依赖方标识一致';
  }
  if (name === 'InvalidStateError') {
    return '该设备已登记过同一凭据, 无需重复注册';
  }
  return `通行密钥操作失败(${name}); 请检查认证器是否可用`;
}
