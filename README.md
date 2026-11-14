# zpi — pi 的 Zig 实现

纯 Zig（仅 std，零第三方依赖）实现的终端编程智能体，行为对齐 [pi](https://pi.dev) 1.5.0。

## 特性

**智能体内核**

- OpenAI 兼容 SSE 流式协议（text / thinking / tool_calls 增量；逐行解析，包级到达即渲染）
- 工具：shell、read、edit（diff 预览）、glob 匹配、选区截断
- 会话持久化（jsonl）+ `-c`/`-r` 继续会话（模型上下文与 TUI 界面双恢复）
- 上下文压缩：手动 `/compact` + 阈值自动压缩，压缩摘要块入转写
- 成本 / 缓存命中率 / token 统计（footer 实时显示）

**TUI**

- 差分帧渲染：DECSTBM 原生滚动 + 垂直位移检测（逐行校验，失败自动回退全量重绘）
- 屏幕层合成：滚动条（auto 显隐 + 拖拽 + 点击）、`Jump to latest message` 提示、搜索浮层
- 流式 Markdown **块级增量渲染**（段间拼接与全量渲染逐字节一致，帧成本与流长度解耦）
- 工具块 / thinking 块：折叠展开、点击切换单块、耗时与错误着色
- 补全菜单（`/` 命令、模型名）、转写内搜索（高亮 + 前后导航）
- 滚动体验：follow-end 钉底、滚轮加速度计、到底惰性（no-op 拉拽零字节）
- 鼠标：点击折叠块、拖拽选区、松开复制（OSC52）、水平滚轮过滤
- 启动欢迎头为文档首块（对齐 pi：继续会话时视窗钉底不可见）

## 快捷键

| 键 | 功能 |
|---|---|
| Enter | 提交 |
| esc | 中止运行中的回合 |
| ctrl+c | 清空编辑器；空时退出 |
| ctrl+d | 空编辑器时退出 |
| ctrl+z | 挂起后台（fg 恢复） |
| shift+tab | thinking 档位循环 off→low→…→max |
| ctrl+t | 显示/隐藏 thinking 块 |
| ctrl+p / shift+ctrl+p | 循环切换模型（下一个 / 上一个） |
| ctrl+l | 显示模型列表 |
| ctrl+o | 工具输出 折叠/展开 |
| ctrl+x | 复制选区（无选区时复制最后回复） |
| ctrl+g | 用 $EDITOR 编辑当前输入 |
| ctrl+↑ / ctrl+↓ | 上一条 / 下一条用户消息 |
| ctrl+home / ctrl+end | 转写顶部 / 回到最新 |
| pageUp / pageDown | 上翻 / 下翻（保留 4 行上下文） |
| ctrl+shift+f | 转写内搜索（enter / ctrl+g 前后导航，esc 关闭） |
| shift+enter / ctrl+j | 编辑器内换行 |
| `/help` | 全部命令 |

## 功能对比矩阵（pi 1.5.0 全量 vs 当前）

图例：✅ 已实现 · 🚧 部分实现 · ⏳ 暂缓

### 斜杠命令

| 命令 | pi | rpi | 说明 |
|---|---|---|---|
| /help /clear /exit /quit /hotkeys | ✅ | ✅ | |
| /model [name] | ✅ | ✅ | 模糊匹配直接切换 |
| /thinking [level] | ✅ | ✅ | rpi 命令名 `/think` |
| /session /name /new /tree /fork /resume | ✅ | ✅ | |
| /compact [hint] | ✅ | ✅ | 含阈值自动压缩 |
| /copy | ✅ | ⏳ | 键位 ctrl+x 已覆盖主要场景 |
| /export /share | ✅ | ⏳ | |
| /themes /settings | ✅ | ⏳ | 依赖主题/设置选择器体系 |
| /skills /trust /login /logout /mcp | ✅ | ⏳ | 依赖技能/扩展/信任体系 |
| /changelog /import /clone /reload /bug /debug | ✅ | ⏳ | pi 专有发布/扩展流程 |

### 全局键位

| pi action | pi 默认键 | rpi | 状态 |
|---|---|---|---|
| app.interrupt（中止） | esc | ✅ | |
| app.clear（清空/退出） | ctrl+c | ✅ | |
| app.exit（空时退出） | ctrl+d | ✅ | |
| app.suspend（挂起后台） | ctrl+z | ✅ | |
| app.thinking.cycle（档位循环） | shift+tab | ✅ | |
| app.thinking.toggle（块显隐） | ctrl+t | ✅ | |
| app.thinking.save（保存档位） | ctrl+s | ⏳ | |
| app.model.cycleForward/Backward | ctrl+p / shift+ctrl+p | ✅ | |
| app.model.select（选择器） | ctrl+l | 🚧 | 列表展示；全屏 selector 暂缓 |
| app.tools.expand（工具输出） | ctrl+o | ✅ | |
| app.editor.external（$EDITOR） | ctrl+g | ✅ | |
| app.message.copy（选区/最后回复） | ctrl+x | ✅ | |
| app.message.followUp / dequeue（排队） | alt+enter / alt+up | ✅ | 运行中排队，回合结束自动续跑 |
| app.clipboard.pasteImage（图片粘贴） | ctrl+v | ⏳ | 需图片输入管线 |
| app.session.toggleNamedFilter | ctrl+n | ⏳ | |
| tui.altScreen.search（转写搜索） | ctrl+shift+f | ✅ | |
| prompt_previous / next（用户消息跳转） | ctrl+↑↓ | ✅ | |
| altScreen 滚动（翻页/顶底/half/line 可配） | ✓ | ✅ | |
| app.session.new / tree / fork / resume | 未绑定（用命令） | ✅ | 同 pi，走命令 |
| editor：kill-ring / undo | ✓ | ⏳ | 多行、history 已实现 |

### 交互与渲染

| 功能 | pi | rpi | 状态 |
|---|---|---|---|
| 差分渲染 + DECSTBM 原生滚动 + 位移检测 | ✅ | ✅ | |
| 滚动条（auto 显隐 / 拖拽 / 点击） | ✅ | ✅ | |
| Jump to latest message 提示 | ✅ | ✅ | |
| 流式 markdown 块级增量渲染 | ✅ | ✅ | |
| thinking 块折叠（全局 + 单块点击） | ✅ | ✅ | |
| 工具块折叠 / 耗时 / 错误着色 | ✅ | ✅ | |
| 会话继续 + 历史界面回放 | ✅ | ✅ | `-c` / `-r` |
| 上下文压缩（手动 + 自动） | ✅ | ✅ | |
| 补全菜单（命令 / 模型） | ✅ | ✅ | |
| 转写搜索（高亮 / 导航） | ✅ | ✅ | |
| 鼠标：点击折叠 / 拖选复制 / 滚轮 | ✅ | ✅ | |
| footer（token / cost / git 分支 / cwd / 模型） | ✅ | ✅ | |
| steering（运行中改向）+ follow-up 排队 | ✅ | ✅ | Enter 运行中改向，alt+enter 排队，alt+up 恢复 |
| 图片输入（粘贴 / 拖放） | ✅ | ⏳ | |
| 会话分享 / 导出 | ✅ | ⏳ | |
| 扩展 / 技能 / MCP 体系 | ✅ | ⏳ | 架构级 |
| 主题体系 | ✅ | ⏳ | 单主题 |

## 构建

```bash
zig build          # Zig 0.17.0
./zig-out/bin/rpi  # 运行（REPL / TUI）
./zig-out/bin/rpi -c        # 继续当前目录最近会话
./zig-out/bin/rpi -p "问题"  # 单条模式（输出到 stdout）
```

## 测试与基准

```bash
zig test test_ui.zig              # 181 个 UI/逻辑测试
zig test leak_g2.zig              # 153 个泄漏回归测试
zig run bench_scroll.zig -O ReleaseFast   # 滚动帧基准
zig run bench_stream.zig -O ReleaseFast   # 流式帧基准
zig run bench_markdown.zig -O ReleaseFast # markdown 渲染基准
```

## 配置

智能体目录：环境变量 `PI_CODING_AGENT_DIR`，默认 `~/.pi/agent`。

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
{ "defaultProvider": "my-provider", "defaultModel": "my-model" }
```

apiKey 支持 字面量 / `$ENV_VAR` / `!command` 三种写法；凭据回退顺序：models.json apiKey → auth.json → 内置环境变量。内置提供方（如 zai-coding-cn）凭据来自 auth.json / 环境变量。

## 架构

```
src/
├── main.zig            入口（REPL / 单条 -p 模式）
├── core/               智能体循环、会话、配置、压缩、存储
├── ai/openai.zig       OpenAI 兼容 SSE 客户端（逐行解析，包级到达即渲染）
├── tools/              shell / read / edit / match / selection / truncate
└── ui/                 TUI：差分渲染、markdown、滚动视图、编辑器、搜索、补全
```

设计决策与演进记录（含完整功能审计史）见 [PLAN.md](PLAN.md)。
