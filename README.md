# Multi-Agent Delegation Kit（多 Agent 异构协作套件）

> 一套面向 **高质量、低成本** 软件开发的多 Agent 分层协作方案与可安装 Skill 套件。
> 核心思路：**强模型主控（AGY Gemini 4 Neon）+ 强 Harness 平价主力（Claude Code GLM-5.3-Flash / AGY Hydrogen）+ 2–3 轮熔断升级（Sonnet 5.5）+ 难点联合决策（Opus 5.5）+ 全断自动降级（Hydrogen）**。

---

## 一、快速安装（两种方式）

### 方式 A：让 AGY（或 Claude Code）直接帮你安装（推荐，跨电脑/分享给他人最省事）
在任意电脑上，直接对 AGY 说：

> 「请克隆 `https://github.com/FengSuSky/multi-agent-delegation-kit`，读取其中的 `README.md`，检查我本机已安装的 CLI（`agy` / `claude` / `agent`），帮我运行 `install.sh --with-rules` 完成安装，并做一次语法校验确认生效。」

### 方式 B：命令行一键安装
```bash
# 0. 克隆仓库
git clone https://github.com/FengSuSky/multi-agent-delegation-kit.git
cd multi-agent-delegation-kit

# 1. 先预览将要安装和修改的文件（不落盘）
bash ./install.sh --with-rules --dry-run

# 2. 完整安装：安装全局 Skill + 幂等注入默认委派规则到 ~/.gemini/AGENTS.md 与 ~/.claude/CLAUDE.md
bash ./install.sh --with-rules

# 若只想安装 Skill、不想修改你的全局 AGENTS.md / CLAUDE.md：
bash ./install.sh --skill-only
```

> **后续更新**：拉取最新代码后重新运行 `install.sh` 即可幂等升级（`git pull && bash ./install.sh --with-rules`）。
> **安全保证**：`install.sh` 使用 `<!-- BEGIN/END multi-agent-delegation -->` 标记块幂等更新规则文件，不会覆盖你原有的全局偏好，并在修改前自动生成 `.bak.<timestamp>` 备份。

---

## 二、套件目录结构

```text
multi-agent-delegation-kit/
├── README.md                          # 本说明（含人机通用安装指南）
├── install.sh                         # 一键幂等安装脚本（支持 --dry-run / --skill-only / --with-rules）
├── docs/
│   └── architecture-and-benchmarks.md # 架构原理、强模型×弱Harness 互补分析、实测数据与官方最佳实践
├── rules/
│   ├── AGENTS-snippet.md              # 注入 ~/.gemini/AGENTS.md 的极简默认委派规则（仅 3 条）
│   └── CLAUDE-snippet.md              # 注入 ~/.claude/CLAUDE.md 的模型分工与委派规则
└── skill/
    └── multi-agent-delegation/        # 可直接拷贝至 ~/.agents/skills/ 的标准 Skill 包
        ├── SKILL.md                   # 路由表、降级链、多轮复用、5 步执行流与安全红线
        ├── references/
        │   └── delegation-best-practices.md  # 实测对照数据、CLI 参数踩坑与五段式简报模板
        └── scripts/
            └── run_delegate.sh        # 跨 CLI 委派脚本（内置自动降级、--resume 复用、费用熔断）
```

---

## 三、前置环境说明（按需配置，缺项自动降级）

| 工具 / 渠道 | 角色 | 必需？ | 配置要点 |
| :--- | :--- | :--- | :--- |
| **AGY (`agy`)** | 主会话（Neon）+ 轻量主力 & 全断兜底（Hydrogen） | **推荐必需** | 登录 Antigravity 账号即可；支持 `gemini-4-neon-medium` / `gemini-4-hydrogen-{low,medium}` / `claude-*-5-5` |
| **Claude Code (`claude`)** | 多文件实现与长程写码主力（配平价模型 API，如 GLM-5.3-Flash） | 可选（无则自动降级 Hydrogen） | 在 `~/.claude/settings.json` 配置兼容 Anthropic 协议的 API（如 Z.ai GLM）；无需 `--dangerously-skip-permissions` |
| **Cursor Agent CLI (`agent`)** | 稀缺攻坚兜底（Sonnet 5.5） | 可选（无则用 AGY Sonnet 或 Hydrogen） | 登录 Cursor CLI；默认 allowlist 限制 shell，改完由主会话验收 |

> **零外部依赖也能跑**：如果某台机器只有 `agy`（或外部 Claude Code / Cursor 额度全部耗尽），本套件会自动降级为全员 **AGY Hydrogen**（或 AGY 原生 `invoke_subagent`）运行，不会卡死。

---

## 四、给 Agent 的自动化安装步骤（供 AGY / Claude Code 读取执行）

当你（Agent）收到用户要求「按本 README 安装」时，请依次执行：
1. **环境探测**：运行 `which agy claude agent || true` 告知用户本机已就绪的渠道与缺失渠道（缺失渠道会自动降级，无需阻塞安装）。
2. **预览安装**：运行 `bash "<kit_dir>/install.sh" --with-rules --dry-run`，确认目标路径无误。
3. **执行安装**：
   - 若用户明确要默认自动生效：运行 `bash "<kit_dir>/install.sh" --with-rules`；
   - 若用户只想试用 Skill 不动全局规则：运行 `bash "<kit_dir>/install.sh" --skill-only`。
4. **安装验收**：
   - 运行 `bash -n ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh` 与 `~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh --help`；
   - 确认 `~/.agents/skills/multi-agent-delegation/SKILL.md` 存在且无损坏；
   - 提示用户开启新会话即可默认生效（或直接通过 `multi-agent-delegation` 触发）。
