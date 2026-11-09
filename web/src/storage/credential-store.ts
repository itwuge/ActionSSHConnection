/**
 * 文件: credential-store.ts
 * 所属目录: web/src/storage/
 * 文件用途: 在本机记录已登记的通行密钥凭据标识, 用于下次打开同类连接串时直接发起断言.
 * 架构定位: 前端层本地存储模块, 上游是 app-controller.ts 与 admission-client.ts 的回调, 下游是浏览器 localStorage.
 * 核心功能: 读取与校验已存记录; 注册成功后写入凭据标识; 提供清除入口.
 * 职责边界: 只保存公开的凭据标识与登记时间, 不保存私钥, 不保存断言, 不保存任何可用于直接登录的凭据;
 *           凭据标识单独泄露不能完成认证, 仍需设备内私钥签名.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 浏览器需支持 localStorage; 不可用时按未登记处理.
 * 依赖关系: 依赖 config.ts 的依赖方标识; 被 app-controller.ts 调用.
 */

import { WEB_RP_ID } from '../config'; // 项目内模块: 依赖方标识

// =========** 常量 =========**
/**
 * 存储键按依赖方标识分域, 避免不同部署口径共用同一条记录.
 */
const STORAGE_KEY = `action-ssh-connection.webauthn.${WEB_RP_ID}.v1`;

/** 凭据标识合法字符与长度; 与 base64url 输出一致. */
const CREDENTIAL_ID_PATTERN = /^[A-Za-z0-9_-]{8,1024}$/;

// =========** 类型 =========**
/**
 * 已登记凭据的公开信息.
 */
export interface StoredCredential {
  /** 凭据标识, base64url; 公开信息, 不能单独用于认证. */
  credentialId: string;
  /** 登记时间, ISO 8601 字符串. */
  registeredAt: string;
}

// =========** 函数 =========**
/**
 * 读取本机已登记凭据.
 *
 * @returns 有效记录; 未登记, 记录损坏或存储不可用时返回 null.
 */
export function loadStoredCredential(): StoredCredential | null {
  let raw: string | null;
  try {
    raw = window.localStorage.getItem(STORAGE_KEY);
  } catch {
    return null; // 隐私模式或存储被禁用时按未登记处理, 不阻断页面
  }
  if (raw === null) {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null) {
      return null;
    }
    const record = parsed as Record<string, unknown>;
    const credentialId = record['credentialId'];
    const registeredAt = record['registeredAt'];
    if (typeof credentialId !== 'string' || !CREDENTIAL_ID_PATTERN.test(credentialId)) {
      return null;
    }
    if (typeof registeredAt !== 'string' || registeredAt.length === 0) {
      return null;
    }
    return { credentialId, registeredAt };
  } catch {
    return null;
  }
}

/**
 * 登记成功后写入凭据标识.
 *
 * @param credentialId 凭据标识, base64url; 必须是认证器返回的 rawId.
 * @returns 写入成功返回 true; 存储不可用或标识非法返回 false, 此时页面仍可继续使用本次会话.
 */
export function saveStoredCredential(credentialId: string): boolean {
  if (!CREDENTIAL_ID_PATTERN.test(credentialId)) {
    return false;
  }
  const record: StoredCredential = {
    credentialId,
    registeredAt: new Date().toISOString()
  };
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(record));
    return true;
  } catch {
    return false;
  }
}

/**
 * 清除本机登记记录; 供用户注销设备或凭据失效时使用.
 *
 * @returns 无.
 */
export function clearStoredCredential(): void {
  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // 存储不可用时没有可清除的内容
  }
}
