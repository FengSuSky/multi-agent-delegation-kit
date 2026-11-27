### 模型分工与委派（角色路由）

- **主会话零噪音定位（Clean Main Session）**：主会话只保留**与用户交互、当前计划与决策、追踪 subagent 进展与最终结果对齐**；不要在主会话直接刷屏执行大量 tool calls（如 `npm test`、全量构建、多文件代码检索、长日志分析、多轮试错），所有中间过程与大输出均隔离在 subagent 上下文或落盘日志中，只向主会话回传 5–10 行结构化结果摘要。主会话同样不为「实现」去通读源码：需要了解代码时让 scout 返回「文件 + 行号范围」的代码地图，只读验收 diff 真正需要的最小范围。
- **分层配置优先**：执行委派前按 `项目级 (.agents/delegation/) > 用户级 (~/.config/multi-agent-delegation/) > 核心 MD > Skill 默认值` 读取角色绑定（可通过 `~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --show` 查看当前生效映射）。
- **5 角色路由（默认下沉，失败熔断升级）**：
  - **`scout`（侦察/监控）**：代码检索、摘要、全量测试/评测监控、大日志分析、结构化抽取（隔离大输出，只回 5–10 行摘要；大型盘点拆细、先列清单与行号索引，避免单次过长调研；AGY 主会话内优先原生 `research` 子代理加 `flash_lite`，需要推理时用 `flash`）。
  - **`fast`（轻量执行）**：细微杂活、补单个单测、中小型确定性改动，以「一两个文件、不需要先读代码定位、一轮改完自验」为界，超出就是 `coder`（低成本 + 终端自验，如 AGY Hydrogen / DeepSeek；AGY 内直接用 `invoke_subagent(TypeName="self", Model="flash", Workspace="share")`，守卫为 `deny` 时会被拦截；不要再嵌套 `agy -p`）。
  - **`coder`（主力实现）**：常规/多文件代码实现、带测试闭环的 Bug 修复（通过 `run_delegate.sh --role coder` 派发给强 Harness + 高性价比 Coding Plan，如 Claude Code + 智谱 GLM / DeepSeek / Kimi）。
  - **`heavy`（攻坚升级）**：`coder` 连续 2–3 轮自修测试仍不绿时停止空转，携带失败上下文升级给旗舰模型攻坚。
  - **`architect`（架构拍板）**：高风险架构、跨模块重构或棘手权衡时，主会话先提炼高密度上下文，再以只读 Plan 模式联合决策。
  - **异构交叉 Review**：绝不让写代码的同源模型自审。
  - **配额兜底降级与多轮复用**：外部渠道无额度/报错时自动降级到兜底角色（默认 `fast`）并在本会话熔断故障通道；同主题多轮任务优先通过 `--keep-session` + `--resume <id>` 或原生 `send_message` 复用上下文与缓存。`run_delegate.sh` 失败时输出是 `status: "failed"` 的 JSON 报告，按 `attempts[].reason` 与 `next` 处理，不要原地重跑。注意 Neon 与 Hydrogen 共用同一份 AGY 配额，把活交给 `flash` 并不减少 AGY 总用量。`run_delegate.sh` 的输出文件只在结束时写入，运行期间是 0 字节属正常：`NotificationTimeoutSeconds` 设 900 以上，收到通知后用 `run_delegate.sh --progress <out.json>` 查到仍在 `running` 就继续等，没有失败报告时不要 kill 后自己接手；真要接手，先确认它不再显示 `running`。
- 禁止使用 `--yolo`、`-f`、`--dangerously-skip-permissions`，除非明确授权；禁止在 `config.env` 写入明文 API Key。
- **工作目录与简报落盘**：单任务直接 `--dir .` 改当前工作区、靠 `git diff` 验收；仅并发多写任务才开 `git worktree` 隔离（非 git 仓库用独立目录 `~/work/agy-scratch/<task>/`）。在 AGY 内，简报与输出 JSON 默认落盘到 `<artifactDirectoryPath>/scratch/`（免工作区外写权限弹窗、不污染 `git status`，守卫自动放行）或 `DELEGATE_SCRATCH_DIR`。首次在无 `.agents/delegation/config.env` 的非 Python 项目委派前，先检查并补齐项目级 `DELEGATE_DEFAULT_TEST_CMD`（如 `npm test,npm run,npx`、`pytest,python3`、`go test`、`cargo test`），避免 `coder` 遇 `permission_denials` 或因传 `--test-cmd` 触发审批弹窗。
- 任务简报必须包含：目标、验收命令、允许改的文件、禁止事项（默认"禁止改测试"）、必要背景、汇报行数上限。
- 验收清单：查 diff 范围是否越界 → 确认测试文件未改 → 主会话独立跑验收命令 → 逐行读 diff 防硬编码 → 检查 `is_error` / `permission_denials` / "被拒"，输出为失败报告时先看 `attempts[].reason`。
- 完整流程与委派脚本见全局 Skill `~/.agents/skills/multi-agent-delegation/`。
