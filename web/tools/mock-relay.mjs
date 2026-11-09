/**
 * 文件: mock-relay.mjs
 * 所属目录: web/tools/
 * 文件用途: 本地回环中继, 用于验证终端渲染, 尺寸自适应与断线提示; 不做任何验签.
 * 架构定位: 开发工具, 不属于产品链路, 不部署到任何宿主.
 * 核心功能: 按 /ws/<session_id> 接受连接; 识别帧头; 模拟准入结果; 回显终端输入; 主动断开演练.
 * 职责边界: 不验签, 不校验公钥, 不保存凭据, 不代表 runner 侧准入实现; 结果中的 verifier 固定为 mock 以便页面显式提示.
 * 运行环境: Node.js 18 以上, 依赖 ws 包, 仅监听本机回环地址.
 * 依赖关系: 依赖 ws 第三方库; 由 package.json 的 mock-relay 脚本调用.
 */

import { WebSocketServer } from 'ws';

const HOST = process.env['MOCK_RELAY_HOST'] ?? '127.0.0.1';
const PORT = Number.parseInt(process.env['MOCK_RELAY_PORT'] ?? '8787', 10);

const FRAME_MAGIC = 0xa1;
const FRAME_VERSION = 1;
const HEADER_BYTES = 8;
const SESSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;

const TYPE = {
  terminalData: 0x01,
  resize: 0x02,
  authBegin: 0x10,
  authChallenge: 0x11,
  authAssertion: 0x12,
  authResult: 0x13,
  registrationOptions: 0x14,
  registration: 0x15
};

/**
 * 编码一帧, 与 src/protocol/frames.ts 保持同构; 两者不一致时页面会报帧错误.
 *
 * @param {number} type 帧类型.
 * @param {Buffer} payload 负载字节.
 * @returns {Buffer} 含帧头的帧.
 */
function encodeFrame(type, payload) {
  const header = Buffer.alloc(HEADER_BYTES);
  header[0] = FRAME_MAGIC;
  header[1] = FRAME_VERSION;
  header[2] = type;
  header[3] = 0;
  header.writeUInt32BE(payload.length, 4);
  return Buffer.concat([header, payload]);
}

/**
 * 解码一帧; 非法帧返回 null, 由调用方断开连接.
 *
 * @param {Buffer} data 收到的二进制数据.
 * @returns {{type: number, payload: Buffer} | null} 解码结果.
 */
function decodeFrame(data) {
  if (data.length < HEADER_BYTES || data[0] !== FRAME_MAGIC || data[1] !== FRAME_VERSION) {
    return null;
  }
  const length = data.readUInt32BE(4);
  if (length !== data.length - HEADER_BYTES) {
    return null;
  }
  return { type: data[2], payload: data.subarray(HEADER_BYTES) };
}

/**
 * 发送 JSON 控制帧.
 *
 * @param {import('ws').WebSocket} socket 目标连接.
 * @param {number} type 帧类型.
 * @param {unknown} value 可序列化对象.
 * @returns {void}
 */
function sendJson(socket, type, value) {
  socket.send(encodeFrame(type, Buffer.from(JSON.stringify(value), 'utf8')));
}

/**
 * 发送终端文本.
 *
 * @param {import('ws').WebSocket} socket 目标连接.
 * @param {string} text 文本内容.
 * @returns {void}
 */
function sendTerminalText(socket, text) {
  socket.send(encodeFrame(TYPE.terminalData, Buffer.from(text, 'utf8')));
}

if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  console.error(`MOCK_RELAY_PORT 不是合法端口: ${String(process.env['MOCK_RELAY_PORT'])}`);
  process.exitCode = 1;
} else {
  const server = new WebSocketServer({ host: HOST, port: PORT });
  server.on('connection', (socket, request) => {
    const pathname = new URL(request.url ?? '/', `http://${HOST}:${PORT}`).pathname;
    const sessionId = pathname.startsWith('/ws/') ? pathname.slice(4) : '';
    if (!SESSION_PATTERN.test(sessionId)) {
      socket.close(1008, 'UNKNOWN_SESSION');
      return;
    }
    console.log(`模拟中继已连接: session_id=${sessionId}, 不验签, 仅本地验证`);
    sendTerminalText(socket, `本地模拟中继已连接(session_id=${sessionId}).\r\n本连接不验签, 仅用于终端渲染验证.\r\n`);
    socket.on('message', (data) => {
      const frame = decodeFrame(Buffer.isBuffer(data) ? data : Buffer.from(data));
      if (frame === null) {
        socket.close(1003, 'BAD_FRAME');
        return;
      }
      if (frame.type === TYPE.authBegin) {
        sendJson(socket, TYPE.authResult, {
          ok: true,
          verifier: 'mock',
          reason: '本地模拟器放行, 未验签'
        });
        sendTerminalText(socket, 'mock$ ');
        return;
      }
      if (frame.type === TYPE.authAssertion || frame.type === TYPE.registration) {
        console.log('模拟中继收到签名材料, 按设计不验签, 直接忽略');
        return;
      }
      if (frame.type === TYPE.resize) {
        return;
      }
      if (frame.type === TYPE.terminalData) {
        socket.send(encodeFrame(TYPE.terminalData, frame.payload));
        if (frame.payload.includes(0x0d)) {
          sendTerminalText(socket, `\r\nmock$ `);
        }
      }
    });
    socket.on('close', () => {
      console.log(`模拟中继连接已关闭: session_id=${sessionId}`);
    });
  });
  console.log(`模拟中继监听 ws://${HOST}:${PORT}/ws/<session_id>; 不验签, 不得用于真实会话`);
}
