/**
 * 文件: app-controller.ts
 * 所属目录: web/src/
 * 文件用途: 编排连接串展示, 首次登记引导, 中继连接与准入状态机, 把结果映射为终端可用性与可读提示.
 * 架构定位: 前端层控制模块, 上游是 main.ts, 下游是 relay-client.ts, terminal-view.ts, admission-client.ts 与本地凭据记录, 依赖方向由入口指向能力模块.
 * 核心功能: 自动连接已登记设备; 首次进入引导注册; 连接与重试; 帧分流; 准入状态渲染; 复制连接串.
 * 职责边界: 不生成挑战, 不验签, 不做访问判定, 不保存私钥; 本机只记录公开凭据标识; 网页通道固定走中继.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 浏览器需支持 WebSocket, WebAuthn, ResizeObserver 与 localStorage.
 * 依赖关系: 依赖 protocol/frames.ts, protocol/control.ts, transport/relay-client.ts, terminal/terminal-view.ts, auth/admission-client.ts, storage/credential-store.ts; 被 main.ts 调用.
 */

import { classifyPageHost, describePageHostNotice } from './config'; // 项目内模块: 部署域名判定与提示
import { FRAME_TYPE } from './protocol/frames'; // 项目内模块: 帧类型编号
import { encodeJson } from './protocol/control'; // 项目内模块: 负载编码
import { normalizeRelayOrigin, RelayClient } from './transport/relay-client'; // 项目内模块: 中继连接
import { TerminalView } from './terminal/terminal-view'; // 项目内模块: 终端视图
import { AdmissionClient } from './auth/admission-client'; // 项目内模块: 准入状态机
import { isWebAuthnSupported } from './auth/webauthn-client'; // 项目内模块: 浏览器能力检测
import { loadStoredCredential, saveStoredCredential, clearStoredCredential } from './storage/credential-store'; // 项目内模块: 本机凭据标识

import type { PageHostMode } from './config'; // 项目内类型: 页面域名类别
import type { Frame } from './protocol/frames'; // 项目内类型: 帧结构
import type { AdmissionSnapshot } from './auth/admission-client'; // 项目内类型: 准入快照
import type { AdmissionIntent } from './protocol/control'; // 项目内类型: 准入意图
import type { StoredCredential } from './storage/credential-store'; // 项目内类型: 本机记录

// =========** 类型 =========**
/**
 * 页面节点集合; 由 main.ts 查询后注入, 控制器不直接访问 document.
 */
export interface AppElements {
  /** 只读连接串输入框. */
  connectStringInput: HTMLInputElement;
  /** 复制连接串按钮. */
  copyButton: HTMLButtonElement;
  /** 顶部状态文本. */
  statusLine: HTMLElement;
  /** 常驻提示与复制反馈. */
  messageLine: HTMLElement;
  /** 终端挂载节点. */
  terminalContainer: HTMLElement;
  /** 首次进入的登记引导层. */
  gate: HTMLElement;
  /** 引导层上的注册按钮. */
  gateRegisterButton: HTMLButtonElement;
  /** 引导层上的直接进入按钮. */
  gateAssertButton: HTMLButtonElement;
  /** 错误与断线浮层. */
  notice: HTMLElement;
  /** 浮层文本. */
  noticeText: HTMLElement;
  /** 浮层重试按钮. */
  noticeAction: HTMLButtonElement;
}

// =========** 常量 =========**
/** 真实验签方标识; 服务端由 runner 侧进程验签时必须填该值. */
const REAL_VERIFIER = 'runner';

/** 表单提示最长保留 300 字, 防止异常消息撑破布局. */
const MAX_MESSAGE_LENGTH = 300;

// =========** 类 =========**
/**
 * 页面会话控制器.
 *
 * 方法一览:
 *   start() -> void: 按本机登记情况自动进入或展示登记引导.
 *   dispose() -> void: 关闭连接并释放终端.
 */
export class AppController {
  private readonly elements: AppElements;

  private readonly sessionId: string;

  private readonly relayOrigin: string;

  private readonly hostMode: PageHostMode;

  private readonly hostNotice: string;

  private readonly terminal: TerminalView;

  private readonly admission: AdmissionClient;

  private stored: StoredCredential | null;

  private relay: RelayClient | null = null;

  private lastIntent: AdmissionIntent = 'assert';

  /**
   * @param elements 页面节点集合, 每个节点都必须存在.
   * @param sessionId 连接串中的会话标识; 空串表示地址不合法.
   * @param relayOrigin 已确定的中继源地址, 部署时与页面同域.
   */
  constructor(elements: AppElements, sessionId: string, relayOrigin: string) {
    this.elements = elements;
    this.sessionId = sessionId;
    this.relayOrigin = relayOrigin;
    this.hostMode = classifyPageHost(window.location.hostname);
    this.hostNotice = describePageHostNotice(this.hostMode, window.location.hostname);
    this.stored = this.hostMode === 'deployment' ? loadStoredCredential() : null;
    this.terminal = new TerminalView(elements.terminalContainer, {
      onInput: (bytes: Uint8Array) => {
        this.handleTerminalInput(bytes);
      },
      onResize: (cols: number, rows: number) => {
        this.handleTerminalResize(cols, rows);
      }
    });
    this.admission = new AdmissionClient(
      (snapshot: AdmissionSnapshot) => {
        this.renderAdmission(snapshot);
      },
      (type, payload) => {
        this.sendFrame(type, payload);
      },
      (credentialId: string) => {
        this.handleRegistered(credentialId);
      }
    );
    this.init();
  }

  /**
   * 展示连接串, 按本机登记情况自动进入或给出一次性登记引导.
   *
   * @returns 无.
   */
  start(): void {
    if (this.sessionId.length === 0) {
      this.setStatus('缺少会话标识', 'failed');
      this.showNotice('缺少会话标识. 连接串应形如 https://wuge.fun/t/会话ID; 请向发起者索取完整连接串.', false);
      return;
    }
    if (this.stored !== null) {
      this.setStatus('正在进入会话', 'pending');
      this.connect('assert');
      return;
    }
    this.setStatus('首次使用');
    this.showGate();
  }

  /**
   * 释放连接与终端; 页面卸载时调用, 重复调用安全.
   *
   * @returns 无.
   */
  dispose(): void {
    this.admission.dispose();
    this.relay?.close(1000, 'page-unload');
    this.relay = null;
    this.terminal.dispose();
  }

  /**
   * 绑定复制, 引导与重试事件, 并写入连接串.
   *
   * @returns 无.
   */
  private init(): void {
    this.elements.connectStringInput.value =
      this.sessionId.length > 0
        ? `${window.location.origin}/t/${this.sessionId}`
        : `${window.location.origin}/t/`;
    this.elements.copyButton.addEventListener('click', () => {
      void this.copyConnectString();
    });
    this.elements.gateRegisterButton.addEventListener('click', () => {
      this.connect('register');
    });
    this.elements.gateAssertButton.addEventListener('click', () => {
      this.connect('assert');
    });
    this.elements.noticeAction.addEventListener('click', () => {
      this.elements.notice.hidden = true;
      this.connect(this.lastIntent);
    });
    const canRegister = isWebAuthnSupported() && this.hostMode === 'deployment';
    this.elements.gateRegisterButton.disabled = !canRegister;
    this.setStatus('未连接');
    if (this.hostNotice.length > 0) {
      this.showMessage(this.hostNotice);
    }
  }

  /**
   * 复制连接串; 剪贴板不可用时选中文本让用户手动复制.
   *
   * @returns 异步完成.
   */
  private async copyConnectString(): Promise<void> {
    const value = this.elements.connectStringInput.value;
    try {
      await navigator.clipboard.writeText(value);
      this.showMessage('已复制连接串.');
    } catch {
      this.elements.connectStringInput.focus();
      this.elements.connectStringInput.select();
      this.showMessage('复制失败, 请手动复制选中的连接串.');
    }
  }

  /**
   * 发起连接; 注册与断言共用同一条 WS, 只是首帧意图不同.
   *
   * @param intent register 表示首次登记, assert 表示已登记设备直接进入.
   * @returns 无.
   */
  private connect(intent: AdmissionIntent): void {
    if (this.sessionId.length === 0) {
      return;
    }
    this.lastIntent = intent;
    this.elements.gate.hidden = true;
    this.elements.notice.hidden = true;
    this.terminal.reset();
    this.terminal.setInputEnabled(false);
    this.setStatus('连接中', 'pending');
    let origin: string;
    try {
      origin = normalizeRelayOrigin(this.relayOrigin);
    } catch (error) {
      this.setStatus('无法连接', 'failed');
      this.showNotice(error instanceof Error ? error.message : '中转地址不合法.');
      return;
    }
    this.relay?.close(1000, 'reconnect');
    const client = new RelayClient({
      onOpen: () => {
        this.handleOpen();
      },
      onFrame: (frame: Frame) => {
        this.handleFrame(frame);
      },
      onClose: (event: CloseEvent) => {
        this.handleClose(event);
      },
      onError: (message: string) => {
        this.setStatus('无法连接', 'failed');
        this.showNotice(message);
      }
    });
    this.relay = client;
    try {
      client.connect(origin, this.sessionId);
    } catch (error) {
      this.setStatus('无法连接', 'failed');
      this.showNotice(error instanceof Error ? error.message : '连接失败.');
      this.relay = null;
    }
  }

  /**
   * 连接打开后启动准入; 已登记设备带上凭据标识缩小选择范围.
   *
   * @returns 无.
   */
  private handleOpen(): void {
    this.setStatus('正在验证设备', 'pending');
    try {
      this.admission.begin(this.lastIntent, this.stored?.credentialId ?? null);
    } catch {
      this.setStatus('无法进入', 'failed');
      this.showNotice('无法发起设备验证, 请重试.');
    }
  }

  /**
   * 按帧类型分流; 终端数据只在准入通过后写入屏幕.
   *
   * @param frame 已解码帧.
   * @returns 无.
   */
  private handleFrame(frame: Frame): void {
    if (frame.type === FRAME_TYPE.terminalData) {
      if (this.admission.isAdmitted) {
        this.terminal.write(frame.payload);
      }
      return;
    }
    if (frame.type === FRAME_TYPE.resize) {
      return;
    }
    void this.admission.handleFrame(frame);
  }

  /**
   * 连接关闭; 给出可读原因, 不把关闭码作为唯一信息.
   *
   * @param event 关闭事件.
   * @returns 无.
   */
  private handleClose(event: CloseEvent): void {
    this.relay = null;
    this.admission.reset();
    this.terminal.setInputEnabled(false);
    this.setStatus('已断开', 'failed');
    this.showNotice(describeClose(event));
  }

  /**
   * 渲染准入状态与终端可用性.
   *
   * @param snapshot 准入快照.
   * @returns 无.
   */
  private renderAdmission(snapshot: AdmissionSnapshot): void {
    if (snapshot.phase === 'admitted') {
      this.setStatus(snapshot.verifier === REAL_VERIFIER ? '已连接' : '已连接(模拟环境, 未验签)', 'admitted');
      this.elements.notice.hidden = true;
      this.elements.gate.hidden = true;
      this.terminal.setInputEnabled(true);
      this.terminal.focus();
      return;
    }
    this.terminal.setInputEnabled(false);
    if (snapshot.phase === 'awaiting-challenge') {
      this.setStatus('正在验证设备', 'pending');
      return;
    }
    if (snapshot.phase === 'awaiting-result') {
      this.setStatus(snapshot.detail, 'pending');
      return;
    }
    if (snapshot.phase === 'idle') {
      this.setStatus('未连接');
      return;
    }
    if (snapshot.phase === 'denied' && snapshot.failureReason === 'CREDENTIAL_NOT_ALLOWED' && this.hostMode === 'deployment') {
      // 允许清单不含本机凭据时清掉旧记录, 回到登记引导, 避免卡在无法恢复的提示上
      clearStoredCredential();
      this.stored = null;
      this.setStatus('需要重新登记本设备', 'failed');
      this.showMessage('本机登记的凭据已不在允许清单内, 请重新注册本设备.');
      this.showGate();
      return;
    }
    this.setStatus('无法进入', 'failed');
    this.showNotice(snapshot.detail);
  }

  /**
   * 注册成功后记录公开凭据标识; 只在部署域记录, 避免本地调试留下无效记录.
   *
   * @param credentialId 认证器返回的凭据标识.
   * @returns 无.
   */
  private handleRegistered(credentialId: string): void {
    if (this.hostMode !== 'deployment') {
      return;
    }
    if (saveStoredCredential(credentialId)) {
      this.stored = { credentialId, registeredAt: new Date().toISOString() };
      this.showMessage('已登记本设备; 下次打开同类连接串会直接进入.');
      return;
    }
    this.showMessage('本浏览器无法记住登记; 下次打开仍需重新认证.');
  }

  /**
   * 终端输入只在准入通过后上送.
   *
   * @param bytes 用户输入编码后的 UTF-8 字节.
   * @returns 无.
   */
  private handleTerminalInput(bytes: Uint8Array): void {
    if (!this.admission.isAdmitted || this.relay === null || !this.relay.isOpen) {
      return;
    }
    try {
      this.relay.send(FRAME_TYPE.terminalData, bytes);
    } catch {
      // 发送失败通常意味着连接刚断开, 由 close 事件统一提示
    }
  }

  /**
   * 上送终端行列数; 未连接时丢弃.
   *
   * @param cols 列数, 正整数.
   * @param rows 行数, 正整数.
   * @returns 无.
   */
  private handleTerminalResize(cols: number, rows: number): void {
    if (this.relay === null || !this.relay.isOpen) {
      return;
    }
    try {
      this.relay.send(FRAME_TYPE.resize, encodeJson({ cols, rows }));
    } catch {
      // 尺寸同步失败不影响本地渲染, 下一次尺寸变化会重试
    }
  }

  /**
   * 发送控制帧; 由准入状态机注入.
   *
   * @param type 帧类型.
   * @param payload 负载字节.
   * @returns 无.
   * @throws {Error} 连接未打开时抛出, 由准入状态机转为 error 状态.
   */
  private sendFrame(type: Frame['type'], payload: Uint8Array): void {
    if (this.relay === null || !this.relay.isOpen) {
      throw new Error('连接未打开, 准入帧未发送');
    }
    this.relay.send(type, payload);
  }

  /**
   * 显示首次进入的登记引导.
   *
   * @returns 无.
   */
  private showGate(): void {
    this.elements.gate.hidden = false;
    this.elements.gateRegisterButton.disabled = !isWebAuthnSupported() || this.hostMode !== 'deployment';
  }

  /**
   * 写入状态行, 并同步配色状态.
   *
   * @param text 面向用户的状态文本.
   * @param state 状态类别, 仅用于配色.
   * @returns 无.
   */
  private setStatus(text: string, state: 'idle' | 'pending' | 'admitted' | 'failed' = 'idle'): void {
    this.elements.statusLine.textContent = text;
    this.elements.statusLine.dataset['state'] = state;
  }

  /**
   * 展示错误或断线提示.
   *
   * @param message 面向用户的说明.
   * @param retryable 是否给出重新连接入口; 地址缺少会话标识等无法重试的情况传 false.
   * @returns 无.
   */
  private showNotice(message: string, retryable = true): void {
    this.elements.noticeText.textContent = message.slice(0, MAX_MESSAGE_LENGTH);
    this.elements.noticeAction.hidden = !retryable;
    this.elements.notice.hidden = false;
  }

  /**
   * 显示提示行; 过长内容截断.
   *
   * @param message 面向用户的提示.
   * @returns 无.
   */
  private showMessage(message: string): void {
    this.elements.messageLine.textContent = message.slice(0, MAX_MESSAGE_LENGTH);
  }
}

// =========** 函数 =========**
/**
 * 把关闭事件转为可读提示; 只识别协议约定的原因标识, 不回显自由文本.
 *
 * @param event 关闭事件, 原因可能为空.
 * @returns 面向用户的提示.
 */
function describeClose(event: CloseEvent): string {
  if (event.reason.includes('UNKNOWN_SESSION')) {
    return '会话不存在或已结束. 请向发起者索取新的连接串.';
  }
  if (event.reason.includes('ROUTE_GONE')) {
    return '会话已结束, 连接已回收. 请重新发起会话获取新的连接串.';
  }
  if (event.code === 1000) {
    return '连接已关闭.';
  }
  return '连接已断开, 请检查网络后重试.';
}
