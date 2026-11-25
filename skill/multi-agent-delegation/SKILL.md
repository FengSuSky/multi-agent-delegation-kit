---
name: multi-agent-delegation
description: >-
  Orchestrate cost-effective, high-quality multi-agent software development by routing
  subtasks by universal roles (scout, fast, coder, heavy, architect) across heterogeneous
  harnesses (AGY, Claude Code with GLM/DeepSeek/Kimi/MiniMax endpoints, Cursor) with
  user/project layered config, automatic fallback, and session reuse. Use when delegating
  implementation, parallel subtasks, codebase research, test monitoring, or cross-model review.
---

# 多 Agent 异构委派工作流（角色路由 × 多 Harness）

面向**高质量、低成本**软件开发的通用多 Agent 协作规程。主会话保持高信息密度，负责需求澄清、拆解、上下文提炼与独立验收；执行任务按 **5 个通用角色（`--role`）**下沉给不同成本与特长的模型 × Harness 组合，遇到难点再熔断升级，渠道不可用时自动降级。

详细实测基准与 CLI 参数速查见 [delegation-best-practices.md](./references/delegation-best-practices.md)。

---

## 0. 配置分层与本地核心 MD 联动（每次触发先读）

本 Skill 将「协作流程」与「用户订阅/模型配置」彻底解耦，升级 Skill 时不会覆盖任何个人配置。生效优先级从高到低：

```text
命令行参数 > 项目级配置 (.agents/delegation/) > 用户级配置 (~/.config/multi-agent-delegation/) > Skill 默认值
```

- **查看当前生效角色映射与本机核心 MD**：
  ```bash
  bash ~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --show --dir <workdir>
  ```
- **Agent 自动读取顺序**：首次在某项目中委派前，先检查并遵循存在的配置文件与核心 MD（按优先级合并）：
  1. 项目级覆盖：`<project_root>/.agents/delegation/overrides.md`（与 `config.env`）
  2. 项目级核心 MD：`<project_root>/AGENTS.md`、`<project_root>/CLAUDE.md`
  3. 用户级覆盖：`~/.config/multi-agent-delegation/overrides.md`（与 `config.env`）
  4. 用户级核心 MD：`~/.gemini/AGENTS.md`、`~/.claude/CLAUDE.md`
- **切换订阅组合 Profile**：
  ```bash
  # 查看内置组合方案（agy-cursor-zhipu / claude-deepseek-glm / agy-only）
  bash ~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --list-profiles
  # 应用方案到用户级配置（加 --force 覆盖已有）
  bash ~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --use-profile claude-deepseek-glm --force
  ```
- **脚本自动生效**：`run_delegate.sh` 安全解析 `config.env`（不执行任意 shell 代码），自动应用角色绑定（`harness:model`）、Claude 多国产端点（`*_BASE_URL` / `*_API_KEY_ENV`）、禁用 Harness/角色自动分流与默认参数。

---

## 1. 通用角色路由决策表（`--role`）

| 任务类型 | 通用角色 (`--role`) | 能力画像与典型组合示例 |
| :--- | :--- | :--- |
| 检索、摘要、全量测试/评测监控、大日志分析、结构化抽取 | `scout`（或原生 `flash` subagent） | 极快、极便宜、隔离大输出只回 5–10 行摘要（如 AGY Hydrogen-low / DeepSeek-Chat） |
| 细微杂活、补单测、中小型确定性改动 | `fast` | 低成本 + 终端可自验（如 AGY Hydrogen / DeepSeek-Chat） |
| 常规/多文件代码实现、带测试闭环的 Bug 修复 | `coder` | 强 Harness（Claude Code）× 高性价比模型（智谱 GLM / Kimi / DeepSeek / MiniMax 等） |
| `coder` 连续 2–3 轮自修仍不绿（熔断升级） | `heavy` | 稀缺旗舰编程模型攻坚（Sonnet / GLM-5.4 / Cursor 等） |
| 高风险架构、棘手权衡（只读联合决策） | `architect` | 最强推理旗舰 + 只读 Plan 模式（Opus / Neon 等），由主会话先提炼高密度上下文 |
| 异构交叉 Review | 跨模型家族互审 | 绝不让写代码的同源模型自审（例如 GLM/DeepSeek 写的 → 主会话或 Sonnet 审） |

> 注：
> - 细小单点改动由主会话直接完成，避免委派固定开销。
> - 旧版 `--preset`（`hydrogen-low` / `hydrogen` / `glm` / `glm-opus` / `sonnet-agy` / `sonnet-cursor` / `opus-plan`）仍完整保留向下兼容。
> - **优先主会话原生原语**：在 AGY 主会话内做轻量 `scout`/`fast` 任务或监控全量测试时，优先用内置 `invoke_subagent`（`Model: "flash"`，写任务用 `Workspace: "share"`，同主题用 `send_message` 复用），比 shell 另起进程更轻量；批量扇出优先用 `run_workflow`。
> - **保护订阅限额**：多轮试错、长程写码优先分流给高性价比 `coder`（如 Claude Code + 国产 Coding Plan），避免在限流较严的主订阅上跑长循环。

---

## 2. 配额耗尽与自动降级链（Fallback）

当某个渠道出现**额度耗尽、限流（429/402）、余额不足、认证失败、服务不可用，或被 `DELEGATE_DISABLED_HARNESSES` / `DELEGATE_DISABLED_PRESETS` 禁用**时，平滑降级不中断任务：

1. **角色降级链**：
   - `heavy`（失败或无额度）→ `coder` → **`fast`**（默认兜底角色，可在 `config.env` 通过 `DELEGATE_DEFAULT_FALLBACK` 自定义）
   - `coder`（无额度或 API 故障）→ **`fast`**
   - **极端全断兜底**：外部渠道均不可用时，统一走本机可用兜底角色（或主会话原生轻量 subagent）。
2. **脚本自动降级**：`run_delegate.sh` 默认开启 `--fallback fast`（可覆盖或 `--fallback none` 关闭），遇到非零退出、`is_error: true` 或配额/限流错误时，自动把失败结果备份到 `*.failed-<target>.json` 并切到兜底角色重跑。
3. **会话级通道熔断**：本会话内一旦观察到某渠道触发配额耗尽，剩余任务直接绕过该渠道；长期停用请写入 `~/.config/multi-agent-delegation/config.env` 的 `DELEGATE_DISABLED_HARNESSES` 或 `DELEGATE_DISABLED_PRESETS`。

---

## 3. 多轮交互与 Subagent / Session 复用

同主题、同模块的后续任务（如审阅返工、追问细节、补齐关联改动）**优先复用已有上下文与 KV Cache**，不要反复新建空会话：

1. **主会话原生 Subagent（首选）**：
   - `invoke_subagent` 返回 `conversationId`；同一主题的后续指令直接用 `send_message(Recipient=conversationId, Message=...)` 续接。
2. **跨 CLI 会话复用（`run_delegate.sh`）**：
   - 首轮预计会有多轮返工时，加 `--keep-session`（对 Claude Code 保留磁盘会话）；从输出 JSON 中提取 `conversation_id`（AGY）或 `session_id`（Claude Code / Cursor）。
   - 后续轮次传 `--resume <id>` 续接：
     ```bash
     bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh \
       --role coder \
       --dir .trees/fix-auth \
       --resume <conversation_id_or_session_id> \
       --brief ~/work/agy-scratch/followup-brief.md \
       --out ~/work/agy-scratch/followup.json
     ```
3. **何时新建会话**：切换到完全无关的新模块、跨 Harness 降级切换后端、或旧会话上下文已严重膨胀/跑偏时，才新建会话。

---

## 4. 标准执行流程

### 步骤 1：准备隔离工作区
- **Git 仓库（首选）**：为每个并发子任务创建独立 worktree：
  ```bash
  git worktree add .trees/<task> -b task/<task>
  ```
- **非 Git 目录**：拷贝到 `~/work/agy-scratch/<task>/`（或 `DELEGATE_SCRATCH_DIR` 指定目录；注意：AGY 禁止在 `/tmp` 下写文件，cwd 必须在 `$HOME` 下）。

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

> 若目标角色绑定的是 `cursor`（受 allowlist 限制无法跑 shell），在“验收”段明确写：**“不要尝试运行命令，改完代码即交卷，验收由主会话执行。”**
> 所有简报遵循**交付物优先（Deliverable-First）**：只要求确定性产物，不派发开放式闲聊任务。

### 步骤 3：调用委派脚本执行
使用封装脚本 [run_delegate.sh](./scripts/run_delegate.sh) 按角色派发（可同时后台并行跑多个独立目录）：

```bash
bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh \
  --role coder \
  --dir .trees/fix-auth \
  --brief ~/work/agy-scratch/fix-auth-brief.md \
  --out ~/work/agy-scratch/fix-auth.json \
  --test-cmd python3
```

> 可加 `--resolve-only` 预览该角色在当前项目下解析出的 `harness / model / endpoint / fallback`，确认无误再执行。

### 步骤 4：主会话独立验收（不信自报，自己验）
1. **检查改动边界**：`git diff --stat` 或 `diff -ru` 确认只改了允许文件、测试文件零改动、无残留文件。
2. **独立跑验收命令**：在子任务目录亲自运行测试/构建确认全绿。
3. **审查 Diff 逻辑**：逐行读 diff，严防硬编码凑通过、删断言或弱化校验。
4. **检查异常信号**：核对输出 JSON 的 `is_error`、`permission_denials` 或回复中是否有“被拒绝/未能运行”。
5. **熔断与升级**：若 `coder` 2–3 轮仍未通过，收集失败日志与当前 diff，由主会话诊断后补充背景重试，或升级到 `--role heavy`。

### 步骤 5：合入与清理
验收全绿后将改动合入主工作区（`git merge` / `cherry-pick`），移除 worktree（`git worktree remove .trees/<task>`）或清理 scratch 目录。

---

## 5. 安全红线

- **严禁**使用 `--yolo`、`-f`、`--dangerously-skip-permissions`，除非用户当次明确授权。
- **严禁**在 `config.env` 中写入明文 API Key（仅通过 `*_API_KEY_ENV` 引用环境变量名）。
- **严禁**子代理修改测试文件以掩盖代码问题（除非任务本身是编写/更新测试）。
- **严禁**多个写任务共享同一个工作目录。
- **合规边界**：CLI 委派仅限单用户在人工发起的当前工作流中按需调用，**严禁** 24/7 无人值守挂机循环或接入违规第三方代理。
