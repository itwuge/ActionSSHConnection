/**
 * 文件: main.ts
 * 所属目录: web/src/
 * 文件用途: 页面前端入口, 从路径 /t/<会话ID> 取出会话标识, 确定中继源地址并启动会话控制器.
 * 架构定位: 前端层入口, 上游是 index.html 的脚本引用, 下游是 app-controller.ts, 依赖方向由入口指向控制器.
 * 核心功能: 节点存在性校验; 路径解析; 中继地址推导; 构造控制器; 页面卸载时释放资源.
 * 职责边界: 不建立连接, 不解析协议, 不渲染终端, 不读取或生成任何凭据; 查询参数只在本地调试域用于覆盖中继地址.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 浏览器需支持 ES 模块打包产物与 WebSocket.
 * 依赖关系: 依赖 styles.css, app-controller.ts; 无下游调用方.
 */

import './styles.css'; // 副作用引入: 页面样式, 与 xterm 基础样式叠加

import { AppController } from './app-controller'; // 项目内模块: 会话控制器

import type { AppElements } from './app-controller'; // 项目内类型: 页面节点集合

// =========** 常量 =========**
/** 路径形态与 tmate 一致: /t/<会话ID>; 会话标识允许字符与中继路径约束相同. */
const SESSION_PATH_PATTERN = /^\/t\/([A-Za-z0-9][A-Za-z0-9_-]{0,127})\/?$/;

/** 本地调试主机; 只有这些主机允许用查询参数指定中继地址. */
const LOCAL_DEBUG_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

// =========** 函数 =========**
/**
 * 按 id 查询节点, 并校验实际标签类型; 页面结构改动导致缺失时直接失败, 避免后续空引用.
 *
 * @param id 节点 id, 不含井号.
 * @param expected 期望的 DOM 构造器, 例如 HTMLInputElement.
 * @param label 面向开发者的节点说明.
 * @returns 类型收窄后的节点.
 * @throws {Error} 节点缺失或标签类型不符时抛出.
 */
function requireElement<T extends HTMLElement>(id: string, expected: new () => T, label: string): T {
  const element = document.getElementById(id);
  if (!(element instanceof expected)) {
    throw new Error(`页面缺少${label}节点 #${id}`);
  }
  return element;
}

/**
 * 从路径中取出会话标识; 地址形态与 tmate 一致.
 *
 * @param pathname 页面路径, 例如 /t/AbC123.
 * @returns 会话标识; 路径不符时返回空串, 由控制器给出可读提示.
 */
function parseSessionId(pathname: string): string {
  let decoded: string;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return '';
  }
  return SESSION_PATH_PATTERN.exec(decoded)?.[1] ?? '';
}

/**
 * 推导中继源地址: 部署口径下与页面同域; 本地调试域允许用 ?relay= 指向模拟中继.
 *
 * @returns 形如 wss://wuge.fun 或 ws://127.0.0.1:8787 的源地址.
 */
function resolveRelayOrigin(): string {
  const hostname = window.location.hostname.toLowerCase();
  if (LOCAL_DEBUG_HOSTS.has(hostname)) {
    const override = new URLSearchParams(window.location.search).get('relay') ?? '';
    if (override.length > 0) {
      return override;
    }
  }
  const scheme = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${window.location.host}`;
}

// =========** 入口 =========**
const elements: AppElements = {
  connectStringInput: requireElement('connect-string', HTMLInputElement, '连接串'),
  copyButton: requireElement('copy-connect-string', HTMLButtonElement, '复制按钮'),
  statusLine: requireElement('status-line', HTMLElement, '状态行'),
  messageLine: requireElement('message-line', HTMLElement, '提示行'),
  terminalContainer: requireElement('terminal', HTMLElement, '终端容器'),
  gate: requireElement('gate', HTMLElement, '登记引导层'),
  gateRegisterButton: requireElement('gate-register', HTMLButtonElement, '注册按钮'),
  gateAssertButton: requireElement('gate-enter', HTMLButtonElement, '直接进入按钮'),
  notice: requireElement('notice', HTMLElement, '提示浮层'),
  noticeText: requireElement('notice-text', HTMLElement, '提示浮层文本'),
  noticeAction: requireElement('notice-action', HTMLButtonElement, '重新连接按钮')
};

const controller = new AppController(elements, parseSessionId(window.location.pathname), resolveRelayOrigin());
controller.start();
window.addEventListener('beforeunload', () => {
  controller.dispose();
});
