/**
 * 文件: terminal-view.ts
 * 所属目录: web/src/terminal/
 * 文件用途: 封装 xterm 终端实例, 负责渲染, 键盘输入采集, 尺寸自适应与锁定状态切换.
 * 架构定位: 前端层视图模块, 上游是 app-controller.ts, 下游是 xterm 库与页面容器, 依赖方向由控制器指向视图.
 * 核心功能: 创建终端; 适配容器尺寸; 上报行列变化; 写入服务端字节; 开关输入; 释放资源.
 * 职责边界: 不建立连接, 不解析帧, 不判断准入; 输入是否上送由控制器决定, 本模块只负责采集与锁定.
 * 运行环境: TypeScript 5.6 以上, 目标 ES2022, 浏览器需支持 ResizeObserver 与 Canvas.
 * 依赖关系: 依赖 @xterm/xterm 与 @xterm/addon-fit; 被 app-controller.ts 调用.
 */

import { FitAddon } from '@xterm/addon-fit'; // 第三方运行库: 按容器尺寸计算行列数
import { Terminal } from '@xterm/xterm'; // 第三方运行库: 终端渲染与按键处理
import '@xterm/xterm/css/xterm.css'; // 副作用引入: xterm 基础样式, 缺少会导致光标与容器尺寸错位

// =========** 常量 =========**
/** 字号 14px; 终端等宽字体在 14px 下中文与符号都不至于挤压. */
const FONT_SIZE_PX = 14;

/** 回滚行数 5000; 够覆盖常见命令输出, 又不至于占用过多内存. */
const SCROLLBACK_LINES = 5000;

/** 最小可适配尺寸, 容器小于该尺寸时跳过 fit, 避免 FitAddon 抛异常. */
const MIN_FIT_WIDTH_PX = 32;

/** 最小可适配高度, 与宽度同理. */
const MIN_FIT_HEIGHT_PX = 32;

/** 终端配色, 深色底与高对比前景; 不依赖第三方主题. */
const TERMINAL_THEME = {
  background: '#0b1017',
  foreground: '#d7e0ea',
  cursor: '#54d6a0',
  selectionBackground: '#2a3a4d',
  black: '#0b1017',
  red: '#f07178',
  green: '#54d6a0',
  yellow: '#e6c07b',
  blue: '#6cb6ff',
  magenta: '#c792ea',
  cyan: '#5fd7d7',
  white: '#d7e0ea'
} as const;

// =========** 类型 =========**
/**
 * 终端视图回调; 由控制器提供, 视图不感知连接细节.
 */
export interface TerminalViewHandlers {
  /** 用户输入产生的 UTF-8 字节; 键盘输入为字符串, 这里统一编码后上送. */
  onInput: (bytes: Uint8Array) => void;
  /** 行列数变化; 初次打开与容器尺寸变化都会触发. */
  onResize: (cols: number, rows: number) => void;
}

// =========** 类 =========**
/**
 * xterm 终端视图.
 *
 * 方法一览:
 *   write(data) -> void: 写入服务端字节.
 *   writeln(text) -> void: 写入一行本地提示, 不经过网络.
 *   reset() -> void: 清屏并复位.
 *   fit() -> void: 立即按容器尺寸适配.
 *   setInputEnabled(enabled) -> void: 开关键盘输入.
 *   focus() -> void: 让终端获得焦点.
 *   dispose() -> void: 释放 xterm 与监听器.
 */
export class TerminalView {
  private readonly terminal: Terminal;

  private readonly fitAddon: FitAddon;

  private readonly container: HTMLElement;

  private readonly resizeObserver: ResizeObserver;

  private readonly disposables: Array<{ dispose: () => void }> = [];

  private fitFrame: number | null = null;

  private disposed = false;

  /**
   * @param container 终端挂载节点, 必须有确定的宽高, 宽度小于 32px 时不会执行适配.
   * @param handlers 输入与尺寸回调, 调用方保证回调不抛异常.
   */
  constructor(container: HTMLElement, handlers: TerminalViewHandlers) {
    this.container = container;
    this.terminal = new Terminal({
      cursorBlink: true,
      fontFamily: '"JetBrains Mono", "Cascadia Mono", "Consolas", "Noto Sans Mono CJK SC", monospace',
      fontSize: FONT_SIZE_PX,
      lineHeight: 1.2,
      scrollback: SCROLLBACK_LINES,
      theme: TERMINAL_THEME,
      disableStdin: true // 准入通过前不收键盘输入, 与控制器状态机形成双保险
    });
    this.fitAddon = new FitAddon();
    this.terminal.loadAddon(this.fitAddon);
    this.terminal.open(container);
    this.disposables.push(
      this.terminal.onData((data: string) => {
        handlers.onInput(new TextEncoder().encode(data));
      })
    );
    this.disposables.push(
      this.terminal.onResize((size: { cols: number; rows: number }) => {
        handlers.onResize(size.cols, size.rows);
      })
    );
    this.resizeObserver = new ResizeObserver(() => {
      this.scheduleFit();
    });
    this.resizeObserver.observe(container);
    this.fit();
  }

  /**
   * 写入服务端字节; 解码交给 xterm, 以保留 ANSI 转义序列.
   *
   * @param data UTF-8 字节或终端控制序列.
   * @returns 无.
   */
  write(data: Uint8Array): void {
    if (!this.disposed) {
      this.terminal.write(data);
    }
  }

  /**
   * 写入一行本地提示; 内容只来自前端固定文案或已校验的元数据.
   *
   * @param text 提示文本, 不得超过 1000 字符以免刷屏.
   * @returns 无.
   */
  writeln(text: string): void {
    if (!this.disposed) {
      this.terminal.writeln(text.slice(0, 1000));
    }
  }

  /**
   * 清屏并复位光标, 用于新会话开始前清理上一会话残留.
   *
   * @returns 无.
   */
  reset(): void {
    if (!this.disposed) {
      this.terminal.reset();
    }
  }

  /**
   * 立即按容器尺寸适配; 容器尚未布局时跳过, 等待 ResizeObserver 再次触发.
   *
   * @returns 无.
   */
  fit(): void {
    if (this.disposed) {
      return;
    }
    if (this.container.clientWidth < MIN_FIT_WIDTH_PX || this.container.clientHeight < MIN_FIT_HEIGHT_PX) {
      return;
    }
    try {
      this.fitAddon.fit();
    } catch {
      // xterm 在容器未渲染完成时可能抛错, 下一次 ResizeObserver 会重试, 不向界面扩散
    }
  }

  /**
   * 开关键盘输入.
   *
   * @param enabled true 允许输入; false 锁定, 用于等待准入与断线状态.
   * @returns 无.
   */
  setInputEnabled(enabled: boolean): void {
    if (!this.disposed) {
      this.terminal.options.disableStdin = !enabled;
    }
  }

  /**
   * 让终端获得键盘焦点.
   *
   * @returns 无.
   */
  focus(): void {
    if (!this.disposed) {
      this.terminal.focus();
    }
  }

  /**
   * 释放 xterm, 监听器与待执行的适配帧; 重复调用安全.
   *
   * @returns 无.
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    if (this.fitFrame !== null) {
      cancelAnimationFrame(this.fitFrame);
      this.fitFrame = null;
    }
    this.resizeObserver.disconnect();
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.terminal.dispose();
  }

  /**
   * 用下一帧合并连续尺寸变化, 避免拖拽窗口时每像素都调用 fit.
   *
   * @returns 无.
   */
  private scheduleFit(): void {
    if (this.disposed || this.fitFrame !== null) {
      return;
    }
    this.fitFrame = requestAnimationFrame(() => {
      this.fitFrame = null;
      this.fit();
    });
  }
}
