/**
 * 文件: relay-client.ts
 * 所属目录: web/src/transport/
 * 文件用途: 管理浏览器到中继 WS 端点的连接, 只按路径携带会话标识, 收发二进制帧.
 * 架构定位: 前端层传输模块, 上游是 app-controller.ts, 下游是浏览器 WebSocket 与 protocol/frames.ts, 依赖方向由界面指向网络.
 * 核心功能: 中继地址规范化; WS URL 生成; 连接与关闭; 帧发送; 收帧解码; 关闭事件上报.
 * 职责边界: 不解析控制负载语义, 不做准入判定, 不重试打洞, 不携带任何凭据参数; 中继侧不解析帧内容.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 浏览器需支持 WebSocket 二进制帧.
 * 依赖关系: 依赖 protocol/frames.ts; 被 app-controller.ts 调用.
 */

import { decodeFrame, encodeFrame } from '../protocol/frames'; // 项目内模块: 帧编解码

import type { Frame, FrameType } from '../protocol/frames'; // 项目内类型: 帧结构定义

// =========** 常量 =========**
/**
 * 会话标识允许字符; 中继按路径取键, 因此这里禁止斜杠, 点号与百分号, 避免路径注入.
 */
export const SESSION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;

/** 本地开发允许明文 WS 的主机清单; 其他主机一律要求 wss, 避免会话内容明文过网. */
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

/** 中继 WS 路径前缀, 与设计书 5.2 节对外接口一致. */
const WS_PATH_PREFIX = '/ws/';

/** 正常关闭码; 1000 是 WebSocket 标准正常关闭. */
export const NORMAL_CLOSE_CODE = 1000;

// =========** 类型 =========**
/**
 * 中继连接回调; 所有回调都在主线程同步调用.
 */
export interface RelayClientHandlers {
  /** WS 打开后调用, 此时可以发送首帧. */
  onOpen: () => void;
  /** 收到一帧且解码成功后调用; 解码失败走 onProtocolError. */
  onFrame: (frame: Frame) => void;
  /** 连接关闭时调用, 含关闭码与原因, 用于区分会话不存在与路由回收. */
  onClose: (event: CloseEvent) => void;
  /** 传输或协议错误时调用, 参数是面向界面的中文说明. */
  onError: (message: string) => void;
}

/**
 * 中继地址不合法; 提示文案用于表单校验, 不含用户输入的原始值.
 */
export class RelayAddressError extends Error {
  /**
   * @param message 面向界面的中文原因.
   */
  constructor(message: string) {
    super(message);
    this.name = 'RelayAddressError';
  }
}

/**
 * 连接未打开时发送帧; 调用方应先判断 isOpen, 这里抛出用于暴露时序错误.
 */
export class RelayNotOpenError extends Error {
  /**
   * @param message 面向界面的中文原因.
   */
  constructor(message: string) {
    super(message);
    this.name = 'RelayNotOpenError';
  }
}

// =========** 函数 =========**
/**
 * 把用户输入规范化为中继源地址, 只保留协议与主机端口.
 *
 * @param input 用户输入, 允许带尾部斜杠; 不得含路径, 查询串, 片段或用户信息.
 * @returns 形如 wss://relay.example 的源地址, 不带尾斜杠.
 * @throws {RelayAddressError} 协议不符, 含路径或查询串, 或非本地主机使用 ws 明文时抛出.
 */
export function normalizeRelayOrigin(input: string): string {
  const trimmed = input.trim();
  if (trimmed.length === 0) {
    throw new RelayAddressError('请填写中转地址, 例如 wss://relay.wuge.fun');
  }
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    throw new RelayAddressError('中转地址格式不正确, 需要包含 wss:// 或 ws:// 前缀');
  }
  if (url.protocol !== 'wss:' && url.protocol !== 'ws:') {
    throw new RelayAddressError('中转地址只允许 wss:// 或 ws://');
  }
  if (url.username.length > 0 || url.password.length > 0) {
    throw new RelayAddressError('中转地址不得包含用户名或口令');
  }
  if (url.pathname !== '/' || url.search.length > 0 || url.hash.length > 0) {
    throw new RelayAddressError('中转地址只填协议与主机端口, 不要带路径, 查询串或片段');
  }
  if (url.protocol === 'ws:' && !LOCAL_HOSTS.has(url.hostname)) {
    throw new RelayAddressError('除本机调试外, 中转地址必须使用 wss:// 加密连接');
  }
  return `${url.protocol}//${url.host}`;
}

/**
 * 生成中继 WS 地址; 路径只放会话标识, 不追加任何凭据参数.
 *
 * @param origin 已规范化的源地址.
 * @param sessionId 会话标识, 必须匹配 SESSION_ID_PATTERN.
 * @returns 形如 wss://relay.example/ws/<session id> 的完整地址.
 * @throws {RelayAddressError} 会话标识为空或含非法字符时抛出.
 */
export function buildRelayUrl(origin: string, sessionId: string): string {
  const trimmed = sessionId.trim();
  if (!SESSION_ID_PATTERN.test(trimmed)) {
    throw new RelayAddressError('会话标识只能由字母, 数字, 下划线与连字符组成, 长度 1 到 128');
  }
  return `${origin}${WS_PATH_PREFIX}${trimmed}`;
}

// =========** 类 =========**
/**
 * 中继 WS 客户端.
 *
 * 方法一览:
 *   connect(origin, sessionId) -> void: 建立连接, 旧连接先关闭.
 *   send(type, payload) -> void: 发送一帧, 未连接时抛错.
 *   close(code, reason) -> void: 主动关闭.
 *   isOpen -> boolean: 当前是否可发送.
 */
export class RelayClient {
  private readonly handlers: RelayClientHandlers;

  private socket: WebSocket | null = null;

  /**
   * @param handlers 连接事件回调, 调用方保证每个回调不抛异常, 否则会中断事件处理.
   */
  constructor(handlers: RelayClientHandlers) {
    this.handlers = handlers;
  }

  /** 当前连接是否处于打开状态; 发送前必须判断, 避免在关闭阶段抛错. */
  get isOpen(): boolean {
    return this.socket !== null && this.socket.readyState === WebSocket.OPEN;
  }

  /**
   * 建立到中继的 WS 连接.
   *
   * @param origin 已由 normalizeRelayOrigin 规范化的源地址.
   * @param sessionId 会话标识.
   * @returns 无; 结果通过 handlers 回调.
   * @throws {RelayAddressError} 地址或会话标识不合法时抛出, 此时不会创建连接.
   */
  connect(origin: string, sessionId: string): void {
    const url = buildRelayUrl(origin, sessionId);
    this.closeSocketQuietly();
    const socket = new WebSocket(url);
    socket.binaryType = 'arraybuffer'; // 协议只承载二进制帧, 文本帧视为错误
    this.socket = socket;
    socket.addEventListener('open', () => {
      if (this.socket === socket) {
        this.handlers.onOpen();
      }
    });
    socket.addEventListener('message', (event: MessageEvent<ArrayBuffer | string>) => {
      if (this.socket !== socket) {
        return; // 旧连接迟到消息直接丢弃, 防止与新会话数据混在一起
      }
      this.handleMessage(event.data);
    });
    socket.addEventListener('error', () => {
      if (this.socket === socket) {
        this.handlers.onError('WebSocket 连接出错, 浏览器未提供更多细节');
      }
    });
    socket.addEventListener('close', (event: CloseEvent) => {
      if (this.socket === socket) {
        this.socket = null;
        this.handlers.onClose(event);
      }
    });
  }

  /**
   * 发送一帧.
   *
   * @param type 帧类型.
   * @param payload 负载字节, 不超过帧上限.
   * @returns 无; WebSocket 缓冲由浏览器管理.
   * @throws {RelayNotOpenError} 连接未打开时抛出.
   * @throws {RangeError} 负载超过帧上限时由 encodeFrame 抛出.
   */
  send(type: FrameType, payload: Uint8Array): void {
    if (this.socket === null || this.socket.readyState !== WebSocket.OPEN) {
      throw new RelayNotOpenError('连接未打开, 无法发送帧');
    }
    this.socket.send(encodeFrame(type, payload));
  }

  /**
   * 主动关闭连接.
   *
   * @param code 关闭码, 必须是 1000 或 3000 到 4999; 默认 1000.
   * @param reason 关闭原因, 会出现在对端日志, 不得含凭据.
   * @returns 无.
   * @throws {RangeError} 关闭码越界时由浏览器 WebSocket.close 抛出.
   */
  close(code: number = NORMAL_CLOSE_CODE, reason = ''): void {
    this.closeSocketQuietly(code, reason);
  }

  /**
   * 处理一条 WS 消息, 只接受 ArrayBuffer.
   *
   * @param data 消息数据, 文本帧说明对端协议不符.
   * @returns 无; 解码失败通过 onProtocolError 回调.
   */
  private handleMessage(data: ArrayBuffer | string): void {
    if (typeof data === 'string') {
      this.handlers.onError('收到文本帧, 本协议只接受二进制帧');
      return;
    }
    try {
      this.handlers.onFrame(decodeFrame(data));
    } catch (error) {
      this.handlers.onError(error instanceof Error ? error.message : String(error));
    }
  }

  /**
   * 关闭并清空当前 socket; 关闭动作的异常在此吞掉, 因为连接已不可用.
   *
   * @param code 关闭码, 缺省 1000.
   * @param reason 关闭原因, 缺省空串.
   * @returns 无.
   */
  private closeSocketQuietly(code: number = NORMAL_CLOSE_CODE, reason = ''): void {
    const socket = this.socket;
    this.socket = null;
    if (socket !== null && socket.readyState < WebSocket.CLOSING) {
      try {
        socket.close(code, reason);
      } catch {
        // 关闭异常不改变结果: socket 引用已清空, 迟到的 close 事件会被丢弃
      }
    }
  }
}
