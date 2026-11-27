### 模型分工与委派（角色路由）

- **主会话零噪音与防膨胀定位（Clean Main Session）**：主会话只保留**与用户交互、当前计划与决策、追踪 subagent 进展与最终结果对齐**；**主会话禁止裸跑全量 `npm test` / `pytest` 等大输出测试**，全量测试/评测跑批统一走 `coder` 通道，只向主会话回传 5–10 行结构化摘要。同时遵守 3 条防膨胀约束：
  - **不代读参考源码**：写简报只放「目标 + 验收 + 范围 + 失败日志路径 + 已知根因」；需要代码位置时让 `scout` 返回 ≤30 行「文件:行号」地图，不把源码片段抄进简报。
  - **大快照 / 单行超大文件不裸 diff**：`*.snap`、`*snapshots*.json`、`package-lock.json` 等禁止主会话直接 `git diff`，交由 `scout` 或 `coder` 按键级比对返回 ≤10 行摘要。
  - **免重复通读 `SKILL.md`**：常规 `--role coder` 派发与验收以本片段为准，仅涉及 `--resume`、`load_config.sh` 或故障排查时按章节局部读取 `SKILL.md`。
- **分层配置优先**：执行委派前按 `项目级 (.agents/delegation/) > 用户级 (~/.config/multi-agent-delegation/) > 核心 MD > Skill 默认值` 读取角色绑定（可通过 `~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --show` 查看当前生效映射）。
- **5 角色路由（Read vs Act 硬边界，失败熔断升级）**：
  - **`scout`（纯只读分析）**：代码地图、大日志/测试报告根因定位、大快照 diff 摘要、文档盘点（隔离大输出，只回 5–10 行摘要；大型盘点拆细、先列清单与行号索引；AGY 主会话内优先原生 `research` 子代理加 `flash_lite`，需要推理时用 `flash`；**明文禁止**派只读无网 `research` 跑需本地端口或家目录配置的测试套件）。
  - **`fast`（轻量执行）**：细微杂活、补单个单测、中小型确定性改动，以「一两个文件、不需要先读代码定位、一轮改完自验」为界，超出就是 `coder`（低成本 + 终端自验，如 AGY Hydrogen / DeepSeek；AGY 内直接用 `invoke_subagent(TypeName="self", Model="flash", Workspace="share")`，守卫为 `deny` 时会被拦截；不要再嵌套 `agy -p`）。
  - **`coder`（统一 Act 执行通道）**：多文件代码实现 + 自测闭环、**全量测试/评测跑批与失败排查**、**常规 Git 整理与收尾**（`git status` / `git diff --stat`、白名单路径精准 `git add`、分批 `git commit`、仅在用户明确授权时 `git push`），通过 `run_delegate.sh --role coder` 派发给强 Harness + 高性价比 Coding Plan（如 Claude Code + 智谱 GLM / DeepSeek / Kimi）。
  - **`heavy`（攻坚升级）**：`coder` 连续 2–3 轮自修测试仍不绿时停止空转，携带失败上下文升级给旗舰模型攻坚。
  - **`architect`（架构拍板）**：高风险架构、跨模块重构或棘手权衡时，主会话先提炼高密度上下文，再以只读 Plan 模式联合决策。
  - **异构交叉 Review**：绝不让写代码的同源模型自审。
  - **配额兜底降级与多轮复用**：外部渠道无额度/报错时自动降级到兜底角色（默认 `fast`）并在本会话熔断故障通道；同主题多轮任务优先通过 `--keep-session` + `--resume <id>` 或原生 `send_message` 复用上下文与缓存。`run_delegate.sh` 失败时输出是 `status: "failed"` 的 JSON 报告，按 `attempts[].reason` 与 `next` 处理，不要原地重跑。注意 Neon 与 Hydrogen 共用同一份 AGY 配额，把活交给 `flash` 并不减少 AGY 总用量。`run_delegate.sh` 的输出文件只在结束时写入，运行期间是 0 字节属正常：`NotificationTimeoutSeconds` 设 900 以上，收到通知后用 `run_delegate.sh --progress <out.json>` 查到仍在 `running` 就继续等，没有失败报告时不要 kill 后自己接手；真要接手，先确认它不再显示 `running`。
- **安全红线**：禁止使用 `--yolo`、`-f`、`--dangerously-skip-permissions`，除非明确授权；禁止在 `config.env` 写入明文 API Key；**无用户明确指令禁止 `git push`，严禁 `--force` / `git reset --hard` 等破坏性参数，禁止 `git add -A` / `git add .`**。
- **工作目录与简报落盘**：单任务直接 `--dir .` 改当前工作区、靠 `git diff --stat` 验收；仅并发多写任务才开 `git worktree` 隔离（非 git 仓库用独立目录 `~/work/agy-scratch/<task>/`）。在 AGY 内，简报与输出 JSON 默认落盘到 `<artifactDirectoryPath>/scratch/`（免工作区外写权限弹窗、不污染 `git status`，守卫自动放行）或 `DELEGATE_SCRATCH_DIR`。首次在无 `.agents/delegation/config.env` 的非 Python 项目委派前，先检查并补齐项目级 `DELEGATE_DEFAULT_TEST_CMD`（示范：`npm test,npm run,node --test,git status,git diff,git log,git add,git commit`，按需可追加 `,git push`），避免 `coder` 遇 `permission_denials` 或因传 `--test-cmd` 触发审批弹窗。
- 任务简报必须包含：目标、验收命令、允许改的文件、禁止事项（默认"禁止改测试"）、必要背景（仅失败日志路径/已知根因，不抄源码）、汇报行数上限。
- 验收清单：查 `git diff --stat` 确认边界（大快照文件不裸 diff）→ 确认测试文件未改 → 短输出单点校验可轻跑，全量测试/评测跑批交由 `coder` 执行并回传 5–10 行摘要 → 逐行读关键 diff 防硬编码 → 检查 `is_error` / `permission_denials` / "被拒"，输出为失败报告时先看 `attempts[].reason`。
- 完整流程与委派脚本见全局 Skill `~/.agents/skills/multi-agent-delegation/`。
