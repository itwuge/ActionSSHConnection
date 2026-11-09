/**
 * 文件: app-controller.ts
 * 所属目录: web/src/
 * 文件用途: 编排终端视图, 中继连接与准入状态机, 把连接事件映射为页面状态与终端可用性.
 * 架构定位: 前端层控制模块, 上游是 main.ts, 下游是 relay-client.ts, terminal-view.ts 与 admission-client.ts, 依赖方向由入口指向能力模块.
 * 核心功能: 连接与断开; 帧分流; 准入状态渲染; 未准入时锁定输入; 断线提示与重连; 尺寸变化上送.
 * 职责边界: 不生成挑战, 不验签, 不做访问判定, 不在页面展示任何凭据; 网页通道固定走中继, 不实现浏览器打洞.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 浏览器需支持 WebSocket, WebAuthn 与 ResizeObserver.
 * 依赖关系: 依赖 protocol/frames.ts, protocol/control.ts, transport/relay-client.ts, terminal/terminal-view.ts, auth/admission-client.ts; 被 main.ts 调用.
 */

import { classifyPageHost, describePageHostNotice } from './config'; // 项目内模块: 部署域名判定与提示
import { FRAME_TYPE } from './protocol/frames'; // 项目内模块: 帧类型编号
import { encodeJson } from './protocol/control'; // 项目内模块: 负载编码
import { normalizeRelayOrigin, RelayAddressError, RelayClient } from './transport/relay-client'; // 项目内模块: 中继连接与地址校验
import { TerminalView } from './terminal/terminal-view'; // 项目内模块: 终端视图
import { AdmissionClient } from './auth/admission-client'; // 项目内模块: 准入状态机
import { isWebAuthnSupported } from './auth/webauthn-client'; // 项目内模块: 浏览器能力检测

import type { PageHostMode } from './config'; // 项目内类型: 页面域名类别
import type { Frame } from './protocol/frames'; // 项目内类型: 帧结构
import type { AdmissionSnapshot } from './auth/admission-client'; // 项目内类型: 准入快照

// =========** 类型 =========**
/**
 * 页面节点集合; 由 main.ts 查询后注入, 控制器不直接访问 document.
 */
export interface AppElements {
  /** 连接表单, 提交即发起连接. */
  form: HTMLFormElement;
  /** 中转地址输入框. */
  relayInput: HTMLInputElement;
  /** 会话标识输入框. */
  sessionInput: HTMLInputElement;
  /** 连接按钮. */
  connectButton: HTMLButtonElement;
  /** 断开按钮. */
  disconnectButton: HTMLButtonElement;
  /** 注册通行密钥按钮. */
  registerButton: HTMLButtonElement;
  /** 表单级错误提示. */
  formMessage: HTMLElement;
  /** 连接状态文本. */
  connectionStatus: HTMLElement;
  /** 当前路径文本. */
  pathStatus: HTMLElement;
  /** 准入状态文本. */
  admissionStatus: HTMLElement;
  /** 模拟环境或降级提示行. */
  warningLine: HTMLElement;
  /** 终端挂载节点. */
  terminalContainer: HTMLElement;
  /** 断线提示浮层. */
  notice: HTMLElement;
  /** 断线提示文本. */
  noticeText: HTMLElement;
  /** 断线提示上的重连按钮. */
  noticeAction: HTMLButtonElement;
}

// =========** 常量 =========**
/** 真实验签方标识; 服务端由 runner 侧进程验签时必须填该值. */
const REAL_VERIFIER = 'runner';

/** 固定用户可见提示: 网页通道本期只走中继, 不宣称直连. */
const PATH_RELAY_LABEL = '中继转发(relay)';

/** 未连接时的路径占位. */
const PATH_NONE_LABEL = '未连接';

/** 表单提示最长保留 300 字, 防止异常消息撑破布局. */
const MAX_MESSAGE_LENGTH = 300;

// =========** 类 =========**
/**
 * 页面会话控制器.
 *
 * 方法一览:
 *   init() -> void: 创建终端并绑定控件事件.
 *   prefill(relay, session) -> void: 用地址栏参数预填表单, 参数不含凭据.
 *   dispose() -> void: 关闭连接并释放终端.
 */
export class AppController {
  private readonly elements: AppElements;

  private readonly terminal: TerminalView;

  private readonly admission: AdmissionClient;

  private readonly hostMode: PageHostMode;

  private readonly hostNotice: string;

  private relay: RelayClient | null = null;

  private userClosed = false;

  /**
   * @param elements 页面节点集合, 每个节点都必须存在.
   */
  constructor(elements: AppElements) {
    this.elements = elements;
    this.hostMode = classifyPageHost(window.location.hostname);
    this.hostNotice = describePageHostNotice(this.hostMode, window.location.hostname);
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
      }
    );
    this.init();
  }

  /**
   * 绑定表单, 按钮与断线提示事件.
   *
   * @returns 无.
   */
  init(): void {
    this.elements.form.addEventListener('submit', (event: SubmitEvent) => {
      event.preventDefault();
      this.connect();
    });
    this.elements.disconnectButton.addEventListener('click', () => {
      this.disconnect();
    });
    this.elements.registerButton.addEventListener('click', () => {
      this.beginRegistration();
    });
    this.elements.noticeAction.addEventListener('click', () => {
      this.elements.notice.hidden = true;
      this.connect();
    });
    this.elements.registerButton.disabled = !isWebAuthnSupported() || this.hostMode !== 'deployment';
    this.elements.disconnectButton.disabled = true;
    this.elements.pathStatus.textContent = PATH_NONE_LABEL;
    this.elements.connectionStatus.textContent = '未连接';
    this.elements.admissionStatus.textContent = '未开始';
    this.renderWarning('');
    this.terminal.writeln('网页终端已就绪: 填写中转地址与会话标识后连接; 网页通道固定走中继.');
    if (this.hostNotice.length > 0) {
      this.showFormMessage(this.hostNotice);
    }
  }

  /**
   * 预填表单; 只接受中转地址与会话标识, 地址栏不得出现任何凭据.
   *
   * @param relay 中转源地址, 空串表示不预填.
   * @param session 会话标识, 空串表示不预填.
   * @returns 无.
   */
  prefill(relay: string, session: string): void {
    if (relay.length > 0 && relay.length <= 200) {
      this.elements.relayInput.value = relay;
    }
    if (session.length > 0 && session.length <= 128) {
      this.elements.sessionInput.value = session;
    }
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
   * 发起连接; 已有连接先关闭.
   *
   * @returns 无; 校验失败写表单提示.
   */
  private connect(): void {
    this.clearFormMessage();
    this.userClosed = false;
    let origin: string;
    try {
      origin = normalizeRelayOrigin(this.elements.relayInput.value);
    } catch (error) {
      this.showFormMessage(error instanceof RelayAddressError ? error.message : '中转地址不合法');
      return;
    }
    const sessionId = this.elements.sessionInput.value.trim();
    if (sessionId.length === 0) {
      this.showFormMessage('请填写会话标识, 可从会话日志的 session_id 字段取得');
      return;
    }
    this.relay?.close(1000, 'reconnect');
    this.terminal.reset();
    this.terminal.setInputEnabled(false);
    this.elements.notice.hidden = true;
    this.renderWarning('');
    this.admission.reset();
    this.elements.connectionStatus.textContent = '连接中';
    this.elements.pathStatus.textContent = PATH_NONE_LABEL;
    this.setButtonsConnected(false);
    this.terminal.writeln('正在连接中转...');
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
        this.showFormMessage(message);
      }
    });
    this.relay = client;
    try {
      client.connect(origin, sessionId);
    } catch (error) {
      this.showFormMessage(error instanceof Error ? error.message : '连接失败');
      this.relay = null;
      this.setButtonsConnected(false);
    }
  }

  /**
   * 主动断开连接; 不丢弃终端内容, 便于用户回看最后输出.
   *
   * @returns 无.
   */
  private disconnect(): void {
    this.userClosed = true;
    this.admission.reset();
    this.terminal.setInputEnabled(false);
    this.relay?.close(1000, 'client-close');
    this.elements.connectionStatus.textContent = '已断开';
    this.elements.pathStatus.textContent = PATH_NONE_LABEL;
    this.setButtonsConnected(false);
  }

  /**
   * 发起通行密钥注册; 注册选项必须由服务端下发, 当前实现存在与否见对接说明.
   *
   * @returns 无.
   */
  private beginRegistration(): void {
    if (this.hostMode !== 'deployment') {
      this.showFormMessage(this.hostNotice);
      return;
    }
    if (!isWebAuthnSupported()) {
      this.showFormMessage('当前浏览器不支持 WebAuthn, 无法注册通行密钥');
      return;
    }
    if (this.relay === null || !this.relay.isOpen) {
      this.showFormMessage('注册通行密钥需要先连接会话, 由 runner 侧下发注册选项');
      return;
    }
    this.elements.notice.hidden = true;
    try {
      this.admission.begin('register');
    } catch (error) {
      this.showFormMessage(error instanceof Error ? error.message : '注册请求发送失败');
    }
  }

  /**
   * 连接打开后启动准入流程; 认证未通过前终端保持锁定.
   *
   * @returns 无.
   */
  private handleOpen(): void {
    this.elements.connectionStatus.textContent = '已连接';
    this.elements.pathStatus.textContent = PATH_RELAY_LABEL;
    this.setButtonsConnected(true);
    this.terminal.writeln('已连接中转, 等待 runner 侧准入挑战...');
    try {
      this.admission.begin('assert');
    } catch (error) {
      this.showFormMessage(error instanceof Error ? error.message : '准入请求发送失败');
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
      return; // 尺寸以浏览器为准, 服务端下发的尺寸帧不作为指令执行
    }
    void this.admission.handleFrame(frame);
  }

  /**
   * 连接关闭; 依据关闭原因给出提示, 不回显服务端原始原因文本, 避免把未知内容带进页面.
   *
   * @param event 关闭事件.
   * @returns 无.
   */
  private handleClose(event: CloseEvent): void {
    this.relay = null;
    this.admission.reset();
    this.terminal.setInputEnabled(false);
    this.elements.connectionStatus.textContent = '已断开';
    this.elements.pathStatus.textContent = PATH_NONE_LABEL;
    this.setButtonsConnected(false);
    this.terminal.writeln('');
    this.terminal.writeln(`连接已断开(关闭码 ${event.code}).`);
    if (this.userClosed) {
      this.elements.notice.hidden = true;
      return;
    }
    this.showNotice(describeClose(event));
  }

  /**
   * 渲染准入状态, 并据此开关终端输入.
   *
   * @param snapshot 准入快照.
   * @returns 无.
   */
  private renderAdmission(snapshot: AdmissionSnapshot): void {
    this.elements.admissionStatus.textContent = snapshot.detail;
    if (snapshot.phase === 'admitted') {
      this.terminal.setInputEnabled(true);
      this.terminal.focus();
      this.elements.notice.hidden = true;
      this.terminal.writeln('准入通过, 终端已开放.');
      const verifierWarning =
        snapshot.verifier === REAL_VERIFIER
          ? ''
          : '当前准入由本地模拟器放行, 服务端未验签; 该状态仅用于界面验证, 不代表真实准入.';
      this.renderWarning(verifierWarning);
      return;
    }
    this.renderWarning('');
    this.terminal.setInputEnabled(false);
    if (snapshot.phase === 'denied' || snapshot.phase === 'not-integrated' || snapshot.phase === 'error') {
      this.showNotice(snapshot.detail);
    }
  }

  /**
   * 终端输入只在准入通过后上送; 未准入时直接丢弃, 不进入发送队列.
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
    } catch (error) {
      this.showFormMessage(error instanceof Error ? error.message : '终端输入发送失败');
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
      // 尺寸同步失败不影响本地渲染, 下一次尺寸变化会重试, 不向界面扩散
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
   * 切换连接相关按钮可用状态.
   *
   * @param connected true 表示连接已打开.
   * @returns 无.
   */
  private setButtonsConnected(connected: boolean): void {
    this.elements.connectButton.disabled = false;
    this.elements.disconnectButton.disabled = !connected;
    this.elements.registerButton.disabled =
      !connected || !isWebAuthnSupported() || this.hostMode !== 'deployment';
  }

  /**
   * 渲染常驻提示行; 部署域名提示始终保留, 模拟环境提示按准入结果追加.
   *
   * @param extra 追加提示, 空串表示本次没有额外提示.
   * @returns 无.
   */
  private renderWarning(extra: string): void {
    const parts = [this.hostNotice, extra].filter((part) => part.length > 0);
    this.elements.warningLine.hidden = parts.length === 0;
    this.elements.warningLine.textContent = parts.join(' ');
  }

  /**
   * 显示表单级提示; 过长内容截断.
   *
   * @param message 面向用户的提示.
   * @returns 无.
   */
  private showFormMessage(message: string): void {
    this.elements.formMessage.textContent = message.slice(0, MAX_MESSAGE_LENGTH);
  }

  /**
   * 清空表单级提示.
   *
   * @returns 无.
   */
  private clearFormMessage(): void {
    this.elements.formMessage.textContent = '';
  }

  /**
   * 显示断线或准入失败浮层.
   *
   * @param message 面向用户的说明.
   * @returns 无.
   */
  private showNotice(message: string): void {
    this.elements.noticeText.textContent = message.slice(0, MAX_MESSAGE_LENGTH);
    this.elements.notice.hidden = false;
  }
}

// =========** 函数 =========**
/**
 * 把关闭事件转为固定中文提示; 只识别协议约定的原因标识, 不回显自由文本.
 *
 * @param event 关闭事件, 原因可能为空.
 * @returns 面向用户的提示.
 */
function describeClose(event: CloseEvent): string {
  if (event.reason.includes('UNKNOWN_SESSION')) {
    return '会话不存在(UNKNOWN_SESSION): 请核对会话标识, 会话可能尚未建立或已结束.';
  }
  if (event.reason.includes('ROUTE_GONE')) {
    return '会话路由已回收(ROUTE_GONE): runner 侧连接已断开, 请重新获取会话信息.';
  }
  if (event.code === 1000) {
    return '连接已关闭. 如需继续操作, 请重新连接.';
  }
  return `连接已断开(关闭码 ${event.code}). 请检查网络与中转状态后重连.`;
}
