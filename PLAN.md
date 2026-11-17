# rpi-zig：pi.dev (pi coding agent) 的 Zig 完整复刻

> 对标版本：pi 1.5.0（npm `@earendil-works/pi-coding-agent`）
> 原版规模：TypeScript, ~218k 行, 10 个包（pi-ai / pi-agent / pi-tui / pi-coding-agent / pi-mcp ...）
> 本项目规模：Zig, ~2.4k 行, 13 个文件
>
> **硬性约束：零依赖** — 纯 Zig std，不 vendor 任何 C 源码，不链接任何第三方库；
> 每个目标平台一个静态单文件二进制（darwin/linux/windows × x86_64/aarch64）。
> 所有平台相关能力（终端 raw mode、shell、路径、信号）通过 `builtin.os.tag` 分支 + OS 原生 API 实现。

## 架构映射

```
pi 包 (TS)              →  Zig 模块
──────────────────────────────────────────
pi-cli (入口)            →  main.zig + src/cli/        (参数、子命令、模式分发)
pi-agent (agent 循环)    →  src/core/                  (循环、事件、队列、压缩、会话)
pi-ai (provider 抽象)    →  src/ai/                    (openai-completions✅, anthropic-messages, openai-responses, google-generative-ai)
pi-tools (内置工具)      →  src/tools/                 (read✅ bash✅ edit✅ write✅ grep✅ find✅ ls✅ + codemode, tool_search)
pi-tui (组件系统)        →  src/ui/                    (fullscreen✅粗糙版, 组件, 主题, 快捷键)
pi-mcp (MCP 客户端)      →  src/mcp/                   (stdio + streamable HTTP)
zpi 扩展系统             →  src/ext/                   (扩展点、钩子、资源加载)
```

## 一、功能对比矩阵（pi 1.5.0 全量 vs 当前）

图例：✅ 已对齐 | ⚠️ 部分/粗糙 | ❌ 未实现 | ➖ 不适用（平台/语言限制）

### 1. Agent 核心循环

> 2026-11 复核：原表大量条目早已落地（steering/follow-up/usage/中断/重试/并行工具等在后续阶段实现），本轮按源码逐项核实并更新。

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| prompt → LLM → tools → LLM 循环 | ✅ | ✅ | 上限 50 轮 |
| 流式输出（text delta） | ✅ | ✅ | SSE 逐行解析（包级节奏） |
| 流式 tool_call 增量合并 | ✅ | ✅ | index 合并 |
| thinking/reasoning 块 | ✅ | ✅ | reasoning_content/reasoning/reasoning_text 三形态；TUI Ctrl+T 折叠 |
| thinking 级别 + thinkingLevelMap | ✅ | ✅ | off…xhigh/max 循环（shift+tab）+ `--thinking` CLI（显式优先）+ `provider/model:level` 后缀（pi splitThinkingSuffix strict 语义）+ thinkingFormat 三形态（default=reasoning_effort 直传 / zai=thinking:{type} / qwen=enable_thinking）+ thinkingLevelMap 映射 + models.json thinkingFormat/supportsReasoningEffort（三态，zai 域名 URL 自动检测）|
| steering（运行中插话） | ✅ | ✅ | Enter 队列；每轮 LLM 请求前注入（drainSteeringIntoContext） |
| follow-up（任务结束后续跑） | ✅ | ✅ | Alt+Enter 队列（运行中）；空闲时 = 普通提交（pi handleFollowUp 尾分支） |
| 中断（Escape / Ctrl+C） | ✅ | ✅ | HTTP 流停止；已流出 thinking/text 保留；未执行 tool_call 补 "aborted by user" 错误结果（wire 合法） |
| usage/cost 统计 | ✅ | ✅ | stream_options.include_usage；input/output/cached/cost 累计 |
| token 估算与上下文水位 | ✅ | ✅ | 页脚 `x.x%/窗口`（70%/90% 变色） |
| provider 错误重试 | ✅ | ✅ | 429/408/5xx + 传输错误，250/500ms 指数退避，有输出不重试 |
| 上下文溢出恢复（compact-and-retry） | ✅ | ✅ | provider 错误文本捕获 + 20 组溢出模式检测（pi OVERFLOW_PATTERNS 近似）→ 强制压缩 → 单次恢复重试；shouldCompact 小窗口下溢防护；单条消息超窗（cut=0）优雅报错 |
| 并行工具执行 | ✅ | ✅ | Thread.spawn 并行 + 按 call id 重排 |

### 2. 上下文组装

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| 系统 prompt 分节（preamble/tools/cwd/skills...） | ✅ | ✅ | `system_prompt.zig`：preamble/tools/rules/addendum/project_context/cwd/skills；skills 段 `<available_skills>` 广告（`skills.zig`，`/reload` 可重建） |
| AGENTS.md / CLAUDE.md 发现（cwd+祖先+agent 目录） | ✅ | ✅ | AGENTS.override.md 优先；root→cwd 去重 |
| `--system-prompt` / `--append-system-prompt` | ✅ | ✅ | 整体覆盖 / addendum 段 |
| @file 附件（文本+图片） | ✅ | ✅ | CLI 位置参数 `@path`：文本 `<file name>` 包裹（BOM 剥离）、图片魔数检测 → base64 ImageBlock 入首条消息（pi processFileArguments/buildInitialMessage 组装顺序 stdin→fileText→prompt） |
| 图片消息（base64 ImageContent） | ✅ | ✅ | ImageBlock 全链路（@file 图片 + read 工具图片）；wire image_url data URI |
| 粘贴图片 / 拖放 | ✅ | ✅ 图片粘贴（拖放留待） | ctrl+v（pi app.clipboard.pasteImage；Windows 下 alt+v 同 pi windowsKeybindings）：macOS osascript PNGf hex 解码；Windows/WSL PowerShell Clipboard::GetImage → Save %TEMP% → 读回（WSL 经 wslpath 转换读 /mnt）；文本回退 pbpaste/Get-Clipboard/xclip；路径插入编辑器，模型经 read 工具读图（pi 同款"临时文件+路径"流）；拖放需终端上报协议，留待。注：Windows 分支代码就位，随整个应用的 Windows 移植里程碑启用（TUI 终端层目前 POSIX 专属） |
| 管道 stdin 并入首条 prompt | ✅ | ✅ | 非 TTY stdin 读入并入首条；interactive 下有 stdin 降级 print（pi readPipedStdin + resolveAppMode） |
| 未识别 `/命令` 作为消息发送 | ✅ | ✅ | 本轮修复：`--no-session` 下 store 检查拦截所有 `/xxx` 的 bug；未识别 slash 命令（含粘贴的 /tmp 路径）作为普通消息发送（pi 语义） |
| `!cmd` 输出进会话 / `!!` 静默执行 | ✅ | ✅ | shell.exec（30s 上限）→ bashExecution 消息（pi JSONL 格式 command/output/exitCode/excludeFromContext）→ wire user 文本（bashExecutionToText）；`!!` 排除；回放渲染 |
| prompt 模板展开 | ✅ | ✅ | `agent-dir/prompts` + `cwd/.pi/prompts` 的 .md（frontmatter 剥离）；提交时 `/name args` 展开：$1..$n、$@/$ARGUMENTS、${N:-default}、${@:N[:L]} 切片（pi substituteArgs bash 引号解析）；未识别 `/` 命令回退模板检查 |

### 3. 工具

| 工具 | pi | rpi-zig | 差距 |
|---|---|---|---|
| read | ✅ 文本+图片 | ✅ | 图片 base64+image 块、truncateHead 截断+pi 提示；缺图片 resize/转换（零依赖限制） |
| bash | ✅ | ✅ | 真 timeout + abort + truncateTail 截断 + 临时文件；缺 stdin/进程组杀 |
| edit | ✅ | ✅ | `edit_diff.zig`：BOM/行尾探测+LF 归一化、fuzzy 匹配（尾随空白/智能引号/破折号归一，精确优先）、多 edit 全部对原始内容匹配（非增量）、唯一性/重叠检测、行号 diff 渲染（4 行上下文+`...` 折叠）；CRLF 保留 |
| write | ✅ | ✅ | |
| grep | ✅ 原生实现 | ✅ | 原生实现（match.zig 正则+glob）；pattern/path/glob/ignore_case/literal/limit；skip 噪声目录；行截 500 字符；100 匹配/50KB 截断+notice |
| find | ✅ 原生 | ✅ | 原生实现；pattern/path/limit；glob 匹配（无/ 匹配 basename，有/ 匹配全路径）；skip 噪声目录；1000/50KB 截断+notice |
| ls | ✅ 原生 | ✅ | 原生实现；path/limit；case-insensitive 排序；目录加 / 后缀；含 dotfiles；500/50KB 截断+notice |
| powershell | ✅ Win | ➖ | 后续 Windows 支持时做 |
| codemode（QuickJS 沙箱调用其他工具） | ✅ | 砍掉→原生并行工具执行 | 零依赖约束下不内嵌 C 解释器，并行执行入 A 阶段 |
| tool_search（未声明工具的搜索装载） | ✅ | ✅ | pi 同款 BM25（k1=1.2 b=0.75，name 权重 3、namespace 0.5，exact>coverage>score 稳定排序）；搜索未激活的 codemode/deferred 工具并装载至下一轮声明；注册即 inactive（`defaultActive:false`），`--tools tool_search`/`defaultTools`/搜索性 MCP 服务器自动激活（pi 激活 codemode 脚本工具，zpi 无 codemode 以 tool_search 兜底）；E2E：搜索→装载→下一轮 tools 数组含 `mcp__mini__screenshot` |
| 工具选择：`--tools`/`+name`/`-name`/`*` 通配 | ✅ | ✅ | selection.zig（E7）+ MCP 接入：`-nt` 禁一切（含 MCP 不注册）、`-nbt` 只禁内置、plain `--tools` 替换内置且仅含 `mcp__` 前缀条目时过滤 MCP（精确/glob，未匹配者不注册）、全 modifier 改默认集不动 MCP、`--exclude-tools` 波及一切（MCP 不注册）；Registry 改 `activateOnly`（inactive 保注册可被 tool_search 装载）+ `removeMatchingOn` |
| `defaultTools` 设置 | ✅ | ✅ | settings.json `defaultTools`（plain 替换/modifier 修改，同 pi resolveDefaultTools）；项目级合并待 H4（`.pi/settings.json` + trust） |
| ToolResult 所有权契约 | n/a | ✅ | 本次修复：content 一律堆分配、move 进消息、零泄漏 |

### 4. 会话（Sessions）

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| JSONL 持久化（v3 树结构 id/parentId） | ✅ | ✅ | `~/.pi/agent/sessions/--path--/<ts>_<uuid>.jsonl`；分支树 + branchMessages |
| 会话头/消息/压缩/分支摘要/自定义条目 | ✅ | ❌ | entry 类型全集见 session-format.md |
| `--continue` 最近会话 | ✅ | ✅ | |
| `--resume` 选择器 | ✅ | ⚠️ | CLI 有 --resume/--session <id>；交互选择器在 TUI /resume |
| `--session`/`--fork`/`--no-session`/`--name`/`--session-dir` | ✅ | ✅ | 支持 path 或 partial id |
| `/new` `/resume` `/name` `/session` `/tree` `/fork` `/clone` `/import` | ✅ | ⚠️ | 缺 /clone /import |
| 树导航 + 分支摘要 | ✅ | ✅ | /tree=交互选择器（leaf 链+图标+预览+视口滚动）；选中点分支 → **LLM 生成被弃路径摘要** → branch_summary entry（pi branchWithSummary）→ transcript 重建；选中 leaf 提示 "Already at this point" |
| /export（HTML/JSONL）、/copy、/share（gist/radius） | ✅ | ❌ | 均未实现；复制场景由 ctrl+x（选区/最后回复，OSC52）覆盖 |
| 会话按 cwd 分组、选择器搜索/改名/删除 | ✅ | ✅ | /resume=modal 选择器：↑↓+视口、**输入实时过滤**（id+name 大小写不敏感）、**ctrl+d 删除**（pi SessionSelector 语义）、Enter 恢复（重建 context+transcript，回放 model_change/thinking_level） |

### 5. 压缩（Compaction）

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| 自动压缩：`context > window - reserveTokens(16k)` | ✅ | ✅ | `maybeAutoCompact` 每轮开头检查 |
| keepRecentTokens(20k) 切点回溯 | ✅ | ✅ | `findCutIndex` snap 到 user/assistant 切点 |
| 结构化摘要 prompt + 迭代式（带上次摘要） | ✅ | ⚠️ | 六段式 prompt 已实现；迭代式（带上次摘要）待做 |
| 文件操作累计跟踪 | ✅ | ✅ | `FileOps` read/write/edit → readFiles/modifiedFiles |
| `/compact [instructions]` 手动 | ✅ | ✅ | TUI 命令 |
| compaction.* 设置 + 溢出恢复联动 | ✅ | ✅ | settings.json `compaction.{enabled,reserveTokens,keepRecentTokens}` |
| 分支切换摘要（branch summarization） | ✅ | ❌ | C5 留待 |

### 6. 模型与 Provider

> 2026-12 刷新：**四协议全实现 + 全量内置目录**。`src/ai/{openai,anthropic,google,responses,provider,sse}.zig`；
> 目录 = `tools/gen_catalog.py` 从 pi-ai 1.5.0 生成的 `src/ai/catalog.json`（@embedFile，23 家 provider / ~700 模型，
> 只收四协议 chat 模型 + 纯 API-key env 认证的 provider）。

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| openai-completions（SSE+tools） | ✅ | ✅ | 原 openai.zig（thinkingFormat zai/qwen/deepseek 已消费） |
| anthropic-messages | ✅ | ✅ | **Phase 6**：x-api-key+anthropic-version 头、顶层 system 数组、tool_use/tool_result blocks、thinking(budget_tokens 按档位)、无签名 thinking 回传转 text（pi allowEmptySignature=false 语义）、SSE message_start/content_block_*/message_delta（input_json_delta → 增量 tool_call 管线复用 openai 格式）|
| openai-responses | ✅ | ✅ | **Phase 6**：instructions、input items（message/function_call/function_call_output）、reasoning.effort、SSE output_text.delta/output_item.added/function_call_arguments.delta/response.completed |
| google-generative-ai | ✅ | ✅ | **Phase 6**：x-goog-api-key、systemInstruction、functionCall/functionResponse parts（**call_id→函数名映射**，response 包 `{"result":...}`）、thinkingConfig.includeThoughts、usageMetadata（含 thoughtsTokenCount）|
| provider 分发 | ✅ | ✅ | `provider.zig`：ApiKind(4) + AnyProvider union + streamDispatch/lastErrorText/buildFromModel；Model 新增 `api` 字段（models.json/catalog 的 "api"）；agent.Session/compaction 走 dispatch；公共 SSE 泵 `sse.zig`（POST+行泵+错误体捕获，retry 留各适配器）|
| 流式韧性三层 | ✅ | ✅ | 对齐 pi `http-dispatcher`/`retry`/`overflow`：`stream_guard.zig` 空闲看门狗（阻塞 read 可被 ESC/超时 shutdown 解除，默认 300s/`$ZPI_HTTP_IDLE_TIMEOUT_MS`）+ 空响应指数退避重试（1/2/4s×3，`emptyRetryDelayMs`）+ 长度截断恢复（`isRecoverableLength`，finish=length 且 output<max_tokens → 一次 compact-retry）+ 纯思考回合轻推（`blocksAreAllThinking` → 一次 continue 注入）|
| 内置 provider 目录（~40 家） | ✅ | ✅（缩编 23 家） | catalog.json 生成式内置：openai/anthropic/google/xai/deepseek/moonshotai(+cn)/zai(+coding-cn)/kimi-coding/minimax(+cn)/mistral/groq/together/fireworks/openrouter/cerebras/nvidia/baseten/ant-ling/meta/xiaomi/huggingface；模型级 api/baseUrl/reasoning/ctx/max/cost/images/thinkingFormat/thinkingLevelMap 全带 |
| models.json 自定义 provider | ✅ | ✅ | providers/models/apiKey/authHeader/$ENV/!cmd + **api 字段**（provider 或 model 级，缺省 openai-completions）；env 兜底查 catalog |
| auth.json 凭证 | ✅ | ✅ | 加载 + **写入**（saveAuthEntry/removeAuthEntry，未知字段保留） |
| OAuth（radius/anthropic/copilot/...） | ✅ | ❌ | J6（/mcp OAuth 一起） |
| `/login` `/logout`、`pi auth ...` | ✅ | ✅（api_key 类） | `/login <provider> <api-key>`：写 auth.json + 即时更新同 provider 全部模型；`/logout [provider]`（缺省当前）；OAuth 类待 J6 |
| 模型模糊匹配（id/name、--provider） | ✅ | ✅ | `resolveModelPattern`（pi resolveModelReference）：provider/id 精确 > 跨家 id 精确（**多家同 id → ambiguous 报错**）> provider 限定 fuzzy 子串 > 全局 fuzzy（**alias 优先于 -YYYYMMDD 日期版，字典序最新**）+ `--provider` 限定 + 未知 id 的 **custom-id fallback**（同 provider 第一个模型的配置换 id，pi buildFallbackModel）|
| `--thinking`/`:level`/`--api-key`/`--models` | ✅ | ✅ | --thinking level（显式优先）、`--model id:level` 后缀、--api-key 覆盖（不参与 auth 过滤）、--models 逗号 patterns（`provider/*` 前缀 glob + `:level` 后缀，匹配集合即 Ctrl+P 循环范围）、--list-models |
| samplingParams / compat / virtual models | ✅ | ⚠️ | thinkingFormat(thinkingFormat:zai/qwen/deepseek) + thinkingLevelMap + cost/images 已消费；strict/mid-convo/cache-control 类 compat 待真模型联调；virtual models（自动 fallback 链）⏳ |
| prompt cache 生命周期 + cache warming | ✅ | ❌ | 可选，靠后 |
| 模型目录自动刷新（`pi update --models`) | ✅ | ❌ | 重跑 tools/gen_catalog.py 等价（随 K4/K6） |

**Phase 6 过程修复**：(1) 三适配器 buildBody 首元素逗号 bug（`if (bfirst)` 应为 `if (!bfirst)`，mock 不
parse 请求体掩盖——google E2E 抓到 parts 数组 `[,` 非法 JSON）；(2) parseCmd 的 arg 只取第二个 token，
多参命令（/login <provider> <key>）截断——改为完整剩余文本；(3) config 内置目录替换时 helpers 块被
`pub fn load` 前缀匹配（loadProjectSettings）误切——恢复；(4) main 的 cwd_alloc 泄漏（defer free）。

### 7. 交互 TUI

> 2026-11 刷新：对照 pi 1.5.0 全量核对。本轮新增：shift+tab thinking 循环、ctrl+p/shift+ctrl+p 模型循环、ctrl+l 模型列表、ctrl+x 复制、ctrl+z 挂起、ctrl+d 空退出、会话继续界面回放、欢迎头对齐（详见文末审计表与本文件各条目）。

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| 全屏模式（alt-screen、固定编辑器/页脚、滚动区） | ✅ | ✅ | ScrollView 模型（wheel 加速/Ctrl+End 饱和、内容锚定）、滚动条（悬停/拖动/1s 隐藏）、Jump to latest 标签、PageUp/Down/Ctrl+Home/End、Ctrl+↑/↓ 用户消息跳转、Ctrl+Shift+F 搜索（语料/高亮/导航/浮框）；差分渲染 + DECSTBM 原生滚动 + 位移检测校验；到底惰性（no-op 拉拽零字节）；流式帧固定 22ms 节奏 |
| regular 模式（终端原生 scrollback） | ✅ | ❌ | |
| 多行编辑器（Shift+Enter、历史、光标移动） | ✅ | ✅ | Shift+Enter/ctrl+j（Kitty 协议）、Ctrl+↑/↓ 输入历史、全光标移动 |
| `/` 命令菜单 + 模糊搜索 | ✅ | ✅ | **pi SelectList 全面复刻 + 一级命令全对齐（pi BUILTIN_SLASH_COMMANDS 24 项原序原文）**：settings/model/tree/thinking（原 /think 改名，别名保留）/scoped-models（**新增**：ScopedModelsSelector——Enter 切换 ✓/✗、Esc 关闭、session-only、Ctrl+P 循环消费 scope）/export（补 .jsonl 分支=store 原文）/import/share（占位：需 Radius/gist 后端）/bug（issue 链接+版本）/copy/name/session/changelog（git 链接）/hotkeys/fork/clone/trust/login/logout/new/compact/resume/reload/quit + /mcp（等价 pi 的 mcp 扩展命令位）；**删** pi 没有的菜单项：/help /clear /debug /exit（handleCommand 保留兼容手打）；**pi SelectList 全面复刻**（对照 pi editor.js/autocomplete.js/select-list.js）：`→ ` 选中前缀 + 两列布局（主列 = clamp(最宽名+2, 12, 32)（slash layout）/默认 32，desc 右列 muted、选中整行 accent）；菜单**渲染在输入框下方**（pi editor.render：bottom border 之后）；窗口 5 行居中（pi autocompleteMaxVisible 默认 5）+ `(sel/total)` muted 滚动指示；up/down **环绕循环** + pgup/pgdn 按页（pi getSelectPageIndex）；命令名显示**不带 `/`**；pi fuzzy.js 完整移植（`src/ui/fuzzy.zig`：贪心字符对齐打分（连续 -5、间隙 +2、词首 -10、位置 +0.1、全等 -100、字母数字交换 +5；token 按空格/斜杠拆分、全 token 必须命中、升序稳定）；`skill:` 条目裸名匹配 + 全名兜底（pi bareNameMatches/fullNameOnlyMatches）；初始选中 = exact > startsWith（pi getBestAutocompleteMatchIndex）；**updateMenu 带文本守卫**（pi 只在 editor onChange 重建——主循环每键都调 updateMenu，无守卫会在导航键上重置 menu_selected 回第一行：菜单"卡住"＋两帧内容叠加的根因）；extras 与内置命令重名跳过（pi getBuiltInCommandConflictDiagnostics）；条目 = 内置命令 + **动态条目**（prompt templates + `skill:<name>`，desc 带 `[u]`/`[p]` scope tag，pi prefixAutocompleteDescription；/reload 刷新）；models 补全显示 id、值 = provider/id（pi label/value 分离）；enter（takes_arg）= 补全 `/name ` 后菜单切参数模式（pi selector UI 等价）；`/model` 无参 = 打开模型补全菜单（pi opens selector UI）|
| `/model`（Ctrl+L）、`/thinking`（Shift+Tab 循环） | ✅ | ✅ | **pi ModelSelectorComponent 全对齐**：/model（带/不带搜索词）打开**边框内模态选择器**（蓝边框）——`> ` 搜索行、橙色 "Only showing models from configured providers. Use /login" 提示（有 scope 时换 Scope: all\|scoped + tab 切换）、条目 `→ ✓ id [provider] · default`（当前模型 ✓、settings 默认 · default 徽章）、(n/total)、空行 + `Model Name: <name>` 详情、hint `Enter to select · Ctrl+S to set as default · Escape/Ctrl+C`；**排序**=当前模型→default→provider 字母序（pi sortModels）；搜索=pi 搜索文本（provider + provider/id + id + name）contains + **"default" 前缀置顶 default 项**；**Ctrl+S 设默认模型**（settings defaultProvider/defaultModel 落盘）；**Tab 切 all/scoped**（scoped_models 存在时）；Enter 切换并关闭；旧 autocomplete 形态的 models 菜单删除；ctrl+p/shift+ctrl+p 循环 + ctrl+l 列表不变；/think + shift+tab 档位循环 |
| `/hotkeys` | ✅ | ✅ | |
| `/settings` 对话框、`/debug` | ✅ | ✅ | **pi SettingsSelectorComponent 全对齐（35 项）**：渲染在**编辑器边框内**（搜索行/条目/计数 (n/35)/空行/描述/键位提示行——pi SettingsList.renderMainList 逐行复刻）；**Type to search**（editor 即搜索框）+ Enter/Space 循环值 + Esc 关闭；条目=pi 全集原序原文 desc；真实生效项=Auto-compact/Skill commands/Autocomplete max/Steering/Follow-up/Hide thinking/Default project trust/Fullscreen scrollbar/Copy on select/Wheel scrolling，其余占位（Enter 提示 not implemented）；**切换静默**（pi 无 "set to" note，行内值即反馈）且 **Auto-compact 同步 session.compaction 副本**（footer "(auto)" 标记与 maybeAutoCompact 立即生效）；改动即 persistSettings；**模态选择器边框固定蓝**（pi theme.border：settings/scoped/sessions/tree/fork/mcp/trust 打开时 BORDER_INFO 蓝，退出恢复 thinking 档位色——idle 紫/high 紫等）；编辑器补 **`> ` prompt**（wrap 缩进+光标 inset）；/debug（隐藏命令）：终端尺寸 + 渲染行 + 会话 JSONL → /tmp/zpi-debug-*.log |
| `!cmd` / `!!cmd`、`@file` 补全、Tab 路径补全 | ✅ | ✅ | !cmd/!!cmd ✅；**@file 实时菜单** ✅（输入 `@token` 即弹：token 边界检测（@ 在行首/空白后、无空格）、目录部分进入子目录、fuzzy 过滤+目录加权+深度排序、目录带 `/` 补全、选择后抑制重弹（token 相同不再弹出）、Tab/Enter 应用、Esc 关闭、继续输入实时过滤——pi autocomplete `@` 触发语义；**Tab 在无菜单时手动（重新）打开 @ 菜单**（含目录内二次补全：@zebra_dir/ + Tab → 列出目录内文件）；简化：无 fd 工具递归遍历（仅 cwd+子目录进入））；CLI `@file` 位置参数 ✅ |
| Ctrl+G 外部编辑器 | ✅ | ✅ | $EDITOR/VISUAL，挂起→编辑→恢复全量重绘 |
| 运行中输入（steering/follow-up/Escape 中断） | ✅ | ✅ | Escape/Ctrl+C 中断✅；**steering 队列**✅（运行中 Enter → 下一 LLM 请求前注入 context，pi getSteeringMessages 语义）；**follow-up 队列**✅（alt+enter 排队 → 回合结束自动续跑为新回合，pi followUpQueue）；**alt+up/alt+v 恢复排队消息到编辑器**✅（app.message.dequeue）；运行中编辑器 live（watcher 分发编辑器键，光标常驻输入框） |
| Ctrl+O 折叠工具输出、Ctrl+T 隐藏 thinking | ✅ | ✅ | Ctrl+O 预览↔全文；Ctrl+T 全局显隐 + 单块点击折叠 |
| 页脚（cwd、session、model、context%、cost） | ✅ | ✅ | cwd+git 分支+session 名；↑↓R/W/CH$、ctx% 变色+(auto)；右侧 (provider) model • thinking |
| 启动 header（欢迎 + 已加载资源清单） | ✅ | 🚧 | 欢迎头✅：文档首块（pi headerContainer 语义，继续会话钉底不可见）、compact 文案（wordmark+版本+快捷键+onboarding）；技能已加载并进系统提示（`skills.zig`）；"已加载资源清单"（Context/Skills/Extensions）header 展示 ⏳ |
| 会话继续界面回放（-c/-r） | ✅ | ✅ | replaySession 对齐 pi renderInitialMessages：user/assistant/thinking 块 + 工具块按 id 配对回填 |
| markdown 渲染 + 代码高亮 + diff 视图 | ✅ | ✅ | markdown 全块（标题/列表/嵌套/表格全边框/引用/hr/链接）；轻量代码高亮；diff 行级红绿 + **word 级反色（1:1 修改对，pi renderIntraLineDiff 语义）**；**OSC8 终端超链接**（链接+裸 URL；tmux/dumb 自动关闭，断行重开，truncateToWidth OSC 撕裂修复）；**LaTeX→unicode**（latex.zig：符号表/frac/sqrt/上下标/\left\right/\text；块级 $$…$$、\[…\ 与内联 $…$、\(…\；流式未闭合按原文渲染）；**流式块级增量渲染（自研增强）**；简化：无 pi 的 2D 分数堆叠排版（超宽回退原文同为 pi 行为） |
| 主题系统（JSON 主题文件、/settings 切换） | ✅ | ⚠️ | theme.zig 仅颜色枚举 |
| 快捷键管理器（keybindings.json） | ✅ | ✅ | Action 全集（含滚动/搜索/菜单/本轮 7 个新键位）、keybindings.json 加载覆盖、pi 默认键位 |
| 鼠标、IME、OSC8 链接 | ✅ | 🚧 | 鼠标✅：点击折叠、拖拽选区、松开复制（OSC52）、滚轮加速、水平滚轮过滤（pi parity）；IME/OSC8 ⏳ |

### 8. 进程模式

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| 交互模式 | ✅ | ✅ | |
| `-p` print（一次运行退出，stdout 只输出正文） | ✅ | ✅ | pi print-mode 语义：全程静默（quiet），回合结束从最后一条 assistant 消息一次性输出正文；thinking/tool 完全不落 stderr；错误 → stderr + **exit 1**（process.exit，无 error trace）；leak 清零（prompt/stdin/@file/trust-ctx 路径） |
| `--mode text` | ✅ | ✅ | `-p` 等价 |
| `--mode json`（JSONL 事件流） | ✅ | ✅ | **K1**：stdout 逐行 JSONL——session header（store 首行 / 合成）+ agent_start / turn_start / message_start / message_update（text_delta/thinking_delta/toolcall_start{id,toolName}/toolcall_delta，pi assistantMessageEvent 形状）/ message_end（assistant 全 content blocks + stopReason/usage；toolResult 带 toolCallId/content/isError）/ compaction_start|end(reason) / turn_end / agent_end / agent_settled(aborted)；stderr 全静默；工具回合 E2E 双轮验证全部行合法 JSON |
| `--mode rpc`（stdin/stdout JSONL 双向控制） | ✅ | ❌ | K2（复用 K1 事件流 + 命令解析），CLI 已占位报未实现 |
| SDK（进程内 TS） | ✅ | ➖ | Zig 侧等价物是库链接；可后置 |

### 9. 扩展与资源

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| 扩展：registerTool / 命令 / 事件钩子（tool_call 拦截）/ 自定义渲染 / UI 组件 | ✅ TS 进程内 | ❌ | 决策点：Zig 动态库 or 内嵌脚本解释器，见 Phase 9 |
| Skills（SKILL.md、agentskills.io 规范、/skill:name、按需加载） | ✅ | ✅ | `skills.zig`：4 处发现（agent/skills、~/.agents/skills、cwd/.pi/skills、cwd/.agents/skills）+ 递归（含 SKILL.md 目录=根）+ 最小 frontmatter 解析 + 名字校验 + 无描述跳过 + 同名去重；系统提示 `<available_skills>` 广告；`/skill:name [args]` 读正文包 `<skill>` 块发送（pi invokeSkill）；`/skill:<tab>` 补全；**转写折叠渲染**（pi SkillInvocationMessageComponent：一行 `[skill] name`，点击/Ctrl+O 展开，args 独立 user 消息，`-c` 回放同样折叠）；6 单测 + E2E |
| Prompt templates（Markdown、$1/$@/默认值） | ✅ | ✅ | Phase D：agent-dir/prompts + cwd/.pi/prompts；`/name args` 展开 $1..$n/$@/$ARGUMENTS/${N:-default}/${@:N[:L]}（bash 引号解析）；未识别 slash 回退模板 |
| 主题 JSON 文件 | ✅ | ⚠️ | theme.zig 仅硬编码 ANSI 暗色；JSON 主题发现/加载 + /settings 切换 + truecolor 迁移 ⏳（H3） |
| Pi packages（npm/git/local 安装分发、`pi install/remove/update/list`） | ✅ | ❌ | 依赖扩展机制成型 |
| `/reload` 热重载 | ✅ | ✅ | 重新发现技能 + 重建系统提示 + 更新 context（模板本就每次提交时新鲜发现，无需缓存） |

### 10. MCP

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| stdio server 接入（tools/call 全链路） | ✅ | ✅ | initialize 握手→tools/list→注册为 `mcp__<server>__<tool>`→tools/call；E2E 验证 |
| streamable HTTP + bearer 认证 | ✅ | ✅ | POST JSON-RPC（application/json + SSE 双格式解析）、`Mcp-Session-Id` 捕获回传、`Authorization: Bearer`（来自 login 或配置）；E2E 验证（含需鉴权服务器） |
| mcp.json（用户/项目，项目覆盖 user 同名项） | ✅ | ✅ | `<base>/mcp.json` + `.pi/mcp.json`，同名项目覆盖 |
| `/mcp` 管理、exposure 模式 | ✅ | ✅ | **pi McpManagerView 复刻**（交互式管理器，替代旧文本列表）：servers 菜单（attention 排序：failed > disabled > connected；desc = `state · exposure · scope`，pi describeState/exposureOf）→ server 菜单（Enable/Tools/Reconnect/Exposure/Disable，按状态裁剪）→ tools 列表（首行 description）/ exposure 四值选择（✓ 当前值）；写回 mcp.json（`setEntryField`：**自有 arena 统一 parse+put+stringify**，修混用分配器 free-after-resize panic）；enable = reconnect + re-register（`Manager.rememberConfigs` 保存启动配置副本供 respawn）；disable = teardown + 注销工具；工具重注册 = `registerToolsInto`（单服务器，exposure 语义同 registerTools）；ESC 逐级返回 |
| `zpi mcp add/remove/list/login/logout` | ✅ | ✅ | add（stdio/http，--local/--env/--cwd/--description/--exposure/-- 参数）；remove；list；login/logout（`mcp-auth.json` 存 bearer token，纯 std 近似 pi 的浏览器 OAuth） |
| MCP resources（list/read） | ✅ | ✅ | 三个全局工具 `list_mcp_resources` / `list_mcp_resource_templates` / `read_mcp_resource`，跨服务器聚合 + cursor；E2E 验证 |
| OAuth 浏览器流程 | ✅ | ❌ | 以 login 存 token 近似（无浏览器）；完整 OAuth 待做 |

### 11. 配置与安全

| 功能 | pi | rpi-zig | 说明 |
|---|---|---|---|
| settings.json（模型/工具/会话/压缩/交互/主题…） | ✅ 全量 | ⚠️ | 目前只读 defaultProvider/defaultModel |
| 项目级 `.pi/settings.json`、`.pi/mcp.json`、`.pi/extensions/` | ✅ | ⚠️ | **trust 门控已落地**：trusted 时加载项目 settings/mcp/skills/prompts；extensions 待 Phase I |
| 配置优先级 CLI > env > 项目 > 用户 | ✅ | ⚠️ | 项目 `.pi/settings.json`（trusted）覆盖用户级（defaultProvider/defaultModel/defaultTools/defaultProjectTrust/fullscreen*/compaction）；CLI --tools 仍最高；**defaultTools 项目覆盖在 ask 场景需重启生效**（CLI --tools 时跳过） |
| 项目信任（trust prompt、`/trust`、`-a/-na`） | ✅ | ✅ | pi trust-manager/project-trust 完整移植（`src/core/trust.zig`）：`trust.json` `{abs-path: true|false}`（键排序+尾换行）；**get 沿祖先链就近继承**（父信任覆盖子项目）；门控资源检测（`.pi/{settings,mcp}.json/extensions/skills/prompts/themes/SYSTEM.md/APPEND_SYSTEM.md` + cwd 祖先链 `.agents/skills`）；resolve 顺序 = CLI override(`--approve/-a`、`--no-approve/-na`) > 存档 > 无门控资源默认信任 > defaultProjectTrust 设置(ask/always/never) > **TUI 交互提示**（pi TrustSelector 五选项：Trust / Trust parent / Trust session-only / Do not trust / Do not trust session-only；面板含 cwd/Saved decision/Current session）；**Trust 热加载**（项目 mcp 重连+工具重注册+过滤重放 + skills/prompts 刷新，reload 钩子 main→TUI 回调）；`/trust` 重选（pi showTrustSelector）；项目 skills/prompts discover 加 `include_project` 参数门控 |
| 环境变量（PI_CODING_AGENT_DIR✅、SESSION_DIR、PI_OFFLINE…） | ✅ | ⚠️ | |

## 二、复刻路线图（按依赖顺序排列）

原则：每步可编译可测试；核心 > 会话 > Provider > TUI > 资源系统 > 扩展；不引入外部依赖（内嵌 C 源码需专项决策）；行为对齐 pi 但用 Zig 惯用方式。

### Phase A — Agent 核心健壮化（~1.5k 行）✅ 完成（A5 依赖 C 留待压缩阶段）
- [x] A1 usage 统计：解析 chunk.usage（input/output/cacheRead/cacheRead/cost），累计进 session；stream_options.include_usage；模型 cost 费率（models.json cost 字段 + 内置表）
- [x] A2 thinking 块：`reasoning_content`/`reasoning`/`reasoning_text` delta → thinking block；print 模式走 stderr；回放时不发给 openai-completions
- [x] A3 中断：SIGINT/SIGTERM handler → 全局 abort 原子标志；SSE chunk 间检查；部分消息落库 + 未执行 tool call 补 aborted 结果（保持 wire 合法）
- [x] A4 重试：transport/408/429/5xx 指数退避（250ms×2^n，最多 3 次尝试，已有输出不重试；4xx 不重试）
- [x] A5 上下文溢出恢复（C2 `maybeAutoCompact` 在每轮开头检查并压缩，避免溢出）
- [x] A6 token 估算 chars/4 + contextTokens()/contextPressure() API
- [x] A7 print 模式净化：stdout 只输出正文；thinking/工具活动/usage/错误走 stderr
- [x] A8 并行工具执行：多 tool call 线程池并发、结果按序归位
- [x] A9【计划外】修复原有 SSE 缓冲区重放 bug（`buf.resize(pos)` 方向反了：保留了已处理前缀、丢弃未处理尾部，长回答跨 read 时整段重放）

### Phase B — 会话持久化（~2k 行）✅ 完成
- [x] B1 SessionManager：JSONL 读写、树结构（id/parentId）、v3 兼容格式（`session_store.zig`）
- [x] B2 entry 类型：session header / message（AgentMessage 全量 block）/ compaction / branch-summary / custom-message
- [x] B3 sessions 目录布局 `--<path>--/<ts>_<id>.jsonl`，按 cwd 分组
- [x] B4 CLI：`--continue` `--resume` `--session <path|id>` `--fork <path|id>` `--no-session` `--name` `--session-dir` `--list-sessions`
- [x] B5 TUI 命令：`/new` `/resume [id]` `/name <n>` `/session` `/tree` `/fork` `/copy`
- [x] B6 `/export [path]`（HTML）、`/copy`（OSC 52 剪贴板）
- 验证：zpi↔pi 双向读写会话文件；`/tree` 缩进树、`/fork` 继承 name+parent、`/export` 生成独立 HTML、`/resume` 上下文重放（模型回忆暗号）全部通过

### Phase C — 压缩（~1k 行）✅ 核心完成（C1–C4，C5 分支摘要留待）
- [x] C1 compaction 设置（reserveTokens/keepRecentTokens/enabled）→ `compaction.Settings` + settings.json 解析
- [x] C2 自动压缩触发（每轮开头 `maybeAutoCompact`）+ 手动 `/compact [instructions]`（TUI）
- [x] C3 结构化摘要 prompt（Goal/Constraints/Progress/Key Decisions/Next Steps/Critical Context）+ 文件跟踪（readFiles/modifiedFiles）
- [x] C4 CompactionEntry 持久化（pi v3 JSONL）+ compaction-aware 上下文重建（`branchMessages`）
- [ ] C5 分支摘要（/tree 离开分支时生成 branch summary）

> **验证**：暗号召回 E2E（压缩后模型仍召回 `BLUE-FOX-42`）；文件跟踪（readFiles 正确记录 `marker.txt`）；JSONL 有效；压缩路径 0 泄漏。修复：`Message.clone` 未复制 `usage`（导致 `--continue` 后估算偏低）。

### Phase D — 上下文组装（~1k 行）
- [x] D1 系统 prompt 分节结构（`src/core/system_prompt.zig`：preamble/tools/rules/addendum/project_context/cwd，对齐 pi `system-prompt.js`）；sections 持久化补丁 ⏳（随扩展系统）
- [x] D2 AGENTS.override.md/AGENTS.md/CLAUDE.md 发现（agent 目录全局 + cwd 祖先链 root→cwd，去重）
- [ ] D3 `@file` 附件（文本+图片 base64）
- [ ] D4 `!cmd`/`!!cmd`（TUI）
- [x] D5 `--system-prompt`（整体覆盖）/`--append-system-prompt`（addendum 段）；管道 stdin 并入 prompt ⏳

> **D 已完成**：`buildSystemPrompt` + `loadProjectContextFiles`（E2E 验证：AGENTS.md 暗号召回、祖先链、CLAUDE.md 回退、覆盖/追加标志、0 泄漏）。D3/D4 属输入处理，独立推进。

### Phase E — 工具对齐（~2k 行）【E1/E5/E6 是跨平台硬性要求】
- [x] E1 Shell 抽象层：`src/tools/shell.zig`（unix `/bin/sh -c` / windows `powershell -NoProfile -Command`）；双 reader 线程读管道 + 主线程 10ms 轮询 timeout/abort；`kill`/`wait` 互斥清理管道
- [x] E2 bash 工具：真 timeout（无默认）、abort 传播、`truncateTail` 截断（2000 行/50KB）+ 临时文件保存完整输出 + 截断标记
- [x] E3 read：图片读取（扩展名探测 + base64 + image 块）、offset/limit + `truncateHead` 截断（pi 同款提示：`Use offset=N to continue` / 首行超限 bash 回退 / 用户 limit 剩余行提示）
- [x] E4 edit：fuzzy 匹配（唯一化）、diff 渲染数据
- [x] E5 grep/find/ls **原生实现**（不 shell 出去——windows 无这些命令，且进程开销大）
- [ ] E6 powershell 工具（windows 侧与 bash 对应，pi 同款设计）
- [x] E7 工具选择引擎：`src/tools/selection.zig`（`--tools`/`+`/`-`/`*` 通配/`defaultTools`）；`Registry.filterToNames`；对齐 pi sdk.js 语义
- [x] E8 Message 图片 content block（`ImageBlock{data,mime}`）+ openai provider 编码（tool 结果只发文本，图片作为后续 user 消息 `image_url`，`supports_images` 门控）
- [ ] E9 路径审计：代码里手工 '/' 分隔的地方全部改走 `std.fs.path`

> **E1/E2 已完成**：`shell.zig`（ShellConfig/ExecOptions/ExecResult，双 reader 线程 + 主线程轮询，kill/wait 互斥）+ `truncate.zig`（truncateTail/truncateHead，双限制取先触发者，formatSize）+ bash 工具重写（timeout/abort/截断/临时文件）。E2E 验证：echo 成功、timeout 1s 杀 sleep 5、seq 5000 截断到 3001-5000 + 临时文件 5000 行、0 泄漏。
>
> **E3/E8 已完成**：read 工具重写（图片扩展名探测 + `readFileAlloc` + base64 + image 块；文本 offset/limit + `truncateHead` + pi 同款截断提示）+ `ImageBlock` content block（deinit/clone/token 估算/HTML 导出）+ openai provider 图片编码（tool 结果只发文本，图片作为后续 user 消息 `image_url`，`Model.supports_images` 门控）。E2E 验证：小文件无截断、big.txt 3000 行截断到 1-2000 + `Use offset=2001`、test.png 读图 + 模型正确描述红色 PNG、0 泄漏。
>
> **E5 已完成**：`match.zig`（原生 glob `**`/`*`/`?` + basic regex `.` `*` `+` `?` `[...]` `^` `$`，6 单测）+ grep/find/ls 全部原生实现（`Dir.walk`/`Dir.iterate`，不 shell 出去）：grep（pattern/path/glob/ignore_case/literal/limit，skip 噪声目录，行截 500 字符，100 匹配/50KB 截断+notice）；find（pattern/path/limit，glob 匹配，1000/50KB 截断+notice）；ls（path/limit，case-insensitive 排序，目录加 / 后缀，含 dotfiles，500/50KB 截断+notice）。顺带修复 read 工具 `lines` 数组的 duped 行未释放泄漏。验证：13 用例功能测试全过 + 14 用例 SafeAllocator 泄漏检测 0 泄漏 + ls E2E（release 二进制）正确排序/目录后缀。
>
> **E4 已完成**：`edit_diff.zig`（~600 行）纯函数模块 + executeEdit 重写：`splitBom`/`detectLineEnding`/`normalizeToLF`/`restoreLineEndings`（CRLF 保留）；`normalizeForFuzzyMatch`（逐行尾随空白剥离 + 智能引号/破折号/特殊空格 → ASCII）；`fuzzyFindText`（精确优先，fuzzy 回退）+ `countOccurrences`（唯一性）；`applyEdits`（多 edit 全部对同一原始内容匹配，非增量；精确路径逆向字节替换，fuzzy 路径按行组叠加保留未改行原始字节）；重叠检测；`generateDiffString`（行号 + 4 行上下文 + `...` 折叠）。错误码映射（NotFound/Duplicate/Overlap/NoChange/EmptyOldText）。验证：10 单测全过 + 8 用例功能测试全过（精确/多 edit/fuzzy 智能引号/CRLF 保留/唯一性/未找到/legacy 格式/diff 输出）+ 8 用例 SafeAllocator 0 泄漏 + E2E（release 二进制）模型正确改单行且其他行不变。
>
> **E7 已完成**：`src/tools/selection.zig`（纯函数，对齐 pi sdk.js 工具选择语义）：`DEFAULT_TOOL_NAMES=[read,bash,edit,write]`；`isToolModifier`（`+`/`-`）；`getToolListError`（plain 与 modifier 不可混用、modifier 不可带 `*`）；`applyToolModifiers`（`+name` 不在则追加、`-name` 在则移除）；`resolveDefaultTools`（plain 作 base，否则 DEFAULT 作 base，再叠 modifier）；`select`（`--tools` plain 替换 / 全 modifier 修改 base，最后减 exclude）；`matchesAny`（精确或 `*` 通配，复用 `match.zig` globMatch）。settings.json `defaultTools`（config.zig 解析，支持 `+`/`-`）。`Registry.filterToNames`（双指针原地压缩，保留注册序）。CLI：`--tools`/`-t`、`--exclude-tools`/`-xt`、`--no-tools`/`-nt`。验证：15 单测全过 + 8 场景 harness（default/replace/modifier±/exclude 精确/通配/cancel-out/all-builtin）全过 + 8 用例 SafeAllocator 0 泄漏 + E2E（release 二进制）`--tools bash` 模型用 bash+cat、`--tools read` 模型用 read、`--no-tools` 模型报 NO TOOLS、混用 plain+modifier 报错退出。
- [x] E3 read：图片读取 + 行号截断
- [x] E4 edit：fuzzy 匹配（唯一化）、diff 渲染数据
- [x] E5 grep/find/ls **原生实现**（不 shell 出去——windows 无这些命令，且进程开销大）
- [ ] E6 powershell 工具（windows 侧与 bash 对应，pi 同款设计）
- [x] E7 工具选择引擎：`src/tools/selection.zig`（`--tools`/`+`/`-`/`*` 通配/`defaultTools`）；`Registry.filterToNames`；对齐 pi sdk.js 语义
- [x] E8 Message 图片 content block + provider 编码
- [ ] E9 路径审计：代码里手工 '/' 分隔的地方全部改走 `std.fs.path`

### Phase F — Provider 扩展（~2.5k 行）
- [ ] F1 anthropic-messages（SSE、tool_use、cache_control）
- [ ] F2 openai-responses、google-generative-ai
- [ ] F3 thinking 级别机制（thinkingLevelMap、预算 clamp、`--thinking`、`:level` 后缀）
- [ ] F4 模型模糊匹配 + `--provider` + `--api-key` + `--models` 作用域 + enabledModels 轮换
- [ ] F5 内置目录扩充（按需：anthropic/openai/deepseek/moonshotai-cn/qwen-token-plan-cn/minimax-cn/kimi-coding…）
- [ ] F6 `pi auth check/print-api-key` 子命令；OAuth 可最后（radius 依赖 pi.dev）
- [ ] F7 compat 消费：thinkingFormat（zai/qwen-chat-template/deepseek…）、samplingParams

### Phase G — TUI 对齐（~4k 行，最大单体）
- [~] G1 组件系统：✅ Text/VStack/Spacer/Box（component.zig）+ ScrollView（scroll_view.zig，批次 9）；待 SelectList/Loader/Input 独立组件
- [x] G2 全屏模式：✅ alt-screen + differential rendering + 光标定位 + 真实终端尺寸（TIOCGWINSZ）+ 键解析（keys.zig）；待 coalesced requestRender + regular(main-screen) 模式
- 批次 1 ✅：keys.zig（Key/parseKey/readKey，5 测试）+ component.zig（Component vtable/Text/VStack/Spacer/Box，4 测试）+ tui.zig 重写（fullscreen + diff render，3 测试）；E2E 验证 0 泄漏
- 批次 2 ✅：editor.zig（多行/光标/历史/@补全/键处理，5 测试）+ TUI 集成（transcript+editor 布局 + 新页脚 cwd/session/model/ctx%/cost + Ctrl+C 智能行为 + `/` 命令）；17 UI 测试全过，E2E 验证 0 泄漏
- **Kitty 键盘协议 ✅**（shift+enter 换行，对齐 pi）：启动发 `ESC[>7u\x1b[?u\x1b[c` 协商（pi 精确序列：push flags=7 + 查询 + DA1）；KeyReader 消费 `ESC[?<flags>u`/DA 回复：flags≠0→kitty 激活，flags=0 或仅 DA→modifyOtherKeys fallback（`ESC[>4;2m`，退出时 `ESC[>4;0m` 关闭）。退出时 `ESC[<u` pop。
- **第二轮修复（用户实测三 bug，根因：release 事件双处理 + 16 字节缓冲溢出）**：
  - **KeyReader 重组器**替代 readKey：512 字节 pending 缓冲 + `seqLenAt` 逐序列切分（pi StdinBuffer 模式），press+release 批次/IME 提交/协商回复混排不再溢出或产生杂字母
  - **release 事件过滤**：kitty flags=7 带事件类型，每键有 press+release；`isReleaseSeq`（`:3u/:3A..:3S`，pi 同款）+ parseKittyU event==3 + 箭头 `:3A` 全部静默丢弃 → 修复英文字母双插、ctrl+j 双换行、shift+enter 异常
  - **协商回复识别**：`parseKittyFlagsReply`/`isDeviceAttributesReply` 不再被当成 escape/杂键；消费后立即返回触发 run 循环 fallback 处理
  - **kitty 状态感知 legacy 映射**（parseSequence）：`ESC CR`=shift_enter(kitty)/alt+enter(非kitty)；`ESC OM`=numpad enter；**`\n`（Ctrl+J）永远 = 换行**（有意偏离 pi：默认终端无 shift+enter，Ctrl+J 是唯一换行键；pi 在非 kitty 下将 `\n` 映射为 enter）
  - **CSI-u 增强**：codepoint 27→escape；alt+letter（`97;3u`）；ctrl+大写字母；repeat 事件（`:2`）当 press 处理（打字重复）
  - E2E 证明（session 文件）：kitty 模式 press+release 批次 → `'hi\nthe'` 单换行；拼音+IME+ctrl+j → `'ni你\n好'` 精确；无 kitty 终端（仅 DA 回复）→ modifyOtherKeys fallback 立即生效，`\x1b[27;2;13~`→换行，`'a\nb'` 精确；CSI-u ctrl+c 退出 ✓；13+44+46 测试全过
- [x] G3 多行编辑器：✅ editor.zig（多行/光标/历史 Up-Down/@Tab 补全/Ctrl+K/U/W/A/E/Home/End/Ctrl+J 换行）+ **Ctrl+G 外部编辑器**（$EDITOR→$VISUAL→vi；临时退出 alt-screen/cooked 模式给编辑器 tty；临时文件 /tmp/zpi-prompt-{pid}.md；退出后重进 alt-screen + 强制全量重绘 + 读回内容 trim 尾部空白；E2E：fake editor 追加文本 → 会话收到 'a-appended'）
- **批次 4 ✅（Escape 中止）**：working 期间后台 stdin watch 线程（200ms 轮询 VMIN=0/VTIME=2）：单字节 ESC → `agent.requestAbort()` 中止（对齐 pi `app.interrupt: escape`）；其它按键捕获进 watch_captured，turn 结束后注入 KeyReader.pending 重放（working 期间打字不丢）；watch_stop 原子标志 + join（≤200ms）；"· interrupted" 笔记显示；E2E：bash sleep 30 → ESC → 中止 ✓ → 正常退出 ✓；全部旧 E2E 回归通过
- **批次 3 ✅（G4 命令菜单 + G6 markdown）**：
  - **markdown.zig**（零依赖 markdown→ANSI，6 测试）：标题三级配色+粗体、围栏代码块（关键字/字符串/数字/注释高亮，多语言关键字表）、行内代码/粗体/斜体/删除线/链接、列表（• 缩进）、引用（│ 前缀）、分隔线；ANSI 感知换行（样式跨行重发）；assistant 消息全走 markdown 渲染；thinking 流分离（stream_text/stream_thinking，thinking 单独暗色块）
  - **命令菜单**：子序列模糊匹配+评分排序（前缀100>子序列50），`❯` 高亮选中行，Up/Down 导航、Tab 补全、Enter 执行（带参命令变补全）、Esc 关闭；菜单行渲染在 transcript 与输入框之间，光标偏移联动
  - **`/model` 选择器**：列出 models.json 全部模型（名称+provider），模糊过滤，Enter 热切换（新建 provider + 换 session.model/provider/thinking_level + 状态行更新）；`/model <name>` 直接切换；owned_provider 生命周期管理（deinit 释放）
  - E2E：'/'→菜单出现；'he'→过滤到 /help；Enter→执行；'/model '→模型菜单；Tab 补全；down+Enter→热切换成功（状态行更新）；markdown 渲染（fence+样式）✓；50 UI + 52 泄漏测试 + 全部旧 E2E 回归通过
- [x] G4 `/` 命令菜单（模糊搜索）、`/model` 选择器；`/thinking` 保留 /think 形式；/settings 待 Phase H
- [~] G5 页脚全家桶：✅ cwd/session8/model/ctx%/cost + `/exit` 提示；待启动 header（cwd + model + session 信息）
- [x] G6 markdown/代码高亮 ✅（见批次 3）+ **批次 7：表格渲染**：管道表格（`| a | b |` + 分隔行）→ 对齐列（box-drawing `│ ├ ┼`、列宽=可见宽最大值、超宽自适应收缩、单元格支持 inline 样式、ANSI 感知截断）；E2E：真实模型表格 → `│/├/┼` 边框 + 单元格对齐 ✓
- **批次 5：diff 渲染 + 工具块**：tool_info 分流到 stream_tool（不再混入 assistant 文本）；`addToolActivity` 彩色渲染（`● 工具名` accent + 参数截断、diff `+`行绿 `-`行红、Successfully 绿/error 红、`...` 暗色、逐行截断）；E2E：真实模型 edit → 红删/绿增/工具头/摘要全出现；待 Ctrl+O 折叠、Ctrl+T thinking 开关、表格
- [x] G7 keybindings.json（keybindings.zig，16 测试）：11 个可配置 action（newline/submit/clear_editor_exit/external_editor/menu_*/toggle_tools/toggle_thinking）；pi 格式（`action: key | [keys]`，提及即整组替换默认）；parseKeyStr（ctrl/alt/shift 修饰 + 命名键 + alt+enter→char）；run loop 全部走 bindings + canonical 键翻译（newline→shift_enter、submit→enter、**未绑定的 enter→换行 fallback**）；文件缺失→默认。附带修 **IXON bug**（Ctrl+S 被 tty 流控制吞掉导致重绑 submit 失效）。E2E（PI_CODING_AGENT_DIR 隔离）：submit=ctrl+s → enter 不提交、ctrl+s 提交 ✓；`/hotkeys` 待做
- [ ] G8 主题 JSON + `--use-theme`；steering/follow-up/Escape 的交互接线
- **批次 8 ✅（TUI 内容显示对齐 pi，对照 pi 1.5.0 渲染源码逐项核对）**：
  - **回合事件日志**（`agent.zig` `TurnEvent`：thinking/text/tool_start/tool_result/compaction/note，按发生顺序）：TUI 事件到达即渲染——**工具执行过程可见**（pending 灰框 → 结果原地变绿/红，对齐 pi ToolExecutionComponent）；回合内顺序与 pi 一致（文本→工具→文本交错），不受 auto-compact 重建影响；print 模式 stderr 输出不变。`ToolResult.duration_ms`（并行执行器逐工具计时）
  - **工具块**（新 `src/ui/tool_block.zig`，23 测试）：前置空行 + 全宽背景 Box（pending/success/error 三态，pi 精确 RGB）+ per-tool 头部（`$ cmd (timeout Ns)` 粗体 / `read path:5-14` 路径紫+行范围黄 / `edit|write path` / `grep /pat/ in path (glob) limit N` / `find` / `ls` / 未知工具 key=value≤100 字符）；折叠预览对齐 pi（bash 尾 5 视觉行+hint、grep 15、find/ls 20、write 10、read 成功仅头部、错误前 10 行）；`Took 4.2s/1m 30s`；edit 只显示 diff（红删/绿增/muted 上下文），write 预览写入内容；输出 sanitize（剥 ANSI/控制字符/tab→3 空格）；Ctrl+O 切预览↔全文（记录 scrollback 索引原地重渲染）
  - **页脚**（新 `src/ui/footer.zig`，12 测试）：两行 pi 全量——cwd（~缩写）+ ` (git branch)`（零依赖读 .git/HEAD，支持 worktree gitdir）+ ` • session name`；`↑in ↓out R/W CH% $0.123 x.x%/window (auto)`（ctx% >70 黄 >90 红）；右侧 `(provider) model • thinking off|level`（多 provider 才显示 provider；非 reasoning 模型无 level）；formatTokens pi 阶梯（850/1.2k/45k/1.3M）；窄屏降级（先去 provider 再截 model）
  - **markdown 重写**（26 测试）：标题三式（H1 粗+下划线、H2 粗、H3+ 保留 `###` 前缀，统一黄）；围栏 ```` ```lang ````（无语言=pi 绿、text=无色、其他=轻量高亮）；列表（`-` 紫色、有序保留 `1.`、task `[x]`/`[ ]`、嵌套每层 4 列、延续行对齐、缩进段落归属正确的列表层）；表格（`┌┬┐├┼┤└┴┘` 全边框、表头粗体、行行分隔、单元格 wrap、pi 列宽收缩算法移植）；引用（`│ ` 边框+斜体 muted，换行重复边框）；hr≤80；链接（蓝+下划线+` (url)`，裸 URL 自动链接且不重复、CJK 标点截断）；**按词换行**（原为按字符硬切；CJK 单字可断；超长词硬拆）；宽字符精确 2 列（原 3 字节全按 2 列，`─│•` 错算）；行内样式用各自 off-code + base 重发（标题里的 `code` 不再丢标题色）；`_` 词内不斜体（snake_case 修复）；块间恰好一空行；`renderWith(base_style)` 支持给段落/列表/单元格整体底色（thinking 用）
  - **消息本体**：user=markdown+userMessageBg 全宽背景块（上下背景空行、每行补齐到整宽、reset 后背景重发）；assistant 去掉 `● Assistant` 头、缩进 1 列（width-2 渲染）；thinking=暗色斜体 markdown（无头部行，Ctrl+T 按索引隐藏，替换原脆弱的前缀字符串匹配）；compaction=`[compaction]` 粗体紫标签+customMessageBg 背景块+`Compacted from N tokens (ctrl+o to expand)`（runCompaction 改返回 tokens_before 并发事件，手动/自动压缩统一走此路径）；中止=红 `Operation aborted`
  - **顺手修复的既有 bug**：`formatTokens` 返回栈缓冲切片（页脚 `↑20` 乱码，E2E 抓到）；outputCallback 流式追加与 spinner 线程读取的数据竞争（加 render_mutex）；statusLine 在 spinner 线程遍历 session.messages 与 agent 线程追加的 UAF 竞争（footer_stats 主线程刷新缓存，watcher 线程走 redrawCached）；`/clear`/`/new` scrollback 泄漏；`deinit→restoreTerminal` 在未 setup 时写垃圾 termios（term_restored 初值改 true，修掉泄漏测试的 errno:19 噪音）；edit_diff `trimEnd` 缺 `\n` 导致 diff 每行后多一空行（发给模型的输出同样受影响，已修+精确格式断言）；`truncateToWidth` 按字节计宽（改按字符显示宽度，CJK 行不再被截短）；stdin EOF 时 run 循环空转（nextKey 改返回 EndOfStream，`catch break` 生效，`zpi < pipe` 干净退出）
  - 验证：119 UI 集成 + 99 泄漏（SafeAllocator 0 泄漏：pending→结果→双 Ctrl+O→孤儿结果→未完成 pending 全路径）+ 26 markdown + 23 tool_block + 12 footer + 10 edit_diff 全过；**本地 E2E**（/tmp/zpi-e2e：假 OpenAI SSE（127.0.0.1）+ pty 驱动 release 二进制 + 迷你终端模拟器逐行核对背景/全宽）：完整回合（thinking/文本/4 工具含失败与 edit diff/表格/围栏/Ctrl+O/Ctrl+T）全对齐，干净退出
  - **滚动修复**（用户报告"滚不到底/点击无效/提示行背景不对"后对齐 pi `TuiAltScreen`）：
    - **下滚回绕**：`scroll_offset` 是 usize，`fetchSub(3)` 在偏移 <3 时回绕成天文数字，渲染 clamp 又把它送到 `max_offset`（=顶部）——滚到底再滚一下直接跳回最顶，表现为"永远滚不到底"。改 `scrollBy`：饱和加减（`+|`/`-|`）+ CAS 循环（主循环/watcher 线程共用）
    - **内容锚定**：pi 不跟随末尾时 scrollTop 固定；zpi 偏移是"距底部行数"，新增内容会把视口推走。`anchorScroll`：offset>0 时 append/加宽工具块按新增行数同加 offset（addMessage、renderToolBlockAt 新增与原地加宽两条路径）；滚动时流式 live 预览属于末尾、不再显示
    - **Jump to latest 对齐 pi compositeScrollToEndIndicator**：不再独占一行整行反色（`hint_h` 布局行删除），改为**叠在 transcript 最后一行**上居中的小标签（` ↓ Jump to latest message · ctrl+end `，selectedBg=blueBg 背景+text 前景，仅标签带背景）。新 `src/ui/overlay.zig` 移植 pi `compositeTuiLine`+`AnsiCodeTracker`：ANSI 感知按列切分（严格边界、宽字符跨界丢弃）、overlay 后重放原行活跃 SGR 态（背景行右侧 padding 不掉色），8 测试
    - **点击跳转**：keys.zig 新 `parseSgrMouse`（button/col/row/release，0 基坐标；wheel 按 `btn&64`+`btn&3` 识别、带修饰键也认）+ `mouse_click` Key（仅左键 press；release/motion/其他键忽略）；tui 打包 `jump_hint` 矩形（原子 u64，渲染线程写、两条输入路径无锁命中检测），命中即 `scroll_offset=0`；Ctrl+End 走同一 scrollToLatest
  - 验证（滚动修复后）：zig build ✓；test_ui 131（新增滚轮回绕/锚定/命中 3 测试）；leak_g2 108 含提示条合成路径 0 泄漏；E2E 新增滚动段：滚上去后标签行 selectedBg=True/label-only=True、回滚到底后多滚一格 no-op=True（不再跳顶）、点击标签后画面与底部逐字节一致=True，退出干净
  - 待做（后续批次）：bash 运行中实时输出流（当前工具框在工具完成时出现，pi 是流式追加）、write/edit 代码预览语法高亮、compaction 展开摘要、diff 行内 word 级 inverse 高亮、OSC8 超链接（overlay 已预置 SEGMENT 概念）

- **批次 9 ✅（ScrollView/滚动条/转录搜索，对照 pi 1.5.0 `TuiAltScreen`+`alt-screen-search.js` 逐项核对）**：
  - **ScrollView 模型**（新 `src/ui/scroll_view.zig`，19 测试）：替换旧 `scroll_offset`（距底部行数）为 pi 同构的 `scroll_top`（文档首行）+ follow-end 状态机（`scrollTo/scrollBy/updateLayout/geometry`，顶/底饱和不回绕、内容增长时跟随钉底、滚上去锚定不动）；`WheelScrollAccelerator`（pi wheel-scroll.js：连发加速 1→2→3 行、500ms 手势合并）；1s 自动隐藏（`markActivity/tick`，空闲轮询 tick）
  - **滚动条**：末列 thumb/track（pi 色板 okhsl(237 7% 33%)/okhsl(232 7% 65%) 转 sRGB）、悬停显现、拖动（press 记住 thumb 行、drag 按行差滚动、release 结束）、滚到底自动隐藏
  - **键绑定**（keybindings.zig + keys.zig）：PageUp/Down（视口高-1 行）、Ctrl+Home/End、Ctrl+↑/↓（跳上一条/下一条用户消息，复用 user_blocks 索引）、Ctrl+Shift+F（Kitty `102;6u`/legacy 0x06 与 pi 同样不可区分时不命中）；搜索框聚焦时吞掉所有键（含 Ctrl+C，对齐 pi Input 拒绝控制字符）
  - **转录搜索**（新 `src/ui/search.zig`，41 测试）：语料构建（剥 ANSI、ASCII 快路径、空白连写折叠为单空格、宽字符整宽索引）、大小写折叠（ASCII fold 双侧）、字面量非重叠匹配（pi matchAll 语义）、选中态（query/next/previous/retain 四模式 + anchor 行 + selectedKey 跨语料保持）、回车/Shift+回车循环导航（@mod 回绕）、reveal 滚动（disable_follow）；高亮 MATCH_STYLE（下划线+24 位底/前景 okhsl(53 51% 24%)+muted）、当前匹配加粗反色；右上角浮动 3 行搜索框（宽 40%、min 32、占位 "Find in transcript"、`n/m` 计数、底行 ↑/↓ 导航按钮可点击/悬停）
  - **顺手修复**：`search.refresh` corpus_query 所有权 double-free（defer 与存储指针冲突，E2E 抓到 segfault，并导致堆损坏后匹配数虚高）；空闲时滚动条隐藏需 100ms 轮询 tick（key_reader.poll）
  - 验证：search 41 + scroll_view 19 + width 4 + keys 16 + test_ui 168 全过；LSP 0 诊断；**E2E 新增两段**（驱动模拟 Kitty 协议应答，CSI-u 发键）：键盘滚动（pageUp 出提示/ctrl+home 到顶见首条用户消息/ctrl+end 回底逐字节一致）+ 搜索（开框/输 "observation" 得 1/27/回车 2/27/Shift+回车两步回绕 27/27/匹配底色 (78,47,27) 出现/Esc 关框后高亮消失），退出干净 0 泄漏
  - **终端缩放**（SIGWINCH + 重排，用户反馈"内容版块及色块不随窗口缩放"后对齐 pi per-frame 渲染）：keys.zig 装 SIGWINCH handler（幂等，deinit 恢复；async-signal-safe 只置原子 flag），KeyReader.fill 从 VMIN/VTIME tcsetattr 技巧改为 100ms poll()（空闲时也轮询 → resize 不再等下一次按键才生效；`.resize` Key → 全量重绘；观察进程 stdout.on("resize") → requestRender）；scrollback 新增并行 `scrollback_src`（assistant/user/thinking 存 markdown 原文、tool 存 tool_calls 索引、compaction 存 tokens），宽度变化时 `rerenderAtWidth()` 全部按新宽度重渲染——markdown 重 wrap、**色块行重新补满新宽度**（此前块在添加时就渲染定宽，缩窄溢出、加宽留白）；高度变化只 2J 全量重绘不重排；流式期间 watcher 线程 100ms 轮询顺带查尺寸（主循环在 runPrompt 里不读键）；顺手修：/clear 现在也清 user_blocks（原残留会误导 Ctrl+↑/↓）
  - 验证：test_ui 169（新增 resize reflow 测试：40→80 列重渲染后行数严格变少、每行 bg 重新补满）；全套件过 + LSP 0；**E2E 新增缩放段**：pty 缩到 38×70 → ctrl+home 到顶验色块跨满新宽（# 标记）→ ctrl+end 回底验编辑器横线重 wrap + footer 在新末行 + 尾部内容可见 → 还原 70×100 后与初始帧逐字节一致；退出干净
  - 已知偏差（不在本批次）：流式中按键捕获/重放、URL 点击、双击选词/三击选行、同步输出、Kitty 图片

- **批次 10 ✅（点击展开/收起 + 拖选自动复制 + 流式整屏推上 + 滚动性能，对照 pi TuiAltScreen 的 mouse/selection/streaming 逐项核对）**：
  - **流式整屏推上**（用户反馈"回复时只在小块区域里推，结束后才整体推"）：旧 renderLiveBlock 每帧只渲染尾部 ≤8 行（budget 截断），内容增长时视口内只有小区域跳动；改为 liveBlockLocked **全量渲染** thinking+text markdown（与 scrollback 同样的 ' ' 前缀），作为文档尾部参与 updateLayout → 内容增长时整个视口自然上推（pi：流式组件每帧全量重渲染）；渲染结果按 (width, thinking.len, text.len) 缓存，spinner 12.5Hz 空转帧不再重复渲染 markdown
  - **滚动卡顿修复**（用户反馈"markdown 加载后往上滚动变卡"）：每帧 collectLines 重切全部 scrollback 块（大 transcript 上千行切片每帧重建）；新增 doc_lines/doc_block_first 缓存，仅在 transcript_gen/宽度/Ctrl+T/Ctrl+O 变化时重建——滚动帧只切可见窗口 ~60 行；顺带提供 blockAt(doc_row)→块索引（点击命中用）
  - **点击工具块展开/收起**（用户反馈原版可点击切换）：ToolEntry 新增 expanded: ?bool（null 跟随全局 Ctrl+O，点击切换单块）；鼠标手势对齐 pi：press→交互元素（搜索框/跳转标签/滚动条）优先，否则开始选择手势；release 未移动 = click → toolAt(doc_row) 命中工具块则原地 toggle（renderToolBlockAt 单块重渲染）；Ctrl+O 全局切换时清除 per-block 覆盖
  - **拖选自动复制**（用户反馈原版可选字符自动复制）：press 设锚点（doc 坐标，滚动不脱锚）→ drag 更新焦点 → release 复制（copyOnSelect，已有 OSC52 copyToClipboard）+ footer 右侧 "Copied!" flash（1.5s，poll 计时同滚动条）；高亮 overlay.applySelectionHighlight：范围内反色 \x1b[7m…\x1b[27m，内嵌 SGR 后重申 [7m（pi 同款）；选区渲染在搜索框之后（pi：selection 覆盖 overlay）、避开滚动条列；selectionText 取 doc 行 sliceByColumn+stripSequences+trimEnd；点击空白处清除选区
  - 验证：test_ui 171（新增：live 全量渲染+缓存同指针、拖选 selectionText 精确文本+反色高亮+点击清除、点击工具块展开/收起翻转）；全套件过 + LSP 0；**E2E 新增两段**：ctrl+home 后点击 read 块头部（press+release）→ 块变高（后续块下移）→ 再点收起（块位复原）；底部拖选 "observation 26" 13 列 → buf 出现 OSC52 + "Copied!" flash；退出干净
  - 顺手修：handleRelease 锁内调 renderToolBlockAt 的双重解锁；调试中发现测试断言用 edit diff 的 " 1 line one" 误判 read 展开（改块高判定）；**滚动时顶部行尾光标闪烁**（用户反馈）：帧写入是裸的，物理光标随逐行写入停在刚写入的行尾，快速滚动时可见——diffRender 整帧包裹 synchronized output（pi BEGIN/END_SYNCHRONIZED_OUTPUT，\x1b[?2026h/l）终端原子应用，写入中途的光标位置不再显示

- **批次 11 ✅（流式期间交互，对照 pi 全状态输入处理逐项核对）**：
  - **watcher 线程接管完整鼠标手势**（用户反馈"流式中不能复制、已输出的块不能展开收起"）：原先流式期间只处理滚轮和跳转标签，其余鼠标事件捕获到回合结束才重放；现在 press/drag/release/move 在 watcher 里实时处理（与主循环同一套 handlePress/handleDrag/handleRelease），流式期间点击工具块展开收起、拖选复制、滚动条拖动全部可用；**序列重组缓冲**（修复点击的 SGR 序列跨 read 分片时首字节 \x1b 被误判为"单独 ESC→中止回合"，会随机中止 turn + 服务器 EPIPE）；**滚动键实时处理**（pageUp/Down/Ctrl+Home/End 原先也被捕获延迟）
  - **流式 thinking 点击收起**（用户反馈"思考输出时可点击收起变成 Thinking..."）：live thinking 收起为单行 `· Thinking…`（dim italic），再点展开；live cache key 含 collapsed 状态；scrollback 中已完成的 thinking 块同样可单块点击收起/展开（thinking_shut 索引表，独立于 Ctrl+T 全局隐藏）；rerenderBlockAtLocked 单块原地重渲染
  - **线程安全加固**：handlePress/handleDrag/handleRelease/scrollbarDrag/scrollbarRelease/copyToClipboard 的锁完善（watcher 线程与 spinner/主循环并发）；copyToClipboard 锁内写避免 OSC52 与帧字节交错
  - **submit 恢复跟随**：发送消息后 scrollToEnd（此前 search reveal disable_follow 后提交新消息视口不跟随，用户看不到自己的消息和回复；pi submit 滚到底部）
  - ~~hint 出现阈值~~（试探后回退：方向感知由终端自然滚动设置决定，非应用层问题；状态机基准验证:底部跟随 + 向下滚 ×N + chunk 交错 = 绝对无动作,上滚 = 真实脱离 + hint,均正确）
  - **流式视口弹跳修复**(用户反馈"流式输出时往下滚会弹来弹去"+ Jump hint 闪烁截图):live 流式尾块原先只在跟随末尾时计入文档——上滚即 following 断开 → live 尾块(几十行)**从文档移除** → doc 突缩、视口上跳;滚回底部 → following 挂上 → live 加回 → 视口下跳,来回滚即反复弹跳;改为**流式尾块始终是文档的一部分**(pi:streaming component 是布局的固定部分),滚动只移动视口、文档不缩放(上滚时尾块在视口下方不可见,视觉不变);collectSearchLines 同步;新增回归测试(流式中上滚:doc_len 恒定 + 视口锚定 + 滚回底部重新跟随无跳变)
  - **渲染防御钳制**(用户反馈:输入框上边框左端偶发 1-2 格工具块色的竖线残块 = 超宽行 wrap 尾巴溢出到下一行):diffRender 对每个变化行做 ANSI+宽度感知的防御钳制(sliceByColumn 到终端宽度;纯 ASCII 短行零开销跳过)——任何来源的超宽行不再污染相邻行
  - **滚动体验修复**(用户反馈"滚动卡、难停、来回滚"):每个 wheel 事件同步全帧 diff 重绘,trackpad 60-120Hz 事件排队超过渲染速度 → 延迟累积过冲;改为**节流渲染**(≥25ms 一帧,scrollBy 逐事件照常应用;跳过的帧由 hide-deadline poll ≤100ms 兜底刷帧,流式期间 spinner 80ms 兜底)
  - **滚动条被块背景盖住**(用户反馈截图):thumb 用前景色 ┃ 绘制,而 replaceCell 的 auto 模式 preserve 把 cell 原背景(工具块绿)重放,灰 ┃ 画在绿底上不可见 → thumb 分段消失;改为 **thumb 不 preserve**(位置指示器必须盖过内容背景),track 保持 pi 一致的隐形
  - **表格右边框不对齐**(用户反馈截图):width.zig 缺 emoji 宽度——✅/❌/🎉 等终端按 EAW=W 渲染 2 列,我们算 1 列 → 含 emoji 的行右 │ 比边框 ┤ 偏右;补 **emoji 宽度表**(EAW=W 的 BMP 范围 + 0x1F000+ 平面 + 区域指示)+ FE0F(emoji 呈现选择符)计 1 列(⚠️ = ⚠1+FE0F1 = 2,与 markdown 逐字符调用路径一致)——表格所有行右边框严格对齐(align 测试 w=74×10)
  - **回退渲染防御钳制**(用户反馈感觉不对):diffRender 恢复裸行写入;竖线残留的正确根因是 emoji 宽度少算导致的行宽溢出,由宽度表修复
  - **滚动流水线深挖**(基准:120×40、200 块/1855 行转录——首帧冷 1ms、滚动帧 avg 0ms/worst 1ms、footer 遍历 0ms):① wheel 事件改用 cached-footer 重绘(原 `redraw()` 每事件全量遍历会话字节做 token 估算,60Hz 事件 = 每秒几十次全内容扫描,长会话上这是滚动卡顿的主因;stats 由 .unknown 兜底路径刷新);② diffRender 帧输出合并为**单次 write**(原每变化行 3 次 syscall ≈ 200 次/帧);③ KeyReader poll 100→33ms(节流跳帧后的尾帧延迟 ≤33ms,顺带 ESC 判定更快);④ `.unknown` 兜底路径改 redrawCached(定时器 tick 不需要重算 stats);⑤ **修 measureSize 健壮性**:ioctl 失败(stdin 非 tty)时保留原尺寸——原代码读未初始化 winsize 的垃圾值,height 可能被设成数万行 → buildTranscript 每帧分配数万空行(基准环境实测 508ms/帧)
  - **流式末尾吸附**(用户反馈"流式中往下滚弹来弹去"的残余:回合流式时文档不断变长,小步下滚永远差 1-2 行够到末尾 → 跟随挂不上、hint 每次闪烁):scrollBy 向下落点距末尾 ≤2 行时**直接吸附到底并重新跟随**(ScrollView SNAP_TO_END_WITHIN)——下滚一定收敛到跟随态,流式期间也不再闪烁;e2e 退出等待改为等回合真正结束("Working" 消失),修掉 Ctrl+C 落在回合内被 watcher 当 abort 的时序竞争
  - **滚轮方向修复**（用户反馈"滚动方向与原版和其它应用相反"）：watcher 的滚轮路径符号写反（SGR 低位 0=上却 scrollBy(+3) 向下）——流式期间滚动方向与空闲时相反；改为与主循环同款语义（wheel 下 → scroll_top 增大 → 视口向尾）并同样接入 WheelScrollAccelerator（连发加速）
  - **表格流式排查**（用户反馈"表格线画好后不再流式"）：12/2 字符粒度模拟 + e2e 慢速流式实测均证明表格逐行流出（top border→空表体→行逐步），本端无停滞；观感停顿来自 provider 端把表格/整行作为大 chunk 发送（常见于非逐 token 流式），如仍复现需 provider/model 信息
  - 验证：test_ui 172（新增流式/已完成 thinking 点击收起测试）；全套件过 + LSP 0；**E2E 第二回合流式段**（服务器第二回合 0.25s/chunk 拉长窗口；基准帧改为等回合完全稳定后截取）：流式中点击 read 块展开（块高 gap 变大判定，容忍视口行漂移）→ 点击 thinking 收起（"Thinking…" 出现）→ 再点展开复原 → 拖选新用户消息复制（OSC52 增量）；调试中先后揪出并修：ESC 分片误中止、watcher 不处理滚动键、e2e 基准帧在流式中截取、Python replay 不排空 pty 导致 zpi 写阻塞持锁全局停摆（测试侧修复）

### Phase G.5 — 滚动渲染深优化（对照 pi tui-main-screen 差分渲染 + 终端原生滚动）

- **滚动帧输出从“全视口重绘”降到“原生滚动 + 只画露出的行”**（用户反馈“滚动效果不是很好”，对照 pi 1.5.0 逐项梳理后定位：每滚一步 transcript 视口 26–50 行逐行 `moveTo`+清行+重写，而 pi 只画变化行/新行）：
  - **垂直位移检测 + DECSTBM 原生滚动**（新 `detectShift/verifyShift`，tui.zig）：transcript 区域在内容上是上一帧的纯垂直位移（滚轮/翻页/流式跟随增长）时，用 `ESC[1;{th}r` 滚动区 + 区底 `\n`×k（上移）/区顶 `ESC M`×k（下移）让终端自己滚，然后只画 k 行露出的内容。位移候选 k 来自**帧间 scroll_top 差值**（buildTranscript 记录 `frame_scroll_top`，diffRender 对比 `rendered_scroll_top`，天然覆盖滚轮/翻页/拖滚动条/搜索 reveal/跳转全部路径；无滚动时回退“底部增长”候选）；验证带内容逐行 memcmp，≤4 个离群行（overlay 标签/搜索框）容忍并逐行重绘，超出即回退全量重绘（正确性不依赖检测成功）
  - **滚动条移入屏幕层**（对齐 pi 布局层 composite 模型）：原 `paintScrollbar` 直接 replaceCell 改写帧行，thumb 随滚动移动 → 位移验证每帧 >4 离群行 → 原生滚动永远触发不了；改为 diff 只看**纯内容行**，新 `paintScrollbarLocked` 在 diff 落屏后按**单元格**修补（新 `overlay.cellReplacement`：只返回单元格替换字节，宽字符跨界含 pad），glyph 类别不变的行零写入；`scroll_glyphs[]` 逐行追踪已画 glyph，原生滚动时随位移整体搬移（`stored'[i] = stored[i±k]`），隐藏时仅恢复内容（本帧已重绘的行跳过）；`scrollbarColumn()` 纯查询供 hint 布局
  - **PageUp/Down 对齐 pi**：`viewportHeight - PAGE_SCROLL_OVERLAP` = 保留 4 行重叠上下文（原 `transcript_h - 1`，翻页“接不上”）；主循环 + watcher 两处
  - **prev 帧所有权移交**：diffRender 接管 frame 行（steal 进 prev_lines），删除每帧“free 全部旧行 + dupe 全部新行”（~80 次/帧）；无变化帧直接释放新帧行保留旧基座；同步维护 `prev_transcript_h`，resize/外部编辑器返回等硬清屏路径重置位移状态
  - 行间改 `\r\n` 链式写入（pi 同款相对移动风格），替代逐行绝对 `ESC[r;1H`
  - **实测**（pty + mock 流式服务器，30×90）：单个滚轮步 3141→638B（DECSTBM+RI ~20B + 1 行露出内容 + hint 离群行 + 2 个 thumb 差量单元格，其余为空闲 poll 帧）；PageUp/ctrl+end 均走原生滚动；会话总输出 336KB→247KB；滚上去/回底逐字节一致、流式中滚动不弹跳等 e2e 14 项全过
  - 单测：verifyShift（up/down/离群/预算拒绝）、detectShift（scroll_delta 定向、流式增长回退、非位移拒绝）4 项进 tui.zig
  - **链式写入跨间隙错位修复**（用户反馈三截图：上滚后 hint 标签在中间列逐行堆叠、stale Working 边框行残留、菜单打开后光标停在输入行下一行）：`\r\n` 链式写入只在“上一画行 == 本行-1”时合法，但绘制循环跳过不需重绘的行后仍沿用链式状态 → 跨间隙的内容全部写到错误的屏幕行（hint 行内容画到 row 1、离群行画丢、后续帧的 diff 基座与屏幕永久不一致）；改为跟踪 `last_painted`，间隙后回退绝对 `moveTo`（pty + pyte 逐字节重放复现并验证：hint 恒在一行、流式中滚动无 stale 行、菜单光标对位）
- **搜索 shift+enter（向上导航）修复**（用户实测反馈失效）：三层键解析对齐——① keys.zig parseCsi 的 Enter(13) 分支补 **alt**（kitty `CSI 13;3u` = alt+enter，此前被映射为 .enter 丢失 steering follow-up 提交）；② ESC CR 恢复**双模式**（kitty 协商成功 → .shift_enter（搜索向上），非 kitty → alt+enter（steering follow-up）——两种终端形态下搜索导航与 follow-up 提交互不抢占）；③ alt+up 解析（kitty 57419+alt，app.message.dequeue）。用户真终端实测确认。已知边界：测试 harness 的 bash 链会屏蔽 SIGTSTP，ctrl+z 挂起需真实终端验证
- **steering / follow-up 运行中输入**（用户要求补齐 pi 的运行中交互）：对照 pi-agent-core agent-loop 语义实现——steering 队列在**每轮 LLM 请求前** drain 进 context（工具调用间生效，pi getSteeringMessages）；follow-up 队列在**回合结束**后作为新回合 prompt 续跑（pi 外层循环）。三层改动：① **agent.zig**：Session 增 steering/followup 队列（Io.Mutex 保护，watcher 线程 push / agent 线程 drain）、runPrompt 外层 follow-up 循环 + 轮首 drainSteeringIntoContext（appendAndRecord 进 context+持久化，无 turn event——TUI 排队时已显示）。② **tui.zig watcher**：运行中键分发重构——可打印/编辑键 live 应用到编辑器（render_mutex.lockUncancelable，pi：编辑器流式期间保持可交互、光标常驻输入框），Enter → queueSteering + 立即显示用户块 + 钉底，alt+enter → queueFollowUp + note，alt+up/alt+v → 恢复队首消息到编辑器（app.message.dequeue）；**watcher 线程渲染调用必须在锁外**（note/addUserMessage 自取非递归锁，锁内调用静默失败），渲染用 redrawCached（redraw 的 computeFooterStats 主线程专用）。③ **keys.zig**：ESC CR 双模式统一解析为 alt+enter（kitty 下 shift+enter 走 CSI 13;2u）、alt+up 解析（kitty 57419+alt）。E2E：运行中排队 fu1/steering → req2 body 含 ['go','fu1','steer me']（fu1 续跑 + steering 注入）✓；alt+up 恢复 ✓。排查备注：lock 是 Cancelable（cancel 点可静默失败）→ watcher 用 lockUncancelable
- **TUI 功能对齐审计 + 六个缺失键位**（用户要求盘点差距并实现）：对照 pi 1.5.0 的 47 个 keybinding 与全部命令逐一核对。**新实现**（pi 默认键位）：shift+tab → thinking 档位循环（app.thinking.cycle，off→low→…→max→off，flash 提示）；ctrl+p / shift+ctrl+p → 模型循环切换（app.model.cycleForward/Backward，按 cfg.models 展平列表 wrap）；ctrl+l → 模型列表展示（app.model.select 的弱选择器替代）；ctrl+x → 复制选区或最后 assistant 回复（app.message.copy，OSC52）；ctrl+z → 挂起后台（app.suspend，restoreTerminal → SIGTSTP → SIGCONT 后 resumeTui 全量重绘）；ctrl+d → 空编辑器时退出（app.exit）。附带修复：copyLastMessage 漏 redraw 导致 flash 不显示；openExternalEditor 用 std.os.linux.getpid()（macOS 假实现）改 std.c.getpid()。E2E 6/6 过。**已实现清单**（详见本条目后附表）与**暂缓差距**（steering/follow-up 排队、图片粘贴/文件拖放、/themes /settings /skills /trust /login /share /import /clone、editor undo/kill-ring、app.session.toggleNamedFilter）见审计表
- **欢迎头对齐 pi 结构与文案**（用户反馈：pi 继续会话时欢迎/技能信息不展示在历史下，要求对齐）：查证 pi 结构——headerContainer 是 documentContainer 的子节点，**欢迎头就是滚动文档的第一块**（随文档滚动，继续会话时视窗钉底故日常不可见；技能列表默认隐藏仅 verbose 展开；changelog 有历史时跳过）。我们此前把欢迎信息用 addMessage 加在 run() 里——排在 replaySession 的历史**之后**，夹在历史和输入框之间。修复：新增 `addWelcomeHeader()`（bold wordmark `zpi` + dim `v0.1.0` + muted 快捷键行 `esc interrupt · ctrl+c clear/exit · / commands · ctrl+o tools · ctrl+t thinking` + dim onboarding 行，对齐 pi compact header 文案），replaySession 开头先加欢迎头再回放历史（header 恒为文档首块）；删除 run() 里的旧欢迎块（模型信息 footer 已有，对齐 pi）。实测：新会话顶部显示新欢迎头、继续会话底部视口纯历史、181+153 测试全过
- **`-c` 回放宽度错误**（用户截图：历史内容固定半屏 ~80 列宽，不铺满终端）：replaySession 在 run()/setupTerminal 之前执行，此时 width 仍是 init 默认 80——所有回放块按 80 列渲染；而 setupTerminal 的 measureSize 只改字段不触发重渲染，首帧 refreshSize 比较发现“无变化”，rerenderAtWidth 永不执行，80 列渲染永久保留。修复：replaySession 开头在 render_mutex 下先 measureSize() 再渲染。实测 117 列终端下历史内容铺满全宽（气泡/文本/工具块），181+153 测试全过
- **`-c`/`-r` 继续会话界面回放**（用户反馈：`zpi -c` 不能继续会话）：对比 pi 原版发现上下文恢复其实早已实现（`-p` 模式验证通过、branchMessages → session.context），缺的是 **TUI 界面回放**——pi 启动时 `renderInitialMessages → renderSessionEntries` 把持久化消息渲染进 chat（assistant 文本/thinking 为消息块、toolCall 为工具块、toolResult 按 id 配对回填）。修复：TUI 新增 `replaySession()`（main.zig 启动时调用，无 store/空分支 no-op）——user → 用户消息块（多 text 拼接）、assistant 按块序 thinking/text/tool_call → thinking 块/markdown/折叠工具块（ToolEntry 直接入列）、tool 角色 → 按 tool_call_id 匹配回填结果。实测：-c 打开后历史完整可见（thinking、用户消息、markdown 回复、`edit ~/.pi/agent/models.json` 折叠工具块），滚动可及；新会话启动无变化；181+153 测试全过
- **流式输出平滑化**（用户反馈：对比 pi 原版，流式文本“很生硬、一段段往外蹦”，怀疑少了打字机效果）：pi 并无打字机动画——它对每个 message_update requestRender、16ms 节流，平滑感来自“包级到达 × 高频渲染”。我们三层各有阻塞：① **SSE 客户端攒批**：`readAllocShort(dest, 4096)` 的 readSliceShort 只有攒满 dest 或 EOF 才返回，把平滑到达（实测 socket 级 2-3ms/事件）攒成 ~70-100ms 的 4KB 块；改 `takeDelimiterInclusive('\n')` 逐行即时处理（注意：takeDelimiter**Exclusive** 不消费分隔符，`
` 留在缓冲头导致每次返回空切片的死循环——std 文档与实现不符的坑）。实测到达 627 行/789ms、中位 1ms。② **渲染窗口拼装 bug**：buildTranscript 在 `scroll_top > doc_lines.len`（流式时 committed 行数少）时从 live[0] 开始填窗口——增长的新内容永远在窗口之下不可见，文本只在回合提交时一次性出现；修复为按 `start - doc_lines.len` 跳进 live 尾部。③ **spinner 节奏**：流式帧此前搭 80ms spinner tick（12.5fps）；改固定 22ms 时钟（自适应 dirty-flag 方案实测会被到达停顿的相位卡回 80ms，弃用），spinner 字形仍按 80ms 推进。**验证**：尾部逐帧连续推进（段落 2→19→29→43→57→71→79）、显示更新中位 42ms（原 85-90ms）、有效 ~24fps；回归：光标 park、到底惰性、抖动拉拽 3/3 全过。附注：滚轮加速器按手势速率限制行数（pi 语义），上行爆发后需对称量才能滚回——测试曾误判为回归
- **滚动期间光标外泄修复**（用户反馈：上拉时输入光标跑到滚动条处、停止时跳到内容最后一行末尾，打字才回输入框）：根因是上一项“光标 park 去重”破坏了帧不变量——**任何写入屏幕字节的帧都会移动硬件光标**，而去重让“位置未变”的帧跳过 park；滚动帧的 body 恰恰只含滚动条 cell（拉拽时）或暴露行（停止时）→ 光标遗留在最后写入的 cell 之后。修复：去重仅对**完全空 body** 生效，body 有任何字节都必须重发 park（隐藏态 sticky 除外）。帧边界采样验证：上拉 24/24、下拉 44/44 帧终光标均在输入行； 到底惰性/空闲往返/抖动拉拽回归全过
- **到底惰性 + 空闲管道 chatter 消除**（用户反馈：到底后连往下拉“还能触发”并堵塞后续上翻，拉一次则无碍；空载消息展示完时拉卡）：定位发现两处无谓的帧写字节——① diffRender 的 no-change 早退路径仍写同步标记+光标 park 字节（33ms 一 tick 的空帧 chatter）；② 主循环 .unknown tick 无条件重绘。修复：光标 park 状态去重（`cursor_park_key`，无变化不发射）+ 无 diff 帧零写入（`flushFrameBytes` 空体直接返回）+ tick 仅在有 pending 帧/滚动条期限跨越/flash 清除时重绘。**实测：到底后 10 次下拉 = 0 字节输出**（完全惰性），上拉响应 47-50ms、下拉清除 8-39ms；流式带横向噪声连续拉 0 次闪跳
- **滚轮幽灵上滚 + 输入积压修复**（用户反馈：拉一次弹一次、连续拉一直弹；流式期间连续拉 3~4 次像卡住、上翻无响应、等一会儿积压事件集中释放成“一直往上滚”；回合结束后拉则完全正常）：
  - **幽灵上滚（主因）**：watcher 的滚轮分支把一切带 bit-64 的鼠标事件都当垂直滚轮——**水平滚轮（button 66/67，低两位 = 2/3）被当成 wheel-up**；真实拉拽必带横向抖动 → 每次拉产生幽灵上滚（following 断开、视图上跳）→ 下一个垂直事件又被 SNAP 吸附回终点（大跳）→ “拉一次弹一次”；pi 的 `parseWheelEvent` 明确拒绝 direction 2/3，主循环路径已过滤而 watcher 路径漏了 → 补齐（对齐 pi）
  - **输入积压（卡住/延迟连滚）**：流式回合中 spinner 帧（80ms，持锁含 writeRaw）、网络线程（每 delta 追加缓冲）、turn_event 提交（完整 markdown 渲染）激烈竞争 render_mutex；watcher 的 scrollBy 阻塞等锁 → 拉拽延迟应用、可见的突发跳动；修复：`TUI.scrollBy` 改 tryLock——拿不到锁把增量记入 `pending_scroll` 原子变量，由下一帧（spinner ≤80ms）在 redrawLocked 顶部统一消化（pi 单线程 requestRender 合并的等价物）；回合中滚轮不再自绘全帧（spinner 帧代劳），消除与 spinner 的锁竞争
  - **事件丢弃**：watcher 输入缓冲 256B，快速连续拉拽超限即整批丢弃（“卡住”）→ 扩到 4096B
  - **验证**：pty 复现脚本注入横向噪声（66/67）模拟真实拉拽，30 次连续拉拽 0 次 hint 闪跳、上翻 1.5s 内响应、回合结束无卡死；181 + 153 单测全过
- **滚动条底边量子抖动修复**（用户反馈：往下拉到底后视图“自动回弹一点上去”、Jump to latest 提示反复闪现又消失；而提示只应在往上拉看历史时出现）：
  - **定位**（排除法 + pty 逐帧监测）：滚轮路径的簿记在静态/流式/工具会话下全部自洽（following 不翻转）；闪跳源在**滚动条指针导航**的映射量子——1 行轨道行 ≈ ceil(max_scroll_top/可偏移行数) 行文档（大文档数百行），底边指针抖动/流式增长导致同指针行重映射 → target 在 max 与 max-量子间交替 → following 反复翻转（pty 复现 19 次闪跳/8s）+ 视图按量子跳动（“回弹”）
  - **修复**：`ScrollToOptions.snap_end`——指针 target 落在一个映射量子内时吸附到终点（与 scrollBy 的 SNAP_TO_END 同思想、阈值随文档大小缩放）；底边悬停从此“粘住”终点，流式增长时 following 保持接合、hint 稳定；非指针导航（搜索 reveal、消息跳转）不受影响；2 个新单测锁底边吸附与流式增长下的持续跟随
- **流式 markdown 增量渲染**（用户反馈“markdown 渲染后滑动变卡”；基准定位：`liveBlockLocked` 每个 chunk 全量重渲染整个流文本，48KB 流时 spinner 帧 26.8ms 且持 render_mutex，滚轮事件等锁 → 滚动变成幻灯片）：
  - **块级增量缓存**（`StreamPrefix`，tui.zig）：流文本是 append-only，markdown 块以空行分隔、上下文无关 → 稳定前缀按行缓存（`prefix_bytes/prefix_rows`），每帧只重渲染“上帧后完成的块 `[prefix_bytes, boundary)` + 正在增长的尾块”；`stableBlockBoundary` 取最后一个空行后的边界，未闭合代码围栏把边界钉在围栏开行（围栏永不拆分）；流重置（buffer 变短）/宽度变化自动全量重建
  - **跨段 gap 状态下沉到渲染器**（新 `markdown.renderSegment`）：块间空行由相邻两块的类型组合决定（`gapAfter`：para→table 有空行、para→list 无、list 后无），分段独立渲染会丢失该判定；新 API 携带 `prev_kind`（上一段尾块类型）跨段续接，拼接输出与全量渲染**逐字节一致**（`blocksNeedGap` 抽取自 gapAfter，单源）；`strip_trailing` 参数区分中段（保留尾空行 = 段间 gap，属于稳定前缀）与流尾（剥掉，pi “无尾空行”语义）；`renderWith` 改为 renderSegment 的全量封装，逻辑单源
  - **实测**（ReleaseFast）：spinner 帧 4KB 2.83ms→**0.14ms**、16KB 9.39→**0.15ms**、48KB 26.78→**0.19ms**（与流长度脱钩）；流首帧冷渲染一次性 17.7ms@48KB，稳态增量帧 0.09ms；idle 滚动帧 markdown 重转录 0.12ms 不变
  - **正确性**：新单测“逐 chunk 增量渲染 == 全前缀全量渲染”（17B 步长刻意对不齐切块，覆盖段落/表格/代码围栏/列表/CJK）+ `stableBlockBoundary` 边界/fence 钉扎 4 例；pty+pyte E2E（40 段中文 markdown 流式 + 期间滚轮上滚 6 步回滚到底）：段落 39 落底、表格框完整、围栏内容可见、hint 恒 1 行、无 stale 行，全过
  - **顺手修**：基准脚本 `buildTui` 把 model/provider/registry 放在函数作用域 → Session 持栈指针悬垂（ReleaseFast 才崩，lldb 定位）；提升为堆上 Fixture；新增 `bench_scroll.zig`（markdown vs plain 滚动帧）、`bench_stream.zig`(流式帧 vs 流长度)、`bench_markdown.zig`（单块渲染成本）三个性能工具

- **SSE 流韧性 + 静默中断修复**（用户反馈"整个任务没完成就中断了"；会话 jsonl 分析定位三个无声失败点）：
  - **SSE 断流被当作成功（主因）**：`sse.zig`/`openai.zig` 的流读取循环里 `EndOfStream`/`ReadFailed`（网络抖动/代理断连）直接 `break` → `return .ok`——没收到 `[DONE]` 也算成功；agent 层收到空 assistant 消息后 `blocks.len==0` 静默 `break`，turn 无声死亡（会话日志末条正是"assistant toolUse 后无 toolResult"）。修复：断流 → `.transport_error`（自动重试 3 次退避，已流出内容按 provider 层 had_output 语义处理）；"干净结束"按协议判定——OpenAI 看 `[DONE]`，Anthropic 看 `message_stop`，Google 看 `finishReason`，Responses 看 `response.completed`（provider 结构体 `stream_done` 标志，`sse.postSse` 用 `@hasDecl` 鸭子类型查询）；空响应 → `error.EmptyResponse`，TUI 显示 `[error: EmptyResponse]`（三处 runPrompt 调用点原先两处吞错一处显示，补齐）
  - **工具轮次上限静默退出**：`max_tool_rounds` 50 触顶时循环无声跳出（长任务 40+ 轮很常见）→ 上限提到 200，触顶时 emit 提示行 `[stopped: tool-round limit reached (200 rounds). Send '继续' to resume]`
  - 验证：全套件过（test_ui 234 / leak_g2 184 / openai 10 / mcp 9 / pt 4 / clip 2 / keys 18）
- **steering/follow-up 与 pi 深度对齐**（用户要求对照原版 working/compacting 时输入新任务的回车逻辑）：对照 pi 1.5.0 `interactive-mode.js`/`agent-session.js`/`PendingMessageQueue` 逐项核查，原有实现已覆盖 Enter=steer / alt+Enter=follow-up / compaction 入队 / ESC 取消压缩，补齐 4 个差距：
  - **ESC 中断恢复队列**（pi `restoreQueuedMessagesToEditor({abort:true})`）：ESC/Ctrl+C（kitty 含 CSI-u）中断时把**全部**排队消息（steering 在前 + follow-up，`\n\n` 拼接）放回编辑器并前置到当前文本，再 abort——原先直接 abort 队列留在原地用户以为丢了。`Session.restoreQueued()` 排空两队列返回拼接文本；顺带修 watcher ESC 后 `return` 杀掉 watcher 线程的问题（改 `continue`，中断后 UI 存活）
  - **alt+up dequeue 语义**（pi `app.message.dequeue`）：恢复**全部**排队消息到编辑器（原先只有 alt+v 且只恢复一条 follow-up、覆盖当前文本）；hint 行补 `alt+up to edit all queued messages`
  - **`/` 命令运行中立即执行**（pi extension commands 永不进 steering 队列）：watcher Enter 分支 `/` 开头直接 `handleCommand`（`/exit` 置 `cmd_exit_requested` + abort，主循环 turn 结束后 break）。修死锁：`handleCommand` 原在持 render_mutex 期间执行，内部 addMessage 再锁同一把不可重入 mutex 永不返回——锁内只读/清编辑器，锁外执行命令与入队
  - **steeringMode/followUpMode 接线**（pi 默认均 one-at-a-time）：TUI 的两个设置项原先从未传给 Session；现 settings.json `steeringMode`/`followUpMode` 解析进 config → init 时传 Session，设置选择器改动即时同步；turn 结束取 follow-up 按 mode（`all` 全部取出合并为一个新 turn，`one-at-a-time` 只取最旧一条）。新增 working 期间 **pending 行实时渲染**（pi `updatePendingMessagesDisplay`：编辑器上方 dim 的 `Steering: …`/`Follow-up: …`，`queuedPeek`/`queuedPeekLen`）
  - 验证：pty 端到端（真实模型流式中）——Enter 入队显示 `Steering:` 行、alt+Enter 显示 `Follow-up:` 行、ESC 1.1s 内 abort 且两条消息拼接恢复回编辑器、`/help` 运行中立即执行不进队列；`test_pending.zig` 2 个新单测（pending 行渲染 + restoreQueued 拼接语义）
- **编辑器鼠标选区/粘贴/复制**（用户反馈批次：选区响应、多行粘贴、Terminal.app 剪贴板）：
  - **选区响应性**：editor.handleKey 去掉全量 `clearSelection()`（只有改文本的键清选区，ESC 清选区）；`insertChar` 替换选区；修 `replaceSelection` 多行截断 bug（`shrinkRetainingCapacity(removed)` 误删后续行 → 精确释放 `(start.line, end.line]` + 左移）
  - **wrap 缓存**（editor.zig）：`wrap_cache/wrap_gen` 等字段 + `invalidateWrapCache()`/`wrappedView()`/`firstVisualRow()`（二分）/`visualRowLine()`/`countLogicalLines()`/`visualLineCount()`——render/highlightSelection/visualToLogical/cursorVisualPos 共享，选区高亮不再逐帧全量 wrap
  - **bracketed paste**（`ESC[?2004h`）：KeyReader 把 `ESC[200~...ESC[201~` 块收为单个 `.paste` Key（16KiB 缓冲、330ms stall flush），TUI 路由 `editor.pasteText`（多行拆分、CRLF trim、替换选区）——修复多行粘贴逐行提交
  - **多击**：keys.zig 解析 5 字段 SGR multi-click 后缀 + TUI 500ms 时间/位置连击兜底；双击选词（CJK 逐字）、三击选行（editor + transcript，`selectWordOrLine`/`selectDocWord`）
  - **剪贴板双通道**：`clipboard.writeClipboardText`（macOS pbcopy / Windows·WSL PowerShell / Linux xclip·wl-copy）+ OSC52 同时发送——Terminal.app 忽略 OSC 52 的场景（"Copied!" 显示但剪贴板为空）修复；`copyToClipboard` 两路并发。Zig 0.17 坑：`Child.wait()` 前必须 `stdin.close()` 且置 `child.stdin = null`（否则 double-close）
  - 验证：pty E2E（SGR 鼠标序列注入 → 断言 OSC52 字节 + `pbpaste` 内容一致）；test_ui 234 / keys 18 / clip 2 全过
- **`/skill:name` 不再刷屏（对齐 pi SkillInvocationMessageComponent）**（用户反馈：用技能时整个 SKILL.md 正文铺满内容区）：对照 pi 1.5.0 `skill-invocation-message.js`——模型收到完整 `<skill>` 块（`_expandSkillCommand` 不变），但**转写只渲染一行** `[skill] name (ctrl+o to expand)`（customMessageBg 背景 + bold label + muted 提示），点击或 Ctrl+O 才展开完整正文（`**name**` + body markdown）；`/skill:name args` 的 args 作为**独立 user 消息**渲染在块下方（pi：userMessage 与 skill 块分离）。实现：`SkillEntry`（name/location/content + `expanded ?bool` 跟随全局 tools_expanded + `block_idx`，session allocator）+ `BlockSrc.skill` + `parseSkillBlock`（对齐 pi 正则语义：`<skill name=".." location="..">\n…\n</skill>` + 可选 `\n\n` user 消息尾）；`addSubmittedMessage` 统一四个提交路径（编辑器/命令/compact 队列/回放）+ `-c` 回放路径（持久化的 `<skill>` 消息重放为折叠块，不再重放整篇 markdown）；`setToolsExpanded` 同步重置并重绘 skill 块（pi 遍历所有 expandable chat 子节点）；鼠标点击 `skillAt` 切换（与 toolAt/thinkingShutAt 同派发链）。验证：test_ui 236（新增 2：折叠单行 + 点击展开 + Ctrl+O 联动；args 独立 user 块）；pty E2E 8/8（折叠行/正文不刷屏/args 独立/请求体含完整 `<skill>` 块）+ `-c` 回放 E2E 3/3
- **长会话可靠性：SSE 空闲看门狗 + 空响应自动重试 + 长度截断恢复 + 纯思考回合轻推**（用户反馈：GLM 网关长会话中反复 `EmptyResponse`，且一次 3 分钟 thinking 后无输出卡死——对照 pi 1.5.0 `http-dispatcher.js`/`retry.js`/`overflow.js` 三层防护逐项对齐）：
  - **P0 空闲看门狗**（新 `src/ai/stream_guard.zig`）：SSE 读是主线程阻塞 `read(2)`——网关"已连接后静默"时无超时、ESC 也无法打断（abort 只在行间检查）。看门狗线程 250ms 轮询 `isAborted()` + 空闲计时，任一触发即 `std.c.shutdown(fd, SHUT_RDWR)` 解除主线程阻塞，读返回错误后走既有 retry/abort 机制。`Guard(@TypeOf(session))` 泛型工厂（Zig 0.17 闭包不能捕获 anytype）；`noteData()` 每行重置空闲窗；idle 默认 300s（pi `DEFAULT_HTTP_IDLE_TIMEOUT_MS`），`$ZPI_HTTP_IDLE_TIMEOUT_MS` 可调、`0` 关闭。`openai.zig` 与 `sse.zig`（anthropic/google/responses 共享）同款接线；**abort 检查移到 `.ok` 短路之前**（shutdown 使 tryStream 对截断流返回 .ok，须先判 abort 区分 ESC 与正常结束）
  - **P1 空响应自动重试**（agent.zig runPrompt）：网关偶发 200 + 空/截断 SSE 体 → 原直接 `return error.EmptyResponse` 死回合；改为指数退避重试（1s/2s/4s，默认 3 次，`emptyRetryDelayMs` 可单测），TUI 显示 `[empty response — retrying (n/3)]`，真实响应到达后预算重置；abort 感知退避
  - **P2a 长度截断恢复**（pi `isRecoverableLength`）：`stream_finish == .length` 且 `usage.output < model.max_tokens` → 上下文压力/网关截断，一次性 compact-and-retry（`length_recovered` 防循环，每回合重置）；`onStreamEvent .done` 捕获 finish reason
  - **P2b 纯思考回合轻推**：某轮 blocks 全为 thinking（无文本无工具调用，`msg.blocksAreAllThinking`）→ 注入一次 continue 提示消息重入循环（`thinking_nudged` 每回合限一次）——模型把输出预算耗在推理上后不再静默停摆
  - 验证：全套件 611 过（test_pending 156 新增 3：退避序列/all-thinking 判定/isRecoverableLength 五分支）；**pty E2E 10/10**（① mock 服务器"连接后零字节"挂起：idle 1s 下 12s 内有限失败不再无限挂起、进程存活、失败后仍可交互；② ESC 在阻塞 read 中 <2.5s 解锁回输入行；③ 200+`[DONE]` 零内容块 ×2 后第 3 次正常响应：retry flash 可见、回合自动恢复出结果）。附带：`outputCallback` 的 `.tool_info` 从静默丢弃改为 flash 提示（恢复类通知可见，trim 首尾换行）
### Phase H — 资源系统（~1.5k 行）
- [x] H1 Skills：`skills.zig` 发现/解析/校验/去重 + 系统提示广告 + `/skill:name` + `/skill:<tab>` + 6 单测 + E2E（`15ade5a`）
- [x] H2 Prompt templates：Phase D 完成（发现/$1/$@/默认值/未识别 slash 回退）
- [ ] H3 主题文件发现与加载（JSON 主题 + /settings 切换）
- [ ] H4 `.pi/` 项目配置 + trust 门控（`-a/-na`、`/trust`）
- [x] H5 `/reload`：重载技能 + 重建系统提示 + 更新 context

### Phase I — 扩展系统（~1.5k 行，零依赖方案）
> 决策（已定）：**不用内嵌解释器，不 vendor QuickJS**。扩展 = 声明式配置 + 钩子脚本 + 编译期注册三层，覆盖 pi 扩展 80% 实用场景。
- [x] I1 命令工具：settings/项目 `.pi/settings.json` 的 `"commandTools": [{name, command, description, schema}]`（`src/tools/command_tools.zig`）——JSON args 走 stdin、stdout（4KB cap）即结果、非零 exit = is_error（含 stderr）；名字校验 `[A-Za-z0-9_]`、重名后者覆盖（global→项目合并）；exposure=direct
- [x] I2 钩子（hooks）：`<agent>/hooks.json` + 项目 `.pi/hooks.json`（**trust 门控**，条目合并）（`src/core/hooks.zig`）——`pre_tool_call`/`post_tool_call`（可 `tools` 过滤、`timeout_ms` 100-120s 默认 10s）/`input`/`session_start`/`compaction`；stdin 收 JSON payload（tool/args/result/text/cwd）；**exit 2 = block**（stderr 即给模型的 reason）、exit 0 = 放行、其它 = 非阻断错误；实现 = spawn + `Io.File.MultiReader` drain（fill timeout 到点 kill）+ stderr 读端关闭后置 null（BADF 教训）；agent `execToolTimed` 头部 pre（block → "blocked by hook: <reason>" is_error）+ 尾部 post
- [x] I3 事件总线（`src/core/events.zig`）：session_start / pre_tool_call（可 block，first-reason-wins）/ post_tool_call / input（TUI submit，block = 拦截输入 + note）/ compaction（runCompaction）；同步监听器列表 + 全局 handle（setGlobal）；hooks 引擎以 listener 形态挂接（I4 内置扩展形态的同一挂载点）
- [ ] I4 编译期扩展点：仓库内 `src/ext/builtin/` 模块 comptime 注册（对齐 pi 的 `builtin:mcp` 模式），功能以“内置扩展”形态交付
- [ ] I5 资源打包即扩展：skills/prompts/themes/hooks 目录本身可分发（配合 K4 package 安装）
- [ ] ~~codemode~~：**砍掉**（需 C 解释器）。其核心价值改为原生实现：**并行工具执行**（独立 tool call 线程池并发 + 按 id 归位），归入 A 阶段
- [x] tool_search：`src/tools/tool_search.zig`（BM25 分词/排名 + 搜索装载工具），随 J3 exposure 落地

### Phase J — MCP 客户端（~2k 行）
- [x] J1a JSON-RPC over stdio；tools/list、tools/call（全链路 E2E 验证）
- [x] J1b resources/list、resources/read（全局工具聚合 + cursor，E2E 验证）
- [x] J2 streamable HTTP + bearer 认证（SSE/JSON 双解析、session-id、Bearer；E2E 含需鉴权服务器）
- [x] J3 mcp.json 加载（用户/项目覆盖规则）+ `/mcp` 状态列出（后升级为 pi McpManagerView 交互式管理器：servers→server→tools/exposure 三层菜单 + enable/disable/reconnect 写回，见矩阵）
- [x] J4 `zpi mcp add/remove/list/login/logout` 子命令（login/logout 存 `mcp-auth.json`）
- [x] J5 exposure 模式（pi 四值：`direct` 直接声明；`codemode`（默认）/`deferred` 注册但**不声明**，由 tool_search 装载；`hidden` 不注册；`toolExposure` 单工具覆盖待 I 阶段）。zpi 适配：codemode 服务器自动激活 `tool_search`（pi 激活 codemode 脚本工具；zpi 无 codemode 以 tool_search 兜底）
- [x] J7 `tool_search` 工具（pi BM25 同款：分词=camelCase 拆分+停用词+naive 单数化（Intl.Segmenter 的 ASCII 近似）；k1=1.2 b=0.75；name 权重 3 / namespace 0.5（namespace=MCP 服务器 description）；exact-name 查询最优先、coverage 次之、score 再次、并列保持文档序）。注册即 inactive；激活路径：`--tools tool_search`、`+tool_search`、defaultTools 设置、搜索性 MCP 服务器自动激活。装载=翻 active 位，下一轮请求即声明（E2E 双轮验证）
- [x] J8 工具选择 × MCP（pi sdk.js `_isAllowedTool` 语义）：`-nt`（noTools=all）禁一切含 MCP 不注册；`-nbt`（noTools=builtin）只禁内置；plain `--tools` 替换内置、仅当含 `mcp__` 前缀条目时过滤 MCP（未匹配者不注册、tool_search 未列入亦不注册）；全 modifier 修改默认集且 MCP 绕过；`--exclude-tools` 波及一切（MCP 不注册）。Registry：`Tool.exposure`+`Tool.active`、`activateOnly`（inactive 保注册）、`removeMatchingOn`、`toolSchemasJson` 只出 active + JSON 字符串转义（修 request 体裸换行 bug）
- [ ] J6 OAuth 浏览器流程（以 login 存 token 近似；完整 OAuth 待做）

### Phase K — JSON/RPC 模式与分发（~2k 行）
- [ ] K1 `--mode json`：事件全集（agent_start/turn_*/message_*/tool_*/compaction/...）
- [ ] K2 `--mode rpc`：命令集（prompt/get_state/abort/set_model/...）+ 事件流 + 扩展 UI 记录
- [ ] K3 `/share`（gist 最小实现，radius 可选）、`/bug`（可裁剪）
- [ ] K4 子命令收尾：`pi config`、`pi list`、`--export`、`--version`、`--help` 全量对齐；package 安装（npm 源最小化 = tarball HTTP 下载 + std.tar 解包，无 npm 进程依赖）
- [ ] K5 **跨平台矩阵发布**：darwin/linux/windows × x86_64/aarch64 六个静态二进制；windows 终端 raw mode 用 Win32 Console API（OS API 不算依赖）；HOME→USERPROFILE；CI 矩阵构建
- [ ] K6 `pi update` 自更新（可裁剪：检查 release 版本号 + 替换自身二进制）

### Phase L — /settings 占位项接线清单（对照 pi settings-selector，逐项待后端）
> 22 项设置已在 /settings 里可循环切换（会话态，placeholder_idx），
> 但 zpi 尚无对应子系统——各子系统落地时按本清单补：**持久化键名
> （与 pi settings.json 完全一致，双向兼容）+ 功能消费点**，然后把该
> 项从 placeholder_idx 迁到真实字段（参照 skill_commands/autocomplete_max
> 的接线模式：settingsApplyNext 写字段 + 消费点读字段）。

| 设置项（pi id） | pi settings.json 键 | 待实现的后端 | PLAN 关联 |
|---|---|---|---|
| Show images (show-images) | `showImages` | 终端内嵌图片渲染（sixel/kitty/iTerm2 协议） | — |
| Image width (image-width-cells) | `imageWidthCells` | 同上（内嵌图宽度） | — |
| Auto-resize images (auto-resize-images) | `autoResizeImages` | 图片 resize（发模型前 2000x2000 上限） | — |
| Block images (block-images) | `blockImages` | 图片附件发送开关（消息组装过滤 image 块） | — |
| Show hardware cursor (show-hardware-cursor) | `showHardwareCursor` | 光标绘制策略（终端光标 vs 自绘） | — |
| Editor padding (editor-padding) | `editorPaddingX` | 编辑器水平内边距（0-3） | — |
| Output padding (output-padding) | `outputPad` | 消息/工具输出水平内边距 | — |
| Clear on shrink (clear-on-shrink) | `clearOnShrink` | 差分渲染的收缩清行策略 | G.5 |
| Terminal progress (terminal-progress) | `showTerminalProgress` | OSC 9;4 进度指示（终端 tab 标题） | — |
| Transport (transport) | `transport` | stdio/HTTP 多传输 provider 支持 | — |
| Session share destination (share-destination) | `sessionShareDestination` | /share 的 Radius/Gist 上传后端 | K3 |
| HTTP idle timeout (http-idle-timeout) | `httpIdleTimeoutMs` | HTTP 客户端空闲超时（本地慢模型） | — |
| Cache warming (cache-warming-mode) | `cacheWarmingMode` | prompt cache 预热（off/streaming/idle） | 6 节 cache 行 |
| Mermaid diagrams (mermaid-rendering) | `mermaidRendering` | Mermaid→Unicode 图渲染 | — |
| Cache miss notices (cache-miss-notices) | `showCacheMissNotices` | cache 成本/恢复诊断的 transcript 通知 | — |
| Collapse changelog (collapse-changelog) | `collapseChangelog` | 更新后的 changelog 折叠展示 | K6 |
| Quiet startup (quiet-startup) | `quietStartup` | 启动头精简（只留 header） | 7 节 header 行 |
| Install telemetry (install-telemetry) | `enableInstallTelemetry` | 匿名版本 ping（zpi 大概率不做） | — |
| Double-escape action (double-escape-action) | `doubleEscapeAction` | 空编辑器双 Esc 的动作（清除/退出） | — |
| Tree filter mode (tree-filter-mode) | `treeFilterMode` | /tree 打开时的默认过滤 | — |
| TUI mode (tui-mode) | `tuiMode` | regular 模式（终端原生 scrollback） | K5 前 |
| Theme (theme) | `theme`/`lightTheme`/`darkTheme` | H3 主题 JSON + picker（切值后重载配色） | H3 |

接线模板：① config.applySettingsValue 解析对应键 → 真实字段；②
settingsApplyNext 占位分支迁移到字段写入 + persistSettings；③ 消费点
读取。已按此模式接线的参考：autocompact / skill_commands /
autocomplete_max / steering_mode / follow_up_mode / hide_thinking /
default_project_trust / fs_scrollbar / fs_copy_on_select /
fs_wheel_lines。

## 三、实施原则

1. **每步可编译** — 每个 commit `zig build` 通过，`--list-models`/`-p` 可验证
2. **所有权契约** — 堆分配字符串所有权随返回值/容器转移；`free("")` 安全兜底 OOM；禁止返回栈指针（已两次踩坑：system prompt 栈临时、read 栈缓冲）
3. **零依赖、全平台** — 纯 Zig std，不 vendor C，不链接第三方库；平台差异用 `builtin.os.tag` + OS 原生 API（Win32 Console、POSIX termios）解决；**任何平台路径/shell/终端代码不允许假设 POSIX**
4. **行为对齐 pi** — 格式（session v3、settings/models.json/mcp.json schema）优先兼容，能用原版 pi 直接读写的格式绝不自创
5. **参考原版源码** — pi 源码在 `~/.pi/agent/install/releases/*/node_modules/@earendil-works/pi-coding-agent/dist/`（js + sourcemap 内嵌 ts 源码），行为细节以它为准
6. **先核心后外围** — A→B→C 是骨架；G/TUI 最大，安排在数据层稳定之后

## 四、预估工作量

| Phase | 预估行数 | 复杂度 | 依赖 |
|---|---|---|---|
| A. Agent 健壮化（含原生并行工具执行） | ~1,800 | 中 | - |
| B. 会话持久化 | ~2,000 | 高 | A |
| C. 压缩 | ~1,000 | 高 | B |
| D. 上下文组装 | ~1,000 | 中 | B |
| E. 工具对齐（含 shell 抽象/原生 grep/find/ls） | ~2,000 | 中 | - |
| F. Provider 扩展 | ~2,500 | 高 | A |
| G. TUI 对齐（含 windows 终端层） | ~4,500 | 极高 | B/D |
| H. 资源系统 | ~1,500 | 中 | D |
| I. 扩展系统（声明式+钩子+comptime，无解释器） | ~1,500 | 中 | H |
| J. MCP | ~2,000 | 高 | E/I |
| K. JSON/RPC/分发（含六平台矩阵） | ~2,000 | 中 | B/I |
| **总计** | **~21,800** | | 当前已完成 ~2,400 |


---

## 附：TUI 功能对齐审计表（对照 pi 1.5.0，2026-11）

### 命令

| 命令 | pi | zpi | 状态 |
|---|---|---|---|
| /help /clear /exit /quit /hotkeys | ✓ | ✓ | 已实现 |
| /model [name] | ✓ | ✓ | 已实现（模糊匹配切换） |
| /think [level]（pi: /thinking） | ✓ | ✓ | 已实现（off/low/medium/high/xhigh/max） |
| /session /name /new /tree /fork /resume | ✓ | ✓ | 已实现 |
| /compact [hint] | ✓ | ✓ | 已实现（runCompaction + auto-compact 阈值） |
| /changelog | ✓ | — | 无版本日志体系，不适用 |
| /export /copy /share | ✓ | /copy 未做 | 缺口（copy/export 低成本可加） |
| /themes /settings /skills /trust /login /logout /scoped-models /mcp | ✓ | — | /settings ✅、/skills（`/skill:name`）✅、/mcp ✅；/themes /trust /login /logout /scoped-models 暂缓（依赖主题/trust/扩展体系） |
| /bug /debug /clone /import /reload /fork-easter-eggs | ✓ | — | 暂缓 |

### 全局键位（主界面）

| pi action | 默认键 | zpi | 状态 |
|---|---|---|---|
| app.interrupt | esc | ✓ | 已实现（中止运行中回合） |
| app.clear | ctrl+c | ✓ | 已实现（清空编辑器/退出） |
| app.exit | ctrl+d | ✓ | 本轮实现（空编辑器退出） |
| app.suspend | ctrl+z | ✓ | 本轮实现 |
| app.thinking.cycle | shift+tab | ✓ | 本轮实现 |
| app.thinking.save | ctrl+s | — | 暂缓（保存档位到 settings） |
| app.thinking.toggle | ctrl+t | ✓ | 已实现 |
| app.model.cycleForward/Backward | ctrl+p / shift+ctrl+p | ✓ | 本轮实现 |
| app.model.select | ctrl+l | ✓ | 本轮实现（列表展示；全屏 selector 暂缓） |
| app.tools.expand | ctrl+o | ✓ | 已实现 |
| app.editor.external | ctrl+g | ✓ | 已实现（$EDITOR） |
| app.message.copy | ctrl+x | ✓ | 本轮实现（选区优先，否则最后回复） |
| app.message.followUp / dequeue | alt+enter / alt+up | ✓ | 已实现（follow-up 队列 + 全量恢复回编辑器） |
| app.clipboard.pasteImage | ctrl+v | — | 暂缓（图片输入管线） |
| app.session.toggleNamedFilter | ctrl+n | — | 暂缓（session selector 过滤） |
| tui.altScreen.search / nextPrompt / previousPrompt | ctrl+shift+f 等 | ✓ | 已实现（搜索框 + 高亮 + 导航） |
| tui.altScreen.* 滚动（pageUp/Down、ctrl+home/end、half/line 可配） | ✓ | ✓ | 已实现 |
| prompt_previous/next（用户消息跳转） | ctrl+up/down | ✓ | 已实现 |
| editor：多行、history（ctrl+up）、kill-ring、undo、word-nav | ✓ | 部分 | undo/kill-ring 暂缓 |
| 文件拖放 / 图片粘贴 | ✓ | — | 暂缓 |

### 交互与渲染

| 功能 | pi | zpi | 状态 |
|---|---|---|---|
| 差分渲染 + DECSTBM 原生滚动 + 位移检测 | ✓ | ✓ | 已实现（自研差分 + 校验回退） |
| 滚动条（auto 显隐 + 拖拽 + 点击吸附） | ✓ | ✓ | 已实现 |
| Jump to latest hint（ctrl+end / 点击） | ✓ | ✓ | 已实现 |
| 流式 markdown 块级增量渲染 | ✓ | ✓ | 已实现（renderSegment 拼接逐字节一致） |
| thinking 块（折叠/点击展开） | ✓ | ✓ | 已实现（ctrl+t 全局 + 点击单块） |
| 工具块（折叠/展开/点击/耗时/错误着色） | ✓ | ✓ | 已实现 |
| 会话持久化 + -c/-r 继续 + 界面回放 | ✓ | ✓ | 已实现（replaySession 对齐 renderInitialMessages） |
| 压缩（手动 + 自动 + 压缩摘要块） | ✓ | ✓ | 已实现 |
| 启动欢迎头（文档首块、继续会话不可见） | ✓ | ✓ | 已实现（addWelcomeHeader 对齐 compact 文案） |
| 补全菜单（/ 命令、模型名） | ✓ | ✓ | 已实现（编辑器内联菜单） |
| 搜索（转写内查找/高亮/导航） | ✓ | ✓ | 已实现 |
| 鼠标：点击折叠、拖拽选区、松开复制、滚轮 | ✓ | ✓ | 已实现（含水平滚轮过滤 pi parity） |
| footer（token/cost/git 分支/cwd/模型） | ✓ | ✓ | 已实现 |
| steering（运行中改向）+ follow-up 排队 | ✓ | ✓ | 已实现（Enter/alt+Enter 排队 + pending 行 + ESC 恢复 + mode 设置） |
| 会话分享/导出（share/export） | ✓ | — | 暂缓 |
| 扩展/技能/MCP 体系 | ✓ | — | 暂缓（架构级） |
