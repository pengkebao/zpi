# zpi — pi 的 Zig 实现

纯 Zig（仅 std，零第三方依赖）实现的终端编程智能体，行为对齐 [pi](https://pi.dev) 1.5.0。

## 特性

**智能体内核**

- OpenAI 兼容 SSE 流式协议（text / thinking / tool_calls 增量）
- 工具：shell、read、edit（diff 预览）、glob 匹配、选区截断
- 会话持久化、上下文压缩（compaction）、成本/缓存命中率统计

**TUI**

- 差分帧渲染：DECSTBM 原生滚动 + 垂直位移检测（逐行校验，失败自动回退全量重绘）
- 屏幕层合成：滚动条、`Jump to latest message` 提示、搜索浮层
- 流式 Markdown **块级增量渲染**（段间拼接与全量渲染逐字节一致，帧成本与流长度解耦）
- 工具/思考块折叠展开（ctrl+O / ctrl+T）、补全菜单、`/` 命令
- 滚动体验：follow-end 钉底、滚轮加速度计、滚动条拖拽映射、到底惰性（no-op 拉拽零字节）

**快捷键**：Enter 提交 · ctrl+O 展开工具输出 · ctrl+T 隐藏 thinking · ctrl+end 回到最新 · ctrl+C 清空/退出 · `/help` 查看全部

## 构建

```bash
zig build          # Zig 0.17.0
./zig-out/bin/rpi  # 运行
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
├── ai/openai.zig       OpenAI 兼容 SSE 客户端
├── tools/              shell / read / edit / match / selection / truncate
└── ui/                 TUI：差分渲染、markdown、滚动视图、编辑器、搜索、补全
```

设计决策与演进记录见 [PLAN.md](PLAN.md)。
