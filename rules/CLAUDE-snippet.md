### 模型分工与委派

- **主会话定位（AGY `gemini-4-neon-medium`）**：负责日常交流、需求澄清、方案设计、上下文组织与最终验收；细微杂活与常规实现不下沉给主会话硬扛，优先委派便宜执行者。
- **困难任务联合决策（`claude-opus-5-5-medium`）**：遇到高风险架构、复杂跨模块重构或棘手权衡时，先由主会话（Neon）高效提炼上下文与候选项，再调用少量 Opus 5.5 额度（AGY `--mode plan` 或独立窗口）共同拍板。
- **选执行者（默认下沉，失败熔断升级）**：
  - **检索、摘要、结构化抽取、细微杂活、中小型确定性改动（首选）**：优先使用 AGY 原生 `invoke_subagent`（`flash`），或 AGY CLI `agy --model gemini-4-hydrogen-{low,medium} --output-format json --print-timeout 300s -p "..."`（`-p` 必须放最后；cwd 必须在 `$HOME` 下，不可在 `/tmp` 写文件）。
  - **常规/多文件代码实现、带测试闭环的 Bug 修复（主力）**：用 Claude Code + 平价模型（如 GLM-5.3-Flash），通过 `~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh --preset glm` 派发（stdin 传简报避免 `--allowedTools` 吞参数，终端可自验）。
  - **攻坚升级（熔断兜底）**：便宜模型连续 2–3 轮自修测试仍不绿时，停止空转，携带失败上下文升级给 **Sonnet 5.5**（Cursor 或 AGY）。
  - **异构交叉 Review**：绝不让写代码的同源模型自审（GLM 写的由 Neon 审，Hydrogen/Neon 写的由 GLM 或 Sonnet 审）。
  - **配额兜底降级**：若 Cursor 与 Claude Code 均无额度或报配额/限流错误，统一自动降级为 `AGY gemini-4-hydrogen-medium`（或 AGY 原生 subagent）兜底，并在本会话内熔断故障通道。
  - **多轮复用**：同主题/同模块后续任务优先复用已有 subagent 或通过 `--keep-session` + `--resume <id>` 续接会话，复用上下文与缓存，不反复新建。
- 禁止使用 `--yolo`、`-f`、`--dangerously-skip-permissions`，除非明确授权。
- 并行任务优先用 `git worktree` 隔离；非 git 仓库用独立目录 `~/work/agy-scratch/<task>/`。
- 任务简报必须包含：目标、验收命令、允许改的文件、禁止事项（默认"禁止改测试"）、必要背景、汇报行数上限。
- 验收清单：查 diff 范围是否越界 → 确认测试文件未改 → 主会话独立跑验收命令 → 逐行读 diff 防硬编码 → 检查 `is_error` / `permission_denials` / "被拒"。
- 完整流程与委派脚本见全局 Skill `~/.agents/skills/multi-agent-delegation/`。
