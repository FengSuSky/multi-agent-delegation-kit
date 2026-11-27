# Multi-Agent Delegation Kit（多 Agent 异构协作套件）

> 一套面向**多订阅开发者（尤其是国内多 Coding Plan 用户）**、兼顾**高质量与低成本**的通用多 Agent 分层协作框架与可安装 Skill 套件。
>
> **核心理念**：不绑定单一厂商，而是把不同 **模型（成本/推理能力）× Harness（工具链/自验闭环）** 映射到 **5 个通用角色（`scout` / `fast` / `coder` / `heavy` / `architect`）**——用便宜快的组合干体力活、用强 Harness + 高性价比模型做主力实现、2–3 轮不绿自动熔断升级旗舰、渠道不可用自动降级。
>
> 路由不只写在规程里：**AGY 守卫 Hook** 用机制让主模型留在编排位置；委派脚本**先预检网络**、运行期间输出**进度心跳**（`--progress` 随时可查），失败时给出**结构化报告**并沿**多级回退链**重试。

---

## 一、为什么需要「角色抽象 × 订阅组合 Profile」？

不同开发者手里的订阅各不相同（例如作者日常使用 **AGY + Cursor + 智谱 GLM**，也有人用 **Claude Code + DeepSeek + GLM/Kimi**，或只用单订阅 **AGY**）：

| 通用角色 (`--role`) | 职责定位 | 典型选型思路 |
| :--- | :--- | :--- |
| **`scout`** | **纯只读分析**：代码地图、大日志/测试报告根因定位、大快照 diff 摘要、文档盘点（**禁止**跑需本地端口或家目录配置的测试） | 极快便宜、隔离大输出（AGY Hydrogen-low / DeepSeek-Chat / 原生 `research` + `flash_lite`） |
| **`fast`** | 细微杂活、补单测、中小型确定性改动 | 低成本 + 终端自验（AGY Hydrogen / DeepSeek-Chat） |
| **`coder`** | **统一 Act 执行通道**：多文件实现 + 自测闭环、**全量测试/评测跑批**、**常规 Git 整理收尾**（精准 `git add` / 分批 `commit` / 仅授权时 `push`） | 强 Harness（Claude Code）× 国内高性价比 Coding Plan（智谱 GLM / Kimi / DeepSeek / MiniMax） |
| **`heavy`** | `coder` 连续 2–3 轮自修不绿时的熔断升级 | 稀缺旗舰编程模型（Sonnet / GLM-5.4 / Cursor） |
| **`architect`** | 高风险架构、跨模块权衡（只读 Plan 模式） | 最强推理旗舰（Opus / Neon），主会话先提炼高密度上下文再拍板 |

### 内置 3 套开箱即用 Profile（面向国内多订阅场景）
- **`agy-cursor-zhipu`**（作者本机实战方案）：AGY 负责主控/侦察/轻量兜底 + Claude Code 接智谱 GLM 做主力写码 + AGY/Cursor Sonnet 攻坚 + Opus 只读拍板。
- **`claude-deepseek-glm`**（纯 Claude Code + 国产多模型）：`scout`/`fast` 走 DeepSeek Anthropic 兼容端点，`coder` 走智谱 GLM / Kimi 等 Coding Plan，同一台机器按角色自动切换不同端点与环境变量。
- **`agy-only`**（零外部依赖兜底方案）：仅需 AGY 订阅，全角色平滑运行。

---

## 二、快速安装与安全升级

### 方式 A：让 AGY（或 Claude Code）直接帮你安装（推荐）
在任意电脑上，直接对 AGY 说：

> 「请克隆 `https://github.com/FengSuSky/multi-agent-delegation-kit`，读取 `README.md`，检查我本机已安装的 CLI（`agy` / `claude` / `agent`），帮我选择最合适的 Profile 运行 `install.sh --with-rules --profile <name>` 完成安装并验收。」

### 方式 B：命令行一键安装
```bash
# 0. 克隆仓库
git clone https://github.com/FengSuSky/multi-agent-delegation-kit.git
cd multi-agent-delegation-kit

# 1. 预览安装动作（不落盘）
bash ./install.sh --with-rules --with-hooks --profile agy-cursor-zhipu --dry-run

# 2. 按你的订阅组合一键安装（可选 profile：agy-cursor-zhipu | claude-deepseek-glm | agy-only）
#    --with-hooks 安装 AGY 守卫 Hook（不用 AGY 主会话时去掉即可）
bash ./install.sh --with-rules --with-hooks --profile agy-cursor-zhipu

# 若只想安装 Skill 与用户配置、不想修改你的全局 AGENTS.md / CLAUDE.md / hooks.json：
bash ./install.sh --skill-only --profile claude-deepseek-glm
```

> **安全升级**：拉取最新代码后运行 `git pull && bash ./install.sh --with-rules --with-hooks`（或 `--skill-only`）即可幂等升级。
> - `install.sh` **绝不会覆盖**你的 `~/.config/multi-agent-delegation/{config.env,overrides.md}`；
> - 规则注入使用 `<!-- BEGIN/END multi-agent-delegation -->` 标记块幂等更新，修改前自动生成 `.bak.<timestamp>` 备份；
> - `--with-hooks` 只改动 `~/.gemini/config/hooks.json` 里名为 `multi-agent-delegation-guard` 的条目（其它 hook 原样保留，旧的同名条目原地升级），修改前同样备份；该文件不是合法 JSON 时会拒绝改写。

---

## 三、用户级与项目级配置（安全定制，自动联动核心 MD）

无需修改 Skill 源码，通过分层配置即可自由替换任意角色的 Harness、模型 ID 或国产 Anthropic 兼容端点：

```text
生效优先级（高 → 低）：
命令行参数 > 项目级配置 (.agents/delegation/) > 用户级配置 (~/.config/multi-agent-delegation/) > Skill 默认值
```

| 层级 | 路径 | 用途 |
| :--- | :--- | :--- |
| **用户级** | `~/.config/multi-agent-delegation/config.env` | 配置 5 角色绑定（`DELEGATE_ROLE_*=harness:model`）、按角色端点（`*_BASE_URL` / `*_API_KEY_ENV`）、禁用 Harness/预设、默认预算与超时 |
| **用户级** | `~/.config/multi-agent-delegation/overrides.md` | 自然语言个人偏好（渠道配额备注、自定义路由习惯），与 `~/.gemini/AGENTS.md` / `~/.claude/CLAUDE.md` 自动联动 |
| **项目级** | `<repo>/.agents/delegation/config.env` | 覆盖当前项目的测试与本地 Git 安全白名单命令（如 `DELEGATE_DEFAULT_TEST_CMD=npm test,npm run,node --test,git status,git diff,git log,git add,git commit`）、预算上限或单角色模型 |
| **项目级** | `<repo>/.agents/delegation/overrides.md` | 当前项目的验收命令、禁改目录与升级策略，与 `<repo>/AGENTS.md` / `<repo>/CLAUDE.md` 自动联动 |

### 常用配置与调试命令
```bash
# 查看所有内置订阅组合 Profile
bash ~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --list-profiles

# 切换 Profile（加 --force 覆盖现有 config.env）
bash ~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --use-profile claude-deepseek-glm --force

# 查看当前目录生效的合并配置（含来源标注）及自动发现的本地核心 MD
bash ~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --show --dir .

# 预览某个角色在当前项目下会解析成哪个 harness/model/endpoint（不实际调用 CLI）
bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh --role scout --resolve-only --dir .

# 为某个项目初始化项目级配置模板（不覆盖已有文件）
bash ~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --init-project /path/to/your-project
```

> **安全保证**：
> - `config.env` 采用白名单 `KEY=VALUE` 解析（不执行 `source` / `eval`），克隆陌生仓库也不会触发命令注入；
> - `*_API_KEY_ENV` 只填环境变量名（如 `DEEPSEEK_API_KEY`），绝不在配置文件中存放明文密钥；
> - 行内注释需要在 `#` 前留空白；`none` / `0` 表示关闭对应限制（例如 `DELEGATE_DEFAULT_MAX_BUDGET=none`）。

### AGY 守卫 Hook：用机制落实路由

文字约定挡不住「主模型顺手自己把活干了」。`install.sh --with-hooks` 会装一个 AGY PreToolUse hook（`guard_subagent.py`），全部策略在 `config.env` 里配置：

| 配置项 | 取值 | 作用 |
| :--- | :--- | :--- |
| `DELEGATE_INHERIT_SUBAGENT` | `rewrite`（默认）/ `deny` / `allow` | `invoke_subagent(Model="inherit")` 即「让子代理跑在主模型上」时：自动改写成轻量档 / 拦截并引导到 coder 通道 / 不干预。`deny` 还会拦下 `self` 子代理（不论 `Model`，`flash` 也算），只放行只读 `research` 子代理的轻量档 |
| `DELEGATE_INHERIT_REWRITE_MODEL` | `flash`（默认）/ `flash_lite` | 被改写到的原生子代理档位 |
| `DELEGATE_AUTO_ALLOW_DELEGATE` | `0`（默认）/ `1` | `1` 时规范形式的 `run_delegate.sh` 命令免权限弹窗、绕过沙箱 |

Prompt 里带 `[allow-inherit]` 可以放行单次调用。Hook 出错时一律回答 `ask`（回到 AGY 默认权限流程），不会因崩溃而放行或拦截。

> 只按 `Model` 拦不住写码任务：守卫把 `inherit` 改写成 `flash` 之后，主会话会把多文件编码任务直接写成 `Model="flash"` 派出去，所以 `deny` 连 `self` 类型一起拦。

> `DELEGATE_AUTO_ALLOW_DELEGATE=1` 是一项长期授权：被委派的 Claude Code 可以在 `--dir` 内改文件、执行配置里的测试命令。Hook 只放行已知角色、不带自定义 `--test-cmd`、三个路径都在工作区（或 scratch 目录）内、不含 shell 元字符的命令；其余照常走 AGY 权限流程。

---

## 四、套件目录结构

```text
multi-agent-delegation-kit/
├── README.md                          # 本说明（定位、安装、Profile、配置分层与双向演进）
├── install.sh                         # 一键幂等安装/升级脚本（支持 --profile / --with-hooks，保留用户配置）
├── scripts/
│   └── sync_from_local.py             # 本机核心 MD 与已装 Skill 反哺套件的差异巡检与脱敏同步工具
├── tests/                             # bash + Python 测试（bash tests/run_tests.sh）
├── docs/
│   └── architecture-and-benchmarks.md # 架构原理、强模型×弱Harness 互补分析与实测基准
├── rules/
│   ├── AGENTS-snippet.md              # 注入 ~/.gemini/AGENTS.md 的通用角色委派规则
│   └── CLAUDE-snippet.md              # 注入 ~/.claude/CLAUDE.md 的通用角色委派规则
└── skill/
    └── multi-agent-delegation/        # 可直接安装至 ~/.agents/skills/ 的标准 Skill 包
        ├── SKILL.md                   # 配置加载、5 角色路由表、降级链、多轮复用、5 步执行流与安全红线
        ├── hooks.json                 # AGY 守卫 Hook 模板（--with-hooks 合并进 ~/.gemini/config/hooks.json）
        ├── profiles/                  # 内置订阅组合（agy-cursor-zhipu / claude-deepseek-glm / agy-only）
        ├── templates/                 # 用户级 / 项目级 config.env 与 overrides.md 模板
        ├── references/
        │   └── delegation-best-practices.md  # 实测对照数据、真实项目用量画像、CLI 参数踩坑与五段式简报模板
        └── scripts/
            ├── guard_subagent.py      # AGY PreToolUse hook：inherit 子代理按策略改写/拦截（deny 连 self 子代理一起拦），规范委派命令可免弹窗
            ├── load_config.sh         # 分层配置解析、Profile 切换、本地核心 MD 发现与模板初始化
            └── run_delegate.sh        # 跨 Harness 委派脚本（预检、--role / --preset、多端点、多级回退、进度心跳、失败报告、--resume）
```

---

## 五、个人实战 ↔ 开源套件的双向演进闭环

本仓库同时面向**社区通用性**与**维护者自身日常提效**：

1. **套件迭代 → 反哺本机日常协作**：
   - 在仓库中优化角色策略、Harness 适配器或安全检查后，运行 `bash ./install.sh --skill-only`，本机所有多 Agent 协作任务立即升级，且 `~/.config/multi-agent-delegation/` 中的个人订阅配置原封不动保留。
2. **本机实战经验 → 脱敏反哺套件**：
   - 日常在 `~/.gemini/AGENTS.md`、`~/.claude/CLAUDE.md`、`~/.agents/skills/multi-agent-delegation/` 或 `~/docs/delegation-best-practices.md` 中沉淀新技巧后，运行同步巡检工具：
     ```bash
     # 巡检差异并自动标记个人路径与私密配额备注
     python3 ./scripts/sync_from_local.py --diff

     # 将已自动脱敏且无个人备注告警的条目回写到仓库
     python3 ./scripts/sync_from_local.py --apply --only skill,agents-rule
     ```
   - 个人专属内容（本机路径、某渠道临时缺额度等）留在 `~/.config/multi-agent-delegation/`，通用方法论进入仓库惠及所有用户。

---

## 六、给 Agent 的自动化安装步骤（供 AGY / Claude Code 读取执行）

当你（Agent）收到用户要求「按本 README 安装」时，请依次执行：
1. **环境探测**：运行 `which agy claude agent || true` 告知用户本机已就绪的 Harness，并根据用户订阅推荐对应 Profile（`agy-cursor-zhipu` / `claude-deepseek-glm` / `agy-only`）。
2. **预览安装**：运行 `bash "<kit_dir>/install.sh" --with-rules --with-hooks --profile <chosen> --dry-run"`（本机没有 AGY 时去掉 `--with-hooks`）。
3. **执行安装**：运行 `bash "<kit_dir>/install.sh" --with-rules --with-hooks --profile <chosen>"`（或 `--skill-only`）。
4. **安装验收**：
   - 运行 `bash ~/.agents/skills/multi-agent-delegation/scripts/load_config.sh --show`；
   - 运行 `bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh --role coder --resolve-only` 确认角色解析正确；
   - 引导用户按需微调 `~/.config/multi-agent-delegation/{config.env,overrides.md}`，提示开启新会话即可生效（AGY 的规则与 Hook 只对新开的会话生效）。
5. **改动套件后**：运行 `bash tests/run_tests.sh`，全部通过再安装。
