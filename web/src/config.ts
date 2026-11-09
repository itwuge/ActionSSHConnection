/**
 * 文件: config.ts
 * 所属目录: web/src/
 * 文件用途: 集中声明网页通道的部署域名与通行密钥依赖方标识, 并提供页面域名判定与提示文案.
 * 架构定位: 前端层配置模块, 上游是页面入口与认证模块, 下游无依赖, 只导出常量与纯函数.
 * 核心功能: 固定依赖方标识 wuge.fun; 判定页面是否部署在该域; 区分本地调试域与外来域; 生成明确提示.
 * 职责边界: 不做 WebAuthn 调用, 不做连接管理, 不改写服务端下发的挑战; 仅提供判定依据与文案.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 浏览器环境.
 * 依赖关系: 无外部依赖; 被 webauthn-client.ts 与 app-controller.ts 调用.
 */

// =========** 常量 =========**
/**
 * 通行密钥依赖方标识, 按 M01 决定固定为 wuge.fun; 页面部署在该域或其子域下.
 * 不随部署环境改名, 避免已登记的通行密钥失效.
 */
export const WEB_RP_ID = 'wuge.fun';

/**
 * 本地调试主机清单; 这些主机只用于配合本地模拟中继验证界面, 不能完成真实准入.
 * 保留 [::1] 是因为浏览器对 IPv6 回环地址的 hostname 带方括号.
 */
const LOCAL_DEBUG_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

// =========** 类型 =========**
/**
 * 页面域名类别; 用联合类型而不是布尔值, 因为本地调试与外来域需要不同提示.
 */
export type PageHostMode = 'deployment' | 'local' | 'foreign';

// =========** 函数 =========**
/**
 * 判定页面域名类别.
 *
 * @param hostname 页面主机名, 通常取自 window.location.hostname, 大小写不敏感.
 * @returns deployment 表示 wuge.fun 或其子域; local 表示本机调试地址; foreign 表示其他域名.
 */
export function classifyPageHost(hostname: string): PageHostMode {
  const normalized = hostname.toLowerCase();
  if (normalized === WEB_RP_ID || normalized.endsWith(`.${WEB_RP_ID}`)) {
    return 'deployment';
  }
  if (LOCAL_DEBUG_HOSTS.has(normalized)) {
    return 'local';
  }
  return 'foreign';
}

/**
 * 生成页面域名提示.
 *
 * @param mode 页面域名类别.
 * @param hostname 页面主机名, 仅用于外来域提示, 由调用方保证来自 location.
 * @returns deployment 返回空串; local 与 foreign 返回明确的中文提示.
 */
export function describePageHostNotice(mode: PageHostMode, hostname: string): string {
  if (mode === 'deployment') {
    return '';
  }
  if (mode === 'local') {
    return '本地调试环境: 仅用于界面验证, 无法完成真实准入.';
  }
  return `请通过 wuge.fun 或其子域打开本页; 当前域名 ${hostname} 无法使用通行密钥.`;
}
