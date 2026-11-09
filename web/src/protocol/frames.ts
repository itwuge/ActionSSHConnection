/**
 * 文件: frames.ts
 * 所属目录: web/src/protocol/
 * 文件用途: 定义浏览器与中继 WS 之间承载字节流的二进制帧格式, 提供编码与严格解码.
 * 架构定位: 前端层协议模块, 上游是 relay-client.ts, 下游是帧负载解析与终端字节分流, 依赖方向单向朝内.
 * 核心功能: 帧头编解码; 帧类型常量; 版本与长度校验; 超长帧拒绝.
 * 职责边界: 不解析终端转义序列, 不解释认证负载语义, 不做传输层连接管理; 中继侧不得解析本格式.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 依赖浏览器 Uint8Array 与 DataView.
 * 依赖关系: 无外部依赖; 被 relay-client.ts 与 admission-client.ts 调用.
 */

// =========** 常量 =========**
/**
 * 帧头魔数, 用于在字节流被误接时快速判定格式不匹配.
 * 取 0xA1 是因为 ASCII 高位置位, 不易与终端 UTF-8 文本的首字节混淆.
 */
export const FRAME_MAGIC = 0xa1;

/**
 * 帧格式版本, 当前只允许 1; 版本不符直接判解码失败, 不做向前兼容.
 */
export const FRAME_PROTOCOL_VERSION = 1;

/**
 * 帧头长度: 魔数 1 + 版本 1 + 类型 1 + 保留 1 + 负载长度 4.
 */
export const FRAME_HEADER_BYTES = 8;

/**
 * 单帧负载上限 1 MiB; 超过即判非法, 防止对端以超长帧耗尽浏览器内存.
 */
export const FRAME_MAX_PAYLOAD_BYTES = 1024 * 1024;

/**
 * 帧类型编号, 用常量对象加联合类型而不是枚举:
 * 枚举会生成运行时反向映射对象, 打包体积与序列化语义都多余; 这里只需要稳定的数值编号.
 */
export const FRAME_TYPE = {
  terminalData: 0x01,
  resize: 0x02,
  authBegin: 0x10,
  authChallenge: 0x11,
  authAssertion: 0x12,
  authResult: 0x13,
  registrationOptions: 0x14,
  registration: 0x15
} as const;

// =========** 类型 =========**
/**
 * 帧类型联合, 取值为 FRAME_TYPE 的值集合.
 */
export type FrameType = (typeof FRAME_TYPE)[keyof typeof FRAME_TYPE];

/**
 * 一个已解码帧; payload 不含帧头, 语义由帧类型决定.
 */
export interface Frame {
  /** 帧类型编号, 必须是 FRAME_TYPE 的取值之一. */
  type: FrameType;
  /** 负载字节, 长度 0 到 FRAME_MAX_PAYLOAD_BYTES. */
  payload: Uint8Array;
}

/**
 * 帧解码失败; 携带可展示的中文原因, 不包含任何凭据内容.
 */
export class FrameDecodeError extends Error {
  /**
   * @param message 解码失败原因, 面向界面展示, 不得含凭据.
   */
  constructor(message: string) {
    super(message);
    this.name = 'FrameDecodeError';
  }
}

// =========** 函数 =========**
/**
 * 判定数值是否为已知帧类型, 用于把外部输入收窄为 FrameType.
 *
 * @param value 待判定数值, 来源不可信, 可能越界.
 * @returns 是已知帧类型返回 true.
 */
function isFrameType(value: number): value is FrameType {
  return Object.values(FRAME_TYPE).includes(value as FrameType);
}

/**
 * 编码一帧.
 *
 * @param type 帧类型, 必须是已知类型.
 * @param payload 负载字节, 长度不得超过 FRAME_MAX_PAYLOAD_BYTES.
 * @returns 含帧头的 ArrayBuffer, 可直接交给 WebSocket.send.
 * @throws {RangeError} 负载超过上限时抛出, 触发条件是调用方传入超长数据.
 */
export function encodeFrame(type: FrameType, payload: Uint8Array): ArrayBuffer {
  if (payload.byteLength > FRAME_MAX_PAYLOAD_BYTES) {
    throw new RangeError(`帧负载 ${payload.byteLength} 字节超过上限 ${FRAME_MAX_PAYLOAD_BYTES} 字节`);
  }
  const buffer = new Uint8Array(FRAME_HEADER_BYTES + payload.byteLength);
  const view = new DataView(buffer.buffer);
  buffer[0] = FRAME_MAGIC;
  buffer[1] = FRAME_PROTOCOL_VERSION;
  buffer[2] = type;
  buffer[3] = 0; // 保留位固定为 0, 留给未来扩展且不影响现有解码
  view.setUint32(4, payload.byteLength, false); // 大端序与网络字节序一致, 避免两端解释差异
  buffer.set(payload, FRAME_HEADER_BYTES);
  return buffer.buffer;
}

/**
 * 解码一帧; 所有校验失败都抛 FrameDecodeError, 便于调用方统一提示.
 *
 * @param data WebSocket 收到的二进制数据, 必须是完整单帧.
 * @returns 解码后的帧, payload 为副本, 不持有原缓冲区引用.
 * @throws {FrameDecodeError} 长度不足, 魔数或版本不符, 负载长度越界, 类型未知时抛出.
 */
export function decodeFrame(data: ArrayBuffer): Frame {
  if (data.byteLength < FRAME_HEADER_BYTES) {
    throw new FrameDecodeError('帧长度不足 8 字节');
  }
  const bytes = new Uint8Array(data);
  if (bytes[0] !== FRAME_MAGIC) {
    throw new FrameDecodeError('帧魔数不匹配, 对端可能不是本项目的中继协议');
  }
  if (bytes[1] !== FRAME_PROTOCOL_VERSION) {
    throw new FrameDecodeError(`帧版本 ${String(bytes[1])} 不受支持, 期望 ${FRAME_PROTOCOL_VERSION}`);
  }
  const type = bytes[2] ?? 0;
  if (!isFrameType(type)) {
    throw new FrameDecodeError(`未知帧类型 0x${type.toString(16)}`);
  }
  const view = new DataView(data);
  const declaredLength = view.getUint32(4, false);
  if (declaredLength > FRAME_MAX_PAYLOAD_BYTES) {
    throw new FrameDecodeError(`帧负载声明 ${declaredLength} 字节超过上限`);
  }
  const available = data.byteLength - FRAME_HEADER_BYTES;
  if (declaredLength !== available) {
    throw new FrameDecodeError(`帧负载长度不符, 声明 ${declaredLength} 字节, 实际 ${available} 字节`);
  }
  return { type, payload: new Uint8Array(data.slice(FRAME_HEADER_BYTES)) };
}
