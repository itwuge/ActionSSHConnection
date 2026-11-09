/**
 * 文件: main.ts
 * 所属目录: web/src/
 * 文件用途: 页面前端入口, 查询固定节点, 预填地址栏参数并启动会话控制器.
 * 架构定位: 前端层入口, 上游是 index.html 的脚本引用, 下游是 app-controller.ts, 依赖方向由入口指向控制器.
 * 核心功能: 节点存在性校验; 构造控制器; 读取 relay 与 session 查询参数; 页面卸载时释放资源.
 * 职责边界: 不建立连接, 不解析协议, 不渲染终端, 不读取或生成任何凭据.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 浏览器需支持 ES 模块打包产物与 WebSocket.
 * 依赖关系: 依赖 styles.css, app-controller.ts; 无下游调用方.
 */

import './styles.css'; // 副作用引入: 页面样式, 与 xterm 基础样式叠加

import { AppController } from './app-controller'; // 项目内模块: 会话控制器

import type { AppElements } from './app-controller'; // 项目内类型: 页面节点集合

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
 * 读取地址栏查询参数; 只接受中转地址与会话标识, 不读取任何凭据类参数.
 *
 * @param name 参数名.
 * @returns 参数值; 缺失时返回空串.
 */
function readQuery(name: string): string {
  return new URLSearchParams(window.location.search).get(name) ?? '';
}

// =========** 入口 =========**
const elements: AppElements = {
  form: requireElement('connect-form', HTMLFormElement, '连接表单'),
  relayInput: requireElement('relay-origin', HTMLInputElement, '中转地址输入框'),
  sessionInput: requireElement('session-id', HTMLInputElement, '会话标识输入框'),
  connectButton: requireElement('connect-button', HTMLButtonElement, '连接按钮'),
  disconnectButton: requireElement('disconnect-button', HTMLButtonElement, '断开按钮'),
  registerButton: requireElement('register-button', HTMLButtonElement, '注册按钮'),
  formMessage: requireElement('form-message', HTMLElement, '表单提示'),
  connectionStatus: requireElement('status-connection', HTMLElement, '连接状态'),
  pathStatus: requireElement('status-path', HTMLElement, '路径状态'),
  admissionStatus: requireElement('status-admission', HTMLElement, '准入状态'),
  warningLine: requireElement('warning-line', HTMLElement, '警告行'),
  terminalContainer: requireElement('terminal', HTMLElement, '终端容器'),
  notice: requireElement('notice', HTMLElement, '断线提示'),
  noticeText: requireElement('notice-text', HTMLElement, '断线提示文本'),
  noticeAction: requireElement('notice-action', HTMLButtonElement, '重连按钮')
};

const controller = new AppController(elements);
controller.prefill(readQuery('relay'), readQuery('session'));
window.addEventListener('beforeunload', () => {
  controller.dispose();
});
