---
name: multi-agent-delegation
description: >-
  Orchestrate cost-effective, high-quality multi-agent software development by routing
  subtasks by universal roles (scout, fast, coder, heavy, architect) across heterogeneous
  harnesses (AGY, Claude Code with GLM/DeepSeek/Kimi/MiniMax endpoints, Cursor) with
  user/project layered config, an AGY guard hook that keeps the primary model orchestrating,
  preflight checks, multi-hop fallback with structured failure reports, progress heartbeats, and session reuse.
  Use when delegating implementation, parallel subtasks, codebase research, full test/eval runs,
  routine git wrap-up, or cross-model review.
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
- **配置写法**：`config.env` 支持行内注释，但 `#` 前必须留空白（`KEY=value  # 说明`）；`none` / `0` 表示不设对应限制（如 `DELEGATE_DEFAULT_MAX_BUDGET=none`）。
- **AGY 守卫 Hook（用机制落实路由，而不只靠文字约定）**：`bash install.sh --with-hooks` 把 `guard_subagent.py` 装进 `~/.gemini/config/hooks.json`，对 `invoke_subagent` 与 `run_command` 生效：
  - `Model="inherit"`（让子代理跑在主模型上）默认被**自动改写**为 `flash`（`DELEGATE_INHERIT_SUBAGENT=rewrite`）；`allow` 关闭。Prompt 里带 `[allow-inherit]` 可放行。
  - `deny` 用来把写码任务逼到 coder 通道：`self` 子代理**不论 `Model`**（`flash` / `flash_lite` 也算）连同所有 `inherit` / `pro` 调用一律拦截，只有只读的 `research` 子代理还能跑在 `flash` / `flash_lite` 上。只按 `Model` 拦不住——实测把 `inherit` 改写成 `flash` 之后，主会话会把多文件编码任务直接写成 `Model="flash"` 派出去。
  - `DELEGATE_AUTO_ALLOW_DELEGATE=1` 时，规范形式的 `run_delegate.sh` 命令不再弹权限、不再被沙箱拦截（默认关闭，授权范围见第 5 节）。

---

## 0.5 主会话零噪音与防膨胀原则（Clean Main Session）

随着项目推进，频繁的 tool calls（跑测试、读大文件、多目录检索、反复试错）会迅速塞满主会话上下文并稀释注意力。本工作流强制将**编排决策**与**工具执行**隔离：

- **主会话只留 4 类高价值信息**：与用户交互与需求澄清、当前计划与决策、subagent 进展追踪、最终验收结果对齐。
- **以下操作默认隔离在 subagent / `coder` 上下文中（禁止在主会话直接刷屏）**：
  - **`npm test` / `pytest` / 构建 / 评测跑批等全量测试与校验**：统一走 `coder` 通道执行，**主会话禁止裸跑全量 `npm test` / `pytest` 等大输出测试**（避免与全局「日志落盘截断」及「禁止 Shell 重定向/复合命令」规则冲突）；
  - 跨文件/大范围代码库检索、大文件通读、大日志根因定位与批量分支盘点（交由只读 `scout`）；
  - 多轮编码试错、报错堆栈排查与常规 Git 整理收尾（交由 `coder`）。
- **只对齐结果，细节留在子代理或落盘**：中间日志与过程保留在子代理上下文（需要追问细节时用 `send_message` 或 `--resume` 续问原执行者）或写入报告文件；主会话仅接收 **5–10 行结构化回执**（状态、通过/失败数、关键指标、改动点、失败定位与报告路径）。
- **主会话不代读参考源码**：写 `coder` 简报只写「目标 + 验收 + 允许范围 + 失败日志路径 + 已知根因」；需要了解代码位置时，只派一次只读 `scout` 返回 **≤30 行「文件:行号」地图**，不把源码片段抄进简报，主会话只读验收 diff 真正需要的最小范围。实测一个 AGY 主会话 75% 的上下文来自它自己的 `read_file`，而子代理回执合计不到一成——上下文是被「自己读文件」撑爆的，不是被回执。
- **大快照 / 单行超大文件不裸 diff**：凡 `*.snap`、`*snapshots*.json`、`package-lock.json` 等单行超长或体积巨大的文件，**禁止主会话直接 `git diff`**，交由 `scout` 或 `coder` 按键级比对返回 ≤10 行摘要。
- **免每场会话重复通读完整 `SKILL.md`**：注入全局核心 MD 的规则片段已覆盖常规 `--role coder` 派发、等待与验收流程；仅在涉及 `--resume`、`load_config.sh` 或故障排查时按章节局部读取 `SKILL.md`。
- **一个阶段一个会话**：一轮实现合并后新开会话，用主会话写的交接文档衔接；上下文超过约 15 万 token 就 `/compact` 或新开。

---

## 1. 通用角色路由决策表（`--role`）

| 任务类型 | 通用角色 (`--role`) | 能力画像与典型组合示例 |
| :--- | :--- | :--- |
| **纯只读分析**：代码地图、大日志/测试报告根因定位、大快照 diff 摘要、文档盘点 | `scout`（或原生 `research` subagent） | 极快、极便宜、隔离大输出只回 5–10 行摘要（AGY 内用 `invoke_subagent(TypeName="research", Model="flash_lite")`，需要推理时用 `flash`；脚本通道为 AGY Hydrogen-low / DeepSeek-Chat）。**明文禁止**派原生 `research` 跑需要本地端口或家目录配置的测试套件（只读无网沙盒会报 `fetch failed` / `EPERM` 或悬挂句柄） |
| 细微杂活、补单个单测、中小型确定性改动 | `fast`（或原生 `flash` subagent） | 低成本 + 终端可自验。**`fast` 级的判定标准：一两个文件、不需要先读代码定位、一轮就能改完自验**，超出任一条就是 `coder`。AGY 内用 `invoke_subagent(TypeName="self", Model="flash", Workspace="share")`（守卫为 `deny` 时会被拦截，改走 `coder`）；脚本通道为 AGY Hydrogen / DeepSeek-Chat |
| **统一 Act 执行通道**：多文件实现 + 自测闭环、**全量测试/评测跑批与失败排查**、**常规 Git 整理与收尾**（`git status` / `git diff --stat`、白名单精准 `git add`、分批 `git commit`、仅授权时 `git push`） | `coder` | 强 Harness（Claude Code）× 高性价比模型（智谱 GLM / Kimi / DeepSeek / MiniMax 等） |
| `coder` 连续 2–3 轮自修仍不绿（熔断升级） | `heavy` | 稀缺旗舰编程模型攻坚（Sonnet / GLM-5.4 / Cursor 等） |
| 高风险架构、棘手权衡（只读联合决策） | `architect` | 最强推理旗舰 + 只读 Plan 模式（Opus / Neon 等），由主会话先提炼高密度上下文 |
| 异构交叉 Review | 跨模型家族互审 | 绝不让写代码的同源模型自审（例如 GLM/DeepSeek 写的 → 主会话或 Sonnet 审） |

> 注：
> - 细小单点改动由主会话直接完成，避免委派固定开销。
> - 旧版 `--preset`（`hydrogen-low` / `hydrogen` / `glm` / `glm-opus` / `sonnet-agy` / `sonnet-cursor` / `opus-plan`）仍完整保留向下兼容。
> - **AGY 原生子代理的 `Model` 只有四个别名**：`inherit`（主会话当前模型，如 Neon）、`flash_lite`（gemini-3.5-flash-lite，最便宜）、`flash`（Hydrogen 高思考档）、`pro`（Hydrogen 更高思考档）。`inherit` 由守卫 Hook 按策略改写或拦截；纯只读分析用 `TypeName="research"` 加 `flash_lite`。**原生 `flash` 子代理只接 `fast` 级的小活**：把简报塞给 `Model="flash"` 的 `self` 子代理只是换了档位，活仍然在 AGY 里、也没有 coder 的测试闭环，需要写简报或执行 Act 闭环的任务一律走 `coder`。
> - **AGY Plan/Execute（Orchestrator）模式与 `coder` 交接**：规划阶段遇到多文件实现、新增多个测试、带测试闭环的 Bug 修复或全量测试/评测验收，通过 `exit_plan_mode` 交付「把简报与输出 JSON 默认写到 `<artifactDirectoryPath>/scratch/`（免工作区外写权限弹窗、不污染 `git status`，守卫自动放行）或 `DELEGATE_SCRATCH_DIR` → 后台调 `run_delegate.sh --role coder`（`NotificationTimeoutSeconds` 设 900 以上）→ 独立验收」的编排步骤，而不是让执行模型在主会话逐文件 `edit_file` 与裸跑全量测试。单任务直接 `--dir .` 改当前工作区、靠 `git diff --stat` 验收，仅并发多写任务才开 `git worktree`；首次在无 `.agents/delegation/config.env` 的非 Python 项目委派前，先检查并补齐项目级 `DELEGATE_DEFAULT_TEST_CMD`（如 `npm test,npm run,node --test,git status,git diff,git log,git add,git commit`，按需追加 `,git push`）、`pytest,python3`、`go test`、`cargo test` 等，避免 `coder` 遇 `permission_denials` 或因传 `--test-cmd` 触发审批弹窗。仅纯文档同步或 1–2 个文件数行级小改才由执行模型直接完成。
> - **Neon 与 Hydrogen 吃的是同一份 AGY 配额**（实测两者同刻打空、同刻重置，Claude 系列另算）。把活交给 `flash`，省的是 Neon 的份额和主会话上下文，不是 AGY 总量；要把用量真正挪出 AGY，走 `coder` 通道（Claude Code + GLM 等）或 Cursor。
> - **调研类子代理是最大的 token 出口**：简报里写明回执行数上限，要求先用 `rg` / `grep` 定位、再按行范围读取，不要逐个整文件通读；大型盘点拆分为 2–3 分钟内可完成的窄范围子代理（纯清单/搜索用 `flash_lite`，需推理用 `flash`），避免单个近 10 分钟的笼统调研。
> - **保护订阅限额**：多轮试错、长程写码、全量评测跑批与常规 Git 整理优先分流给高性价比 `coder`（如 Claude Code + 国产 Coding Plan），避免在限流较严的主订阅上跑长循环或消耗大量轮次。

---

## 2. 配额耗尽与自动降级链（Fallback）

当某个渠道出现**额度耗尽、限流（429/402）、余额不足、认证失败、模型/服务不可用、网络连接失败，或被 `DELEGATE_DISABLED_HARNESSES` / `DELEGATE_DISABLED_PRESETS` 禁用**时，平滑降级不中断任务；若遇到**权限拒绝（`auto-denied` / `permission_denials`）、CLI 参数错误、预算/轮次上限等非模型调用类错误**，脚本会立即停止并输出失败报告，不会静默切到兜底角色：

1. **角色降级链**（按顺序逐个尝试，直到某个通道成功）：
   - `heavy`（失败或无额度）→ `coder` → **`fast`**（默认兜底角色，可在 `config.env` 通过 `DELEGATE_DEFAULT_FALLBACK` 自定义）
   - `coder`（无额度或 API 故障）→ **`fast`**
   - **多级链**：`--fallback fast,scout` 或 `DELEGATE_DEFAULT_FALLBACK=fast,scout`；同一 `harness:model` 在一条链里只试一次。
   - **极端全断兜底**：外部渠道均不可用时，统一走本机可用兜底角色（或主会话原生轻量 subagent）。
2. **脚本先预检再启动（Preflight）**，不让 CLI 在坏掉的网络路径上空转几分钟：
   - 从 AGY 会话里调用时，Claude Code 会继承 AGY 的代理设置；代理指向的本机端口不通时，脚本会自动改成直连再试（`DELEGATE_PREFLIGHT_TIMEOUT`，`0` 关闭预检）。
   - 嵌套 `agy` 依赖的本机代理不通时直接给出原因；可配 `DELEGATE_PROXY_ENSURE_CMD` 让脚本先把隧道拉起来。
   - headless 的 `agy -p --mode plan` 无法审批工具，脚本会自动在简报前加上「不要调用任何工具」的约束。
3. **输出文件始终是合法 JSON**：
   - 成功：harness 自己的结果 JSON（看 `is_error`、`permission_denials`、`usage`）。
   - 全部失败：`{"status": "failed", "attempts": [{"target", "harness", "model", "exit_code", "reason"}], "next": "..."}`，每个失败通道的原始输出另存为 `*.failed-<target>.json`。agy 在 headless 下「工具被自动拒绝、没有输出」也算失败，不再以退出码 0 蒙混过去。
4. **会话级通道熔断**：本会话内一旦观察到某渠道触发配额耗尽，剩余任务直接绕过该渠道；长期停用请写入 `~/.config/multi-agent-delegation/config.env` 的 `DELEGATE_DISABLED_HARNESSES` 或 `DELEGATE_DISABLED_PRESETS`。

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
- **单任务（默认）**：直接用 `--dir .` 改当前工作区，验收时用 `git diff` 检查改动；只有并发多写任务才需要隔离。
- **Git 仓库并发任务（首选）**：为每个并发子任务创建独立 worktree：
  ```bash
  git worktree add .trees/<task> -b task/<task>
  ```
- **非 Git 目录**：拷贝到 `~/work/agy-scratch/<task>/`（或 `DELEGATE_SCRATCH_DIR` 指定目录；注意：AGY 禁止在 `/tmp` 下写文件，cwd 必须在 `$HOME` 下）。

### 步骤 2：撰写五段式任务简报
将简报写入临时文件：在 AGY 内默认写到 `<artifactDirectoryPath>/scratch/`（免工作区外写权限弹窗、不污染 `git status`，守卫自动放行），也可用 `~/work/agy-scratch/<task>-brief.md` 或 `DELEGATE_SCRATCH_DIR`：

```markdown
## 目标
<一句话描述要修什么 / 做什么，达成什么状态>

## 验收
在当前目录运行: <命令>  (期望: <全绿 / 输出X>)

## 范围
只允许修改: <文件列表>。禁止: 修改测试 / 其他文件 / 新建文件 / 改公开签名 / 装依赖。

## 背景（可选，仅放已知事实，不代读也不抄源码）
<失败日志路径、已定位的根因、≤30 行文件:行号地图、主会话已拍板的决定>

## 完成后
5-10 行以内结构化汇报: 改动点 + 根因 + 关键指标 + 验收命令末行/摘要 + 报告路径。最多自修 2-3 轮，若测试仍失败则立即停止并汇报卡点。
```

> 若目标角色绑定的是 `cursor`（受 allowlist 限制无法跑 shell），在“验收”段明确写：**“不要尝试运行命令，改完代码即交卷，验收由主会话另派 `coder` 执行。”**
> 所有简报遵循**交付物优先（Deliverable-First）**：只要求确定性产物，不派发开放式闲聊任务。
> **验收段写实与不代读源码**：写简报前不要为了写清上下文而逐个 `read_file` 参考文件；`coder` 自己能读源码，真需定位时只派一次 `scout` 返回 ≤30 行文件:行号地图即可。验收命令用项目配置的测试命令（项目级 `DELEGATE_DEFAULT_TEST_CMD`，多个前缀用逗号分隔）。首次在无 `.agents/delegation/config.env` 的非 Python 项目委派前，先检查并补齐项目级 `DELEGATE_DEFAULT_TEST_CMD`（例如 Node.js 推荐：`npm test,npm run,node --test,git status,git diff,git log,git add,git commit`，按需可追加 `,git push`），避免 `coder` 遇 `permission_denials` 或因传 `--test-cmd` 触发审批弹窗。单测全绿是弱信号——涉及交互行为的改动，把项目自带的 eval / 冒烟也写进验收，否则回归要等用户手测才暴露。

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
>
> **落盘位置**：在 AGY 内，简报与 `--out` 默认放 `<artifactDirectoryPath>/scratch/`（守卫自动放行，免工作区外写权限弹窗、不污染 `git status`）或 `DELEGATE_SCRATCH_DIR`；`--dir` 仍必须在工作区或 `DELEGATE_SCRATCH_DIR` 内。
>
> **在 AGY 主会话内调用**：写 `bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh ...`。未开启 `DELEGATE_AUTO_ALLOW_DELEGATE` 时，AGY 会就「执行工作区外的脚本并绕过沙箱」弹一次权限确认——这是默认的安全行为，确认后继续即可；在 AGY 里不需要再套一层 `run_delegate.sh` 去起 Hydrogen：`fast` 级小活直接用原生 `invoke_subagent(TypeName="self", Model="flash")`（守卫为 `deny` 时改走 `--role coder`）。
>
> **等待与判定（不要误杀还在干活的 coder）**：多文件任务可能跑十几分钟，而且开头几分钟往往只有读取和检索、没有任何文件改动——`--out` 文件是 0 字节、`git status` 没变化都属于正常，结果只在结束时写入。脚本在运行期间每 `DELEGATE_HEARTBEAT_INTERVAL` 秒（默认 30）向 stderr 打一行 `[DELEGATE]` 进度（已用时、工具调用次数、最近一次调用的工具和目标）；Claude Code 的完整事件流留在 `<out>.events.jsonl`。`NotificationTimeoutSeconds` 设 900 以上，收到通知后先查进度——读后台任务日志里的 `[DELEGATE]` 行，或者运行 `bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh --progress <out.json>`（直接读磁盘上的事件流和进程状态，不依赖任务日志是否实时）：**查询显示 `running`、没有出现 `status: "failed"` 报告、工具调用次数在涨，就继续等**。真要接手，先确认 coder 已经退出（`--progress` 不再显示 `running`），否则会和它改同一批文件。

### 步骤 4：主会话独立验收（不信自报，且不污染主会话）
1. **检查改动边界**：`git diff --stat` 确认只改了允许文件、测试文件零改动、无残留文件。凡 `*.snap`、`*snapshots*.json`、`package-lock.json` 等大快照或单行超大文件，**禁止主会话直接裸跑 `git diff`**，交由只读 `scout` 或 `coder` 按键级比对返回 ≤10 行摘要。
2. **独立跑验收命令（隔离大输出）**：短输出单点校验可由主会话轻跑；**全量测试（`npm test` / `pytest` 等）、评测跑批与构建验收统一交由 `coder` 通道执行**（日志留存 `coder` 侧或落盘，只回传 5–10 行结构化摘要：通过/失败数、关键指标、失败定位与报告路径；**明文禁止**派只读无网 `research` 子代理跑需本地端口或家目录配置的测试，也禁止主会话裸跑）。
3. **审查 Diff 逻辑**：逐行读关键 diff，严防硬编码凑通过、删断言或弱化校验（大 diff 可先由只读 `scout` 提炼疑点）。
4. **检查异常信号**：输出是 harness 的结果 JSON 时，核对 `is_error`、`permission_denials` 或回复中是否有“被拒绝/未能运行”；输出是 `status: "failed"` 的失败报告时，按 `attempts[].reason` 区分**环境问题**（端点或代理不可达、配额、headless 下工具被拒）与**任务问题**。环境问题按报告里的 `next` 处理（守卫策略允许时改用原生 `invoke_subagent(TypeName="self", Model="flash")`，`deny` 下由主会话接手），或修复通道后重试，不要原地反复重跑同一条命令。
5. **熔断与升级**：若 `coder` 2–3 轮仍未通过，收集失败日志与当前 diff，由主会话诊断后补充背景重试，或升级到 `--role heavy`。

### 步骤 5：合入与清理（常规 Git 收尾可走 `coder`）
验收全绿后，将改动合入主工作区（`git merge` / `cherry-pick`），移除 worktree（`git worktree remove .trees/<task>`）或清理 scratch 目录。常规 Git 整理与收尾（核对 `git status` / `git diff --stat`、按白名单路径精准 `git add`、分批 `git commit`、仅用户明确授权时 `git push`）也可直接写入简报交由 `coder` 执行，释放主会话额度与轮次。

---

## 5. 安全红线

- **严禁**使用 `--yolo`、`-f`、`--dangerously-skip-permissions`，除非用户当次明确授权。
- **严禁**在 `config.env` 中写入明文 API Key（仅通过 `*_API_KEY_ENV` 引用环境变量名）。
- **严禁**子代理修改测试文件以掩盖代码问题（除非任务本身是编写/更新测试）。
- **严禁**多个写任务共享同一个工作目录。
- **Git 操作红线**：在 `DELEGATE_DEFAULT_TEST_CMD` 配置 Git 白名单时，**无用户明确指令严禁 `git push`**；**严禁** `--force`、`--force-with-lease` 滥用、`git reset --hard`、`git clean -fd` 等破坏性参数；**严禁** `git add -A` / `git add .`（必须按白名单路径精准暂存）。
- **`DELEGATE_AUTO_ALLOW_DELEGATE=1` 是一项长期授权**，只在你信任当前主会话时开启：它让规范形式的 `run_delegate.sh` 命令免权限确认并绕过 AGY 沙箱，而被委派的 Claude Code 可以在 `--dir` 内改文件、执行**配置里**的测试/Git 白名单命令（`Bash(<test-cmd>:*)`）。守卫 Hook 只放行同时满足以下条件的命令，其余一律回到 AGY 默认权限流程：角色/预设在已知列表内；不带自定义 `--test-cmd`；`--dir` 在工作区或 `DELEGATE_SCRATCH_DIR` 内；`--brief` / `--out` / `--progress` 在工作区、`DELEGATE_SCRATCH_DIR` 或 `<artifactDirectoryPath>/scratch/` 内；不含 shell 元字符，也没有重复选项。
- **守卫 Hook 出错时只会「不干预」**：任何异常都回答 `ask`（回到 AGY 默认权限流程），绝不因为崩溃而放行或拦截。
- **合规边界**：CLI 委派仅限单用户在人工发起的当前工作流中按需调用，**严禁** 24/7 无人值守挂机循环或接入违规第三方代理。
