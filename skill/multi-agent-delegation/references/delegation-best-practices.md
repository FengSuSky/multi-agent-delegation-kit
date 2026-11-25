# 多 Agent 异构委派：实测基准与 CLI 速查

> 适用于 `multi-agent-delegation` Skill。全程未使用 `--yolo` / `-f` / `--dangerously-skip-permissions`。

## 1. 中等任务横向实测对比（`inventory.py` 5 Bug + 6 Pytest）

| 执行者 | 耗时（墙钟 / API） | 结果与自验 | 改测试 / 越界 | Token（in / out / cache） | 备注 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **AGY `gemini-4-hydrogen-medium`** | **27.3s** | 6 passed，**自验通过** | 否 / 否 | 20.0k / 1.68k (thinking 495) / 41.0k | 全场最快，主动处理重复 SKU 累加 |
| **Claude Code `glm-5.3-flash[1m]`** | **38.5s** (API 18.9s) | 6 passed，**自验通过** | 否 / 否 | 46.3k / 1.30k / 48.0k | 6 turns，`permission_denials: []` |
| **Cursor `claude-sonnet-5-5-medium`** | 61s (API 36s) | 6 passed（主会话复验） | 否 / 否 | 12 / 1.8k / 115k+20k | 质量稳，受 allowlist 限制不能自验 |
| **AGY `gemini-3.8-flash-medium`** | 205s (API 190s) | 6 passed，自验通过 | 否 / 否 | 24.7k / 6.5k (thinking 5.6k) / 70k | 已被 `gemini-4-hydrogen-medium` 替代 |
| **Cursor `grok-4.7-medium-fast`** | 418s | 6 passed（主会话复验） | 否 / 否 | 121k / 10.4k (reasoning 8.4k) / 1.0M | 慢且费 token，仅适合低频第二意见 |

---

## 2. 各 CLI 实测要点与踩坑

### Claude Code (`claude`)
- **推荐非交互命令**（安全自验）：
  ```bash
  claude -p --model sonnet --effort high --max-budget-usd 1.00 \
    --no-session-persistence --exclude-dynamic-system-prompt-sections \
    --permission-mode acceptEdits --permission-prompts none \
    --output-format json --allowedTools "Read,Edit,Write,Bash(python3:*)" < brief.txt
  ```
- **关键踩坑**：`--allowedTools` 为变长参数，**简报必须走 stdin 重定向（`< brief.txt`）或 `--` 分隔**，否则会把 prompt 吃进工具列表报错。
- **多轮复用**：去掉 `--no-session-persistence`（脚本传 `--keep-session`），次轮传 `--resume <session_id>`。

### AGY (`agy`)
- `-p` 必须放最后；cwd 必须在 `$HOME` 下（`/tmp` 写文件被拒）；加 `--print-timeout 300s`。
- 支持 `--json-schema` 强约束结构化输出、`--mode plan` 只读评审、`--resume <conversation_id>` 多轮复用。
- 读取 `AGENTS.md` 和 `GEMINI.md`。

### Cursor Agent CLI (`agent`)
- `-p --trust` 且不加 `--force` 时受 `~/.cursor/cli-config.json` allowlist 限制无法跑测试，由主会话验收（进阶可测 `--auto-review` + `--sandbox enabled`）。
- 单次存在 ~10–60k 固定系统上下文开销；支持 `--mode plan`、`--mode ask`、`-w/--worktree`、`--resume <session_id>`。

---

## 3. 五段式简报模板

```markdown
## 目标
<一句话: 修什么 / 做什么，达成什么状态>

## 验收
在当前目录运行: <命令>  (期望: <全绿 / 输出X>)

## 范围
只允许修改: <文件列表>。禁止: 修改测试 / 其他文件 / 新建文件 / 改公开签名 / 装依赖。

## 背景（可选，只放必要事实）
<已知根因、文件:行号、主会话已拍板的决定>

## 完成后
3-5 行以内汇报: 改动点 + 根因 + 验收命令末行输出（最多自修 2-3 轮，仍失败则停止并汇报卡点）
```

## 4. 主会话验收清单（不信自报，自己验）

1. `git diff --stat` / `diff -ru` 确认只改了允许文件、测试未改、无多余文件；
2. 主会话自己跑验收命令确认全绿；
3. 逐行读 diff 防硬编码、特判或弱化校验；
4. 检查输出 JSON 的 `is_error`、`permission_denials` 或回复文本中有无“被拒/未能运行”；
5. 核对耗时与 `usage`；通过后合入主分支并清理 worktree / scratch。
