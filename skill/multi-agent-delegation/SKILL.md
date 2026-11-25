---
name: multi-agent-delegation
description: >-
  Orchestrate cost-effective, high-quality multi-agent software development by routing
  subtasks from the primary Neon session to cheaper self-verifying CLI workers
  (AGY Gemini 4 Hydrogen, Claude Code GLM-5.3-Flash) and escalating hard decisions
  or blocked tasks to Claude Opus 5.5 / Sonnet 5.5. Use when delegating implementation,
  parallel subtasks, codebase research, or cross-model review.
---

# 多 Agent 异构委派工作流

面向“高质量、低成本”开发的多 Agent 协作规程。主会话（AGY `gemini-4-neon-medium`）保持高信息密度，负责需求澄清、拆解、上下文提炼与最终验收；执行任务下沉给能自验的便宜 Worker，遇到难点再熔断升级给稀缺旗舰额度。

详细实测基准与 CLI 参数速查见 [delegation-best-practices.md](./references/delegation-best-practices.md)。

---

## 1. 路由决策表

| 任务类型 | 路由目标 (`--preset`) | 说明 |
| :--- | :--- | :--- |
| 检索、摘要、日志分析、结构化抽取 | `hydrogen-low` | 极快便宜，可配 `--json-schema` |
| 细微杂活、补单测、中小型确定性改动 | `hydrogen` | `gemini-4-hydrogen-medium`，实测 27s，终端全放行自验 |
| 常规/多文件代码实现、带测试闭环的 Bug 修复 | `glm` | Claude Code `glm-5.3-flash[1m]`，实测 38s，精确白名单自验 |
| 较复杂多模块实现（仍想控成本） | `glm-opus` | Claude Code `glm-5.4[1m]` |
| 便宜模型 2–3 轮自修仍不绿（熔断升级） | `sonnet-agy` 或 `sonnet-cursor` | 动用少量 `claude-sonnet-5-5-medium` 额度攻坚 |
| 高风险架构、棘手权衡（联合决策） | `opus-plan` | Neon 先提炼高密度上下文，再请 `claude-opus-5-5-medium --mode plan` 只读拍板 |
| 异构交叉 Review | 跨模型家族互审 | GLM 写的 → Neon 审；Hydrogen/Neon 写的 → GLM 或 Sonnet 审 |

> 注：细小单点改动由主会话直接完成，避免委派固定开销。
>
> **路由补充原则**：
> - **优先 AGY 原生原语**：在 AGY 主会话内做轻量检索/杂活或全渠道兜底时，优先直接用内置 `invoke_subagent`（`Model: "flash"` + `Workspace: "share"` + `send_message` 复用），比 shell 另起 `agy -p` 更轻量且零进程开销；批量扇出流水线优先用 `run_workflow`。
> - **保护 AGY 订阅限额**：多轮试错、长程写码优先分流给 Claude Code (`glm`)，避免在 AGY 侧跑长循环触发 5 小时/周黑盒限流。

---

## 2. 配额耗尽与自动降级链（Fallback）

当外部渠道出现**额度耗尽、限流（429/402）、余额不足、认证失败或服务不可用**时，按以下顺序平滑降级，确保任务不中断：

1. **完整降级链**：
   - `sonnet-cursor` / `sonnet-agy`（攻坚失败或无额度）→ `glm` / `glm-opus` → **`hydrogen`（AGY `gemini-4-hydrogen-medium`）**
   - `glm` / `glm-opus`（无额度或 API 故障）→ **`hydrogen`（AGY `gemini-4-hydrogen-medium`）**
   - **极端全断兜底**：若 Cursor 与 Claude Code 均无额度，所有子任务默认统一走 **AGY `hydrogen`**（或直接用 AGY 原生 `invoke_subagent` 的 `Model: "flash"`）。
2. **脚本自动降级**：`run_delegate.sh` 默认开启 `--fallback hydrogen`，遇到非零退出、`is_error: true` 或配额/限流错误时，自动把失败结果备份到 `*.failed-<preset>.json` 并切到 `hydrogen` 重跑（如需关闭传 `--fallback none`）。
3. **会话级通道熔断**：一旦本会话内观察到某渠道（如 `glm` 或 `sonnet-cursor`）触发配额耗尽，主会话应在本会话剩余任务中**直接熔断该渠道**、改派 `hydrogen`，不再重复踩坑。

---

## 3. 多轮交互与 Subagent / Session 复用

同主题、同模块的后续任务（如审阅返工、追问细节、补齐关联改动）**优先复用已有上下文与 KV Cache**，不要反复新建空会话：

1. **AGY 原生 Subagent（首选）**：
   - `invoke_subagent` 返回 `conversationId`；同一主题的后续指令直接用 `send_message(Recipient=conversationId, Message=...)` 续接，避免重复探索代码库。
2. **跨 CLI 会话复用（`run_delegate.sh`）**：
   - 首轮预计会有多轮返工时，加 `--keep-session`（对 Claude Code 保留磁盘会话）；从输出 JSON 中提取 `conversation_id`（AGY）或 `session_id`（Claude Code / Cursor）。
   - 后续轮次传 `--resume <id>` 续接：
     ```bash
     bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh \
       --preset hydrogen \
       --dir .trees/fix-auth \
       --resume <conversation_id_or_session_id> \
       --brief ~/work/agy-scratch/followup-brief.md \
       --out ~/work/agy-scratch/followup.json
     ```
3. **何时新建会话**：切换到完全无关的新模块、跨 CLI 降级切换后端、或旧会话上下文已严重膨胀/跑偏时，才新建会话。

---

## 4. 标准执行流程

### 步骤 1：准备隔离工作区
- **Git 仓库（首选）**：为每个并发子任务创建独立 worktree：
  ```bash
  git worktree add .trees/<task> -b task/<task>
  ```
- **非 Git 目录**：拷贝到 `~/work/agy-scratch/<task>/`（注意：AGY 禁止在 `/tmp` 下写文件，cwd 必须在 `$HOME` 下）。

### 步骤 2：撰写五段式任务简报
将简报写入临时文件（例如 `~/work/agy-scratch/<task>-brief.md`）：

```markdown
## 目标
<一句话描述要修什么 / 做什么，达成什么状态>

## 验收
在当前目录运行: <命令>  (期望: <全绿 / 输出X>)

## 范围
只允许修改: <文件列表>。禁止: 修改测试 / 其他文件 / 新建文件 / 改公开签名 / 装依赖。

## 背景（可选，仅放已知事实）
<已定位的根因、文件:行号、主会话已拍板的决定>

## 完成后
3-5 行以内汇报: 改动点 + 根因 + 验收命令末行输出。最多自修 2-3 轮，若测试仍失败则立即停止并汇报卡点。
```

> 若走 `sonnet-cursor`，在“验收”段明确写：**“不要尝试运行命令，改完代码即交卷，验收由主会话执行。”**
> 所有简报遵循**交付物优先（Deliverable-First）**：只要求确定性产物（改完文件 + 测试输出 / 结构化 JSON），不派发开放式闲聊任务。

### 步骤 3：调用委派脚本执行
使用封装脚本 [run_delegate.sh](./scripts/run_delegate.sh) 派发（可同时后台并行跑多个独立目录）：

```bash
bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh \
  --preset glm \
  --dir .trees/fix-auth \
  --brief ~/work/agy-scratch/fix-auth-brief.md \
  --out ~/work/agy-scratch/fix-auth.json \
  --test-cmd python3 \
  --effort high \
  --max-budget 1.00
```

> 脚本对 Claude Code 预设已内置 `--no-session-persistence`（传 `--keep-session` 时保留）、`--exclude-dynamic-system-prompt-sections`（提升缓存命中）与 `--permission-prompts none`（未放行命令自动拒而不挂起）。

### 步骤 4：主会话独立验收（不信自报，自己验）
1. **检查改动边界**：`git diff --stat` 或 `diff -ru` 确认只改了允许文件、测试文件零改动、无残留文件。
2. **独立跑验收命令**：在子任务目录亲自运行测试/构建确认全绿。
3. **审查 Diff 逻辑**：逐行读 diff，严防硬编码凑通过、删断言或弱化校验。
4. **检查异常信号**：核对输出 JSON 的 `is_error`、`permission_denials` 或回复中是否有“被拒绝/未能运行”。
5. **熔断与升级**：若 Worker 2–3 轮仍未通过，收集失败日志与当前 diff，由主会话诊断后决定补充背景重试，或升级到 `sonnet-agy` / `sonnet-cursor`。

### 步骤 5：合入与清理
验收全绿后将改动合入主工作区（`git merge` / `cherry-pick`），移除 worktree（`git worktree remove .trees/<task>`）或清理 scratch 目录。

---

## 5. 安全红线

- **严禁**使用 `--yolo`、`-f`、`--dangerously-skip-permissions`，除非用户当次明确授权。
- **严禁**子代理修改测试文件以掩盖代码问题（除非任务本身是编写/更新测试）。
- **严禁**多个写任务共享同一个工作目录。
- **合规边界**：`agy -p` 仅限单用户在人工发起的当前工作流中按需调用，**严禁** 24/7 无人值守挂机循环或接入第三方 OAuth 代理。
