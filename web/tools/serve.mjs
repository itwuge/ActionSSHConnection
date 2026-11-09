/**
 * 文件: serve.mjs
 * 所属目录: web/tools/
 * 文件用途: 本地静态预览服务器, 只暴露 index.html 与 dist 目录, 供浏览器在 localhost 安全上下文下验证页面.
 * 架构定位: 开发工具, 不属于前端运行时代码, 不进入部署产物.
 * 核心功能: 端口与主机取自环境变量; 限定可访问路径; 目录穿越防护; 无缓存响应.
 * 职责边界: 不做 HTTPS 终止, 不代理 WebSocket, 不读取任何凭据; 仅用于本机验证.
 * 运行环境: Node.js 18 以上, 仅使用内置模块.
 * 依赖关系: 无外部依赖; 由 package.json 的 serve 脚本调用.
 */

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB_ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const HOST = process.env['HOST'] ?? '127.0.0.1';
const PORT = Number.parseInt(process.env['PORT'] ?? '5173', 10);

const MIME_TYPES = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.map', 'application/json; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.svg', 'image/svg+xml']
]);

/**
 * 把请求路径映射为允许访问的文件; 根路径与 /t/<会话ID> 返回 index.html, 其余只放行 dist 下的文件.
 *
 * @param requestUrl 请求的 URL, 可能含查询串.
 * @returns 绝对文件路径; 不允许访问时返回 null.
 */
function resolveRequestPath(requestUrl) {
  const pathname = new URL(requestUrl, `http://${HOST}:${PORT}`).pathname;
  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  if (decoded.includes('\0')) {
    return null;
  }
  const isSessionPath = /^\/t\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}\/?$/.test(decoded);
  const relative = decoded === '/' || isSessionPath ? 'index.html' : decoded.replace(/^\/+/, '');
  if (relative !== 'index.html' && !relative.startsWith('dist/')) {
    return null;
  }
  const absolute = resolve(join(WEB_ROOT, relative));
  const allowedPrefix = `${resolve(WEB_ROOT)}${sep}`;
  return absolute.startsWith(allowedPrefix) ? absolute : null;
}

if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  console.error(`PORT 不是合法端口: ${String(process.env['PORT'])}`);
  process.exitCode = 1;
} else {
  const server = createServer(async (request, response) => {
    const filePath = resolveRequestPath(request.url ?? '/');
    if (filePath === null) {
      response.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end('只允许访问 index.html 与 dist 目录');
      return;
    }
    try {
      const body = await readFile(filePath);
      const mime = MIME_TYPES.get(extname(filePath)) ?? 'application/octet-stream';
      response.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'no-store' });
      response.end(body);
    } catch {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end('文件不存在; 请先执行 npm run build');
    }
  });
  server.on('error', (error) => {
    console.error(`静态服务器启动失败: ${error.message}`);
    process.exitCode = 1;
  });
  server.listen(PORT, HOST, () => {
    console.log(`本地预览: http://${HOST}:${PORT}/ (仅本机, 只读 index.html 与 dist)`);
  });
  process.on('SIGINT', () => {
    server.close(() => {
      process.exit(0);
    });
  });
}
