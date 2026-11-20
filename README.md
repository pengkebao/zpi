# zpi

> 一个用纯 Zig 写的终端编程智能体 —— [pi](https://pi.dev) 1.5.0 的行为级重实现

![Zig](https://img.shields.io/badge/zig-0.17.0-orange) ![License](https://img.shields.io/badge/license-MIT-blue) ![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey) ![Tests](https://img.shields.io/badge/tests-718%2B-brightgreen)

**零第三方依赖 · 单二进制 · 与 pi 配置/会话双向兼容**

zpi 把 pi 的完整交互体验 —— 流式 Markdown、差分渲染 TUI、MCP 工具生态、技能与提示模板、会话树与压缩 —— 用 Zig 标准库从零实现。没有 Node，没有运行时，编译产物就是一个可以扔进 `$PATH` 的可执行文件。

## 为什么是 Zig

- **零依赖**：仅 `std`，不引任何第三方包。所有协议解析（SSE / JSON / ANSI / MCP）均为手写实现
- **单二进制**：`zig build` 产出一个静态倾向的可执行文件，拷贝即用
- **性能**：ReleaseFast 构建 ~3MB；渲染路径为帧预算精确设计（增量 markdown 渲染、DECSTBM 原生滚动、差分帧）

## 特性

**智能体内核**

- OpenAI 兼容 SSE 流式协议（text / thinking / tool_calls 增量；逐行解析，包级到达即渲染）
- 四种线路协议：openai-completions / anthropic-messages / openai-responses / google-generative-ai
- 工具：shell、read、edit（diff 预览）、glob 匹配、选区截断
- 会话持久化（jsonl，pi 同格式）+ `-c`/`-r` 继续会话（模型上下文与 TUI 界面双恢复）；**存储加固**：无效 UTF-8 工具输出清理为 U+FFFD（JSONL 不再因二进制字节损坏整行）、原子持久化（tmp + rename，写一半崩溃不截断会话文件）
- 上下文压缩：手动 `/compact` + 阈值自动压缩，压缩摘要块入转写
- 成本 / 缓存命中率 / token 统计（footer 实时显示）
- **运行中可干预**（pi 同款 steering / follow-up）：流式期间 Enter 排入 steering（下个 LLM 请求前注入上下文）、alt+Enter 排入 follow-up（本回合结束后跑新回合），编辑器上方实时显示 `Steering: …` / `Follow-up: …` pending 行；ESC 中断时全部排队消息恢复回编辑器（不丢失）；`steeringMode` / `followUpMode` 设置（all / one-at-a-time）从 settings.json 读取
- **运行中完整交互**（pi input in every state）：流式期间编辑器不只是能打字——`/` 补全菜单、`/model` `/thinking` 选择器、Cmd+V 整块粘贴、ctrl+v 剪贴板（图片→临时路径 / 文本直插）全部实时响应；会重建回合数据的命令（`/new` `/resume` `/fork` `/clear` `/compact` 等）会提示先按 Esc 而不是悄悄炸掉当前回合
- **流式韧性**（对齐 pi 1.5.0 的 `http-dispatcher` / `retry` / `overflow` 三层防护）：
  - **空闲看门狗**：网络读取是阻塞 `read(2)`，看门狗线程轮询 abort 标志 + 空闲计时（默认 300s，`$ZPI_HTTP_IDLE_TIMEOUT_MS` 可调，`0` 关闭），超时或对 ESC 时 `shutdown(fd)` 解除阻塞。看门狗从**建连/发送/等待响应头**阶段即启动（响应头到达后绑定 fd），覆盖请求全生命周期——网关静默挂起不再卡死，ESC 即时响应
  - **空响应自动重试**：网关偶发返回 200 但空/截断 SSE 体时，指数退避重试（默认 3 次，1s/2s/4s），不再静默 `EmptyResponse` 死回合
  - **长度截断恢复**（pi `isRecoverableLength`）：`finish_reason=length` 且 `output < max_tokens` 时判定上下文压力/网关截断，一次性压缩并重试
  - **纯思考回合轻推**：某轮只产出 thinking（无文本无工具调用）时注入一次 continue 提示，防止模型把输出预算耗在推理上后静默停滞
  - **无轮次上限**（对齐 pi `agent-loop` 的 `while(true)`）：工具轮循环只在模型停止调用工具或用户 ESC 中断时结束，长任务不会被中途切断
- **失败可见性**（不再静默死回合）：重试 / 自动压缩等恢复提示同时写入转写（灰色 `·` 行，不再 1.5 秒闪没）；回合失败时错误行自动滚入视口（钉底跟随），并持久化为会话条目——重启后红色内联重放，事后可追溯
- MCP 客户端：stdio + HTTP 传输、OAuth 登录、工具注册与热重载、`zpi mcp add/remove/list` 全套管理
- 技能（Skills）与提示模板（Prompts）：pi 同款发现机制与 `SKILL.md` 格式；`/skill:name` 调用时**完整技能体发给模型，但转写只占一行** `[skill] name (ctrl+o to expand)`——点击或 Ctrl+O 才展开正文（对齐 pi `SkillInvocationMessageComponent`，不再把整个 SKILL.md 刷屏）
- 事件总线 + hooks.json 钩子（session_start / pre_tool_call / post_tool_call / compaction）

**TUI**

- 差分帧渲染：DECSTBM 原生滚动 + 垂直位移检测（逐行校验，失败自动回退全量重绘）
- 屏幕层合成：滚动条（auto 显隐 + 拖拽 + 点击）、`Jump to latest message` 提示、搜索浮层
- 流式 Markdown **块级增量渲染**（段间拼接与全量渲染逐字节一致，帧成本与流长度解耦）
- 工具块 / thinking 块：折叠展开、点击切换单块、耗时与错误着色
- 补全菜单（`/` 命令、模型名、`!` bash）、转写内搜索（高亮 + 前后导航）
- 滚动体验：follow-end 钉底、滚轮加速度计、到底惰性（no-op 拉拽零字节）
- 鼠标：点击折叠块、拖拽选区、松开复制（OSC52）、水平滚轮过滤
- 编辑器：鼠标拖拽选区 + 双击选词（CJK 逐字）+ 三击选行、滚轮滚动编辑区；粘贴走 bracketed paste（多行整体粘贴，不再逐行提交）
- 剪贴板双通道：OSC 52（SSH/远程终端）+ 系统剪贴板（macOS pbcopy / Linux xclip·wl-copy / Windows PowerShell），覆盖 Terminal.app 忽略 OSC 52 的场景
- 启动欢迎头：半块像素 logo、双态键位提示（Ctrl+O 展开）、Model scope、技能/模板清单 —— 与 pi 逐行对齐
- **主题系统**（pi 同款 JSON 主题引擎）：53 个颜色 token，支持 hex / `okhsl()` / `oklch()` / 256 色索引 / `var()` 引用，内置 dark / light 双主题（逐字节对齐 pi 1.5.0），`/themes` 打开选择器（输入过滤、Enter 应用、✓ 标记当前主题）；自定义主题放 `~/.pi/agent/themes/*.json`，选择自动写入 settings.json 的 `theme` 字段并在下次启动时加载

## 快速开始

```bash
# 构建（Zig 0.17.0）
zig build

# 运行
./zig-out/bin/zpi            # 交互 TUI
./zig-out/bin/zpi -c         # 继续当前目录最近会话
./zig-out/bin/zpi -p "问题"   # 单条模式（输出到 stdout）
```

首次在某个目录使用会提示信任确认（pi 同款 trust 机制）。

### 命令行参数

与 pi 1.5.0 同名同义：`-p/--print`、`-m/--model`、`--model-id`、`--provider`、`--api-key`、`--models`、`--mode text|json|rpc`、`--thinking`、`-c/--continue`、`-r/--resume`、`--session`、`--session-id`、`--session-dir`、`--fork`、`--name`、`--no-session`、`--list-sessions`、`--list-models`、`--cwd`、`--no-tui`、`-t/--tools`、`-xt/--exclude-tools`、`-nt/--no-tools`、`-nbt/--no-builtin-tools`、`-a/--approve`、`-na/--no-approve`、`--append-system-prompt`、`--system-prompt`、`@file` 附加文件、子命令 `zpi mcp …`。

诊断开关：`--version`、`--no-mcp`（跳过 MCP 服务器加载）、`--no-context-files`（跳过 AGENTS.md/CLAUDE.md 注入）、`--quiet`（抑制匹配提示等诊断输出）、`--verbose`（stderr 输出传输/重试诊断）。

## 配置

智能体目录：环境变量 `PI_CODING_AGENT_DIR`，默认 `~/.pi/agent`。**与 pi 完全共享** —— 如果你已经在用 pi，无需任何迁移，zpi 直接读取你的模型、凭据、技能、提示模板与会话历史。

`models.json` — 自定义提供方/模型：

```json
{
  "providers": {
    "my-provider": {
      "baseUrl": "https://api.example.com/v1",
      "api": "openai-completions",
      "apiKey": "sk-...",
      "models": [{ "id": "my-model", "name": "My Model",
                   "contextWindow": 128000, "maxTokens": 8192, "reasoning": true }]
    }
  }
}
```

`settings.json` — 默认模型与行为开关：

```json
{ "defaultProvider": "my-provider", "defaultModel": "my-model", "theme": "dark" }
```

`theme` 取值 `dark` / `light` / 自定义主题名（`~/.pi/agent/themes/<name>.json` 的文件名，不含 `.json`）；缺省为 `dark`，也可在运行时用 `/themes` 切换（自动写回该字段）。

apiKey 支持 字面量 / `$ENV_VAR` / `!command` 三种写法；凭据回退顺序：models.json apiKey → auth.json → 内置环境变量。内置提供方（zai-coding-cn 等）定价内置于 catalog。

## 快捷键

| 键 | 功能 |
|---|---|
| Enter | 提交（**运行中** = 排入 steering 队列） |
| alt+Enter | 运行中排入 follow-up 队列（结束后作为新回合执行） |
| alt+↑ | 恢复全部排队消息到编辑器（pi dequeue） |
| esc | 中止运行中的回合（排队消息先恢复回编辑器） |
| ctrl+c | 清空编辑器；空时退出 |
| ctrl+d | 空编辑器时退出 |
| ctrl+z | 挂起后台（fg 恢复） |
| shift+tab | thinking 档位循环 off→low→…→max |
| ctrl+s | 保存当前 thinking 档位为默认（pi app.thinking.save） |
| ctrl+t | 显示/隐藏 thinking 块 |
| ctrl+p / shift+ctrl+p | 循环切换模型（下一个 / 上一个） |
| ctrl+l | 显示模型列表 |
| ctrl+o | 工具输出 折叠/展开（同时切换启动头形态） |
| ctrl+x | 复制选区（无选区时复制最后回复） |
| ctrl+v | 剪贴板粘贴：图片→临时文件路径入编辑器，文本直插（**运行中同样可用**） |
| ctrl+g | 用 $EDITOR 编辑当前输入 |
| ctrl+↑ / ctrl+↓ | 上一条 / 下一条用户消息 |
| ctrl+home / ctrl+end | 转写顶部 / 回到最新 |
| pageUp / pageDown | 上翻 / 下翻（保留 4 行上下文） |
| ctrl+shift+f | 转写内搜索（enter / ctrl+g 前后导航，esc 关闭） |
| shift+enter / ctrl+j | 编辑器内换行 |
| `!cmd` | 直接运行 bash（`!!cmd` 不入上下文） |
| `/help` | 全部命令 |

## 斜杠命令

常用：`/help` `/model` `/think` `/compact` `/new` `/session` `/name` `/tree` `/fork` `/resume` `/settings` `/mcp` `/skills` `/trust` `/login` `/logout` `/copy` `/export` `/share` `/themes` `/reload` `/bug` `/debug` 等 24+ 个，与 pi 1.5.0 同名同义。

亮点：

- **`/settings`**：pi SettingsSelectorComponent 全对齐的 35 项设置选择器（边框内渲染 + type-to-search + Enter/Space 循环值 + 即时持久化）
- **`/mcp`**：MCP 服务器管理器（状态/工具浏览、重连、全局/项目配置），`zpi mcp add|remove|list|login|logout` 命令行全套
- **`/model`** `/scoped-models`：模型选择器与 Ctrl+P 循环范围管理
- **`/tree` `/fork` `/resume`**：会话树、分支继承、跨目录恢复

## 架构

```
src/
├── core/               智能体循环、会话、配置、压缩、存储、MCP、事件、hooks
├── ai/                 四协议 SSE 客户端（openai / anthropic / responses / google）
├── tools/              shell / read / edit / match / selection / truncate / tool_search
└── ui/                 TUI 引擎：差分渲染、markdown、滚动视图、编辑器、搜索、补全
```

零依赖解析器均为手写：SSE 逐行解码、JSON 增量读取、ANSI 序列宽度计算、MCP stdio/HTTP 传输。

设计决策与完整功能审计史见 [PLAN.md](PLAN.md)。

## 测试

```bash
zig test test_ui.zig              # 277 个 UI/逻辑测试
zig test leak_g2.zig              # 195 个泄漏回归测试（SafeAllocator 全路径）
zig test src/ui/keys.zig          # 按键/鼠标序列解析（19）
zig test src/ui/tool_block.zig    # 工具块渲染：diff/ANSI/CJK 折行/实时输出（27）
zig test src/ui/theme.zig         # 主题引擎：token 解析/JSON 加载/内置主题（9）
zig test src/ui/oklab.zig         # okhsl/oklch → sRGB 颜色转换（2）
zig test test_openai.zig          # SSE 协议解析（11）
zig test test_mcp.zig             # MCP 客户端单测（9）
zig test test_pt.zig              # bracketed paste（4）
zig test test_clip.zig            # 剪贴板（2）
zig test test_pending.zig         # steering/follow-up 队列（含传递依赖共 187）
zig run bench_scroll.zig    # 滚动帧基准
zig run bench_stream.zig    # 流式帧基准
zig run bench_markdown.zig  # markdown 渲染基准
```

除单测外，开发流程使用 pty + 终端模拟器（pyte）驱动真实二进制的 E2E：mock SSE LLM + mock MCP stdio server + 原始 ANSI 字节流断言。

## 与 pi 的兼容性

| 维度 | 兼容方式 |
|---|---|
| 配置 | 直接共享 `~/.pi/agent`（models.json / settings.json / auth.json） |
| 会话 | jsonl 格式互通，`zpi -c` 可继续 pi 开的会话，反之亦然 |
| 技能/模板 | 同一发现机制与目录布局（`skills/` `prompts/`，user + project 两级） |
| MCP | 同一 `mcp.json` 结构与工具命名（`mcp__server__tool`） |
| 交互 | 键位、命令、启动头、footer 均按 pi 1.5.0 源码逐行对齐 |

## Roadmap

- [ ] 图片输入（拖放；ctrl+v 粘贴图片已支持）
- [ ] 会话分享 / 导出
- [ ] 主题体系（多主题选择器）
- [ ] Windows 终端支持
- [ ] skills 校验诊断（`[Skill warnings]` 启动节）

## License

[MIT](LICENSE)

## 联系

- 邮箱：84665381@qq.com
- Issue：[github.com/pengkebao/zpi/issues](https://github.com/pengkebao/zpi/issues)
