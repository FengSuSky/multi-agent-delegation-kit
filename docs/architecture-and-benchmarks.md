# 多 Agent 异构协作：架构原理、实测数据与最佳实践

> 本文沉淀整套多 Agent 分层协作的底层逻辑、实测对照数据、CLI 进阶参数踩坑，以及 Google Antigravity (`agy`) / Claude Code / Cursor 的协同边界。

---

## 一、核心动机：为什么需要异构多 Agent 协作？

### 1. 强模型 × 弱 Harness 与 平价模型 × 强 Harness 的结构性互补
- **政策与 OAuth 边界**：Google（Antigravity）和 Anthropic（Claude Code）均严禁将包月订阅的 OAuth 凭证接入第三方开源 harness（如 OpenCode/OpenClaw/代理），违规会触发限流甚至封号。要在合规前提下用好各自优势，最佳路径是**在原生客户端内分工协作**，而非强行把订阅模型塞进同一个壳子。
- **错位互补**：
  - **AGY（Gemini 4 Neon / Hydrogen）**：强在 **1M 统一上下文、低幻觉、高可引导性、原生编排原语**（`invoke_subagent` / `run_workflow` / `/swarm` / `Orchestrator (Neon)`）与终端全放行；但单点工程 Harness 细节（如费用硬顶、命令前缀级白名单）弱于 Claude Code，且订阅 5 小时/周限额偏黑盒，不适合跑长程试错循环。
  - **Claude Code（接平价 API，如 GLM-5.3-Flash / GLM-5.4）**：拥有目前最成熟的终端工程 Harness（代码定位、编辑、测试闭环、`--allowedTools`、`--max-budget-usd`、`--exclude-dynamic-system-prompt-sections`），能把成本仅为旗舰 ~1/10 的模型拉到准旗舰交付水平，同时替 AGY 分担长程写码消耗。
  - **Cursor Agent（Sonnet 5.5）**：IDE 深度集成与稀缺旗舰模型兜底。

### 2. 三大底层工程共识
1. **管理学视角**（多模型分工）：承认模型偏科，通过**单一事实源（`AGENTS.md`）**对齐规范，让合适模型干合适的活。
2. **Harness & Context Engineering**：$\text{Agent} = \text{LLM} + \text{Context} + \text{Tools}$。有强验收闭环（单测/构建/lint）+ 干净简报 + KV Cache 复用时，便宜模型即可胜任 80% 实现任务。
3. **不信自报、独立验收、异构互审**：绝不让写代码的同源模型自审；主会话必须亲自核对 diff 边界并跑验收命令。

---

## 二、四层异构协作矩阵

| 层级与角色 | 日常主力（高性价比） | 稀缺王牌（按需升级） | 适用任务 | 自验能力 |
| :--- | :--- | :--- | :--- | :--- |
| **L0 主会话 / 架构师** | **AGY `gemini-4-neon-medium`** | **AGY/Cursor `claude-opus-5-5-medium`**（Neon 提炼上下文后联合决策） | 需求澄清、任务拆解、简报撰写、Diff 验收、复杂权衡 | 全放行 |
| **L1 攻坚实现** | **Claude Code `glm-5.3-flash[1m]`**（复杂可切 `glm-5.4[1m]`） | **Cursor/AGY `claude-sonnet-5-5-medium`**（2–3 轮熔断兜底） | 多文件实现、带测试闭环的 Bug 修复、长程写码 | Claude Code 精确白名单自验 |
| **L2 快速外勤 / 批处理** | **AGY `gemini-4-hydrogen-{low,medium}`**（或 AGY 内置 `invoke_subagent` `flash`） | — | 仓库检索、摘要、结构化抽取（`--json-schema`）、细微杂活、补单测、中小型确定性改动 | 全放行 |
| **L3 异构互审** | 跨模型家族互审（GLM→Neon；Hydrogen/Neon→GLM/Sonnet） | `opus-5-5` / *(其他异构模型按额度启用)* | 关键 PR 安全与边界审计、设计方案挑刺 | 只读审查 |

### 降级链与多轮复用
- **配额耗尽自动降级**：`run_delegate.sh` 沿回退链逐个通道重试（默认 `--fallback fast`，可写成 `fast,scout` 这样的多级链），启动前先预检网络路径；全部失败时输出一份结构化报告，列出每个通道的失败原因和下一步，而不是把原因留在 stderr。极端情况下外部渠道全无额度，本会话熔断故障渠道、全员走 **AGY Hydrogen**（或内置 `invoke_subagent`）兜底；守卫为 `deny` 时原生子代理会被拦截，失败报告改为让主会话接手。
- **多轮上下文复用**：同模块/同主题后续返工优先复用已有会话——AGY 原生 subagent 用 `send_message(Recipient=conversationId)`；外部 CLI 用 `--keep-session` + `--resume <session_id>` 复用前缀缓存。

### 机制保障：守卫 Hook 与预检
规程写得再清楚，主模型仍会顺手把实现做了。一次真实项目的复盘中，约 41% 的主模型生成花在「亲自实现」和「用 `inherit` 派实现子代理」上（数据见 Skill 的 `references/delegation-best-practices.md` 第 5 节）。所以路由不能只靠文字约定：
- **守卫 Hook**（`guard_subagent.py`，AGY PreToolUse）：`invoke_subagent(Model="inherit")` 默认被自动改写为 `flash`，可切换为拦截（把写码任务逼到 coder 通道）或不干预。拦截时 `self` 子代理不论 `Model` 都会被拦下——只看 `Model` 的话，主会话把编码任务写成 `Model="flash"` 就绕过去了。
- **预检**：委派脚本先确认端点可达、本机代理在监听；坏掉的网络路径几秒内失败，而不是让 CLI 空转几分钟。
- **进度心跳**：输出文件只在结束时写入，运行期间脚本每隔一段时间向 stderr 报一行已用时、工具调用次数和最近一次调用，编排方据此区分「还在干活」和「挂死」。
- **失败报告**：输出文件始终是合法 JSON，列出每个尝试过的通道、失败原因和下一步。

---

## 三、横向对照实测数据（`inventory.py` 5 Bug + 6 Pytest 基准）

测试基准：~60 行库存模块（5 个 bug：折扣百分数当小数、下单非原子、`<=` 应 `<`、`merge` 覆盖而非累加、`remove` 对未知 SKU 污染 `defaultdict`）+ 6 个 pytest 用例。统一五段式简报、独立目录并行运行、全程不开启 `--yolo`/`--dangerously-skip-permissions`。

| 执行者 | 耗时（墙钟 / API） | 结果与自验 | 改测试 / 越界 | Token（in / out / cache） | 关键观察 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **AGY `gemini-4-hydrogen-medium`** | **27.3s** | 6 passed，**自验通过** | 否 / 否 | 20.0k / 1.68k (thinking 495) / 41.0k | **全场最快**，汇报严守 3 行，主动处理同订单重复 SKU 累加 |
| **Claude Code `glm-5.3-flash[1m]`** | **38.5s** (API 18.9s) | 6 passed，**自验通过** | 否 / 否 | 46.3k / 1.30k / 48.0k | 6 turns，`permission_denials: []`，主动处理重复 SKU |
| **Cursor `claude-sonnet-5-5-medium`** | 61s (API 36s) | 6 passed（主会话复验） | 否 / 否 | 12 / 1.8k / 115k+20k | 质量稳，但默认 allowlist 拦 shell 无法自验；10–60k 固定开销 |
| **AGY `gemini-3.8-flash-medium`** | 205s (API 190s) | 6 passed，自验通过 | 否 / 否 | 24.7k / 6.5k (thinking 5.6k) / 70k | 已被 `gemini-4-hydrogen-medium` 全面替代 |
| **Cursor `grok-4.7-medium-fast`** | 418s | 6 passed（主会话复验） | 否 / 否 | 121k / 10.4k (reasoning 8.4k) / 1.0M | 慢且费 token，仅适合低频异构第二意见（额度充足时再启用） |

---

## 四、各 CLI 关键踩坑与进阶参数

### 1. Claude Code (`claude`)
- **关键踩坑**：`--allowedTools` 是变长参数（`<tools...>`），直接把 prompt 跟在后面会被吃进工具列表并报错 `Input must be provided...`。**必须通过 stdin 重定向（`< brief.txt`）或 `--` 分隔**。
- **推荐安全自验组合**（已封装进 `run_delegate.sh`）：
  - `--permission-mode acceptEdits` + `--allowedTools "Read,Edit,Write,Bash(<test-cmd>:*)"` + `--permission-prompts none`（未放行命令直接拒绝不挂起）
  - `--max-budget-usd 1.00`（单次硬费用熔断）
  - `--effort <low|medium|high|xhigh|max>`（按难度控思考深度）
  - `--exclude-dynamic-system-prompt-sections`（提升跨目录 Prompt Cache 命中率）
  - `--no-session-persistence`（一次性杂活不污染历史；多轮复用时改传 `--keep-session` + `--resume <id>`）

### 2. AGY (`agy`)
- `-p` 必须放在命令最后；工作目录必须在 `$HOME` 下（`/tmp` 写文件会被拒）；务必带 `--print-timeout` 防网络抖动挂起。
- 善用官方原语：**日常轻量任务/兜底优先内置 `invoke_subagent`（`flash` + `share` 工作区；守卫为 `deny` 时 `self` 子代理会被拦截）**，批量扇出流水线用 `run_workflow`，单点硬 bug 用 `/boost`，多文件并发用 `/swarm`，纯 AGY 复杂任务可试 `gemini-pro-orchestrator-neon`。
- **合规红线**：`agy -p` 仅限单用户在人工发起的当前工作流中按需调用，严禁 24/7 无人值守挂机循环。

### 3. Cursor Agent CLI (`agent`)
- 默认 allowlist 限制 shell，不加 `--force` 时无法自验，简报中应写明“不要尝试运行命令，改完即交卷”，验收由主会话跑（进阶可测官方 `--auto-review` + `--sandbox enabled`）。
- 单次有 10–60k 固定系统上下文开销，不适合琐碎问答；支持 `--mode plan` / `--mode ask`、`-w/--worktree`、`--resume <session_id>`。
