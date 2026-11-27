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

> 原生子代理的 `flash_lite`（gemini-3.5-flash-lite）是 AGY 里最便宜的一档，尚未纳入本基准。

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
- **`--output-format json` 只在结束时输出**：运行几十分钟的编码任务，输出文件一直是 0 字节。脚本改用 `--output-format stream-json --verbose`（`-p` 下必须带 `--verbose`，否则直接报错退出）把事件流写到 `<out>.events.jsonl`，运行期间打印进度心跳，结束后再从事件流里取出 `result` 写入输出文件。
- **从 AGY 会话里调用会继承代理**：AGY 的包装函数把 `HTTP(S)_PROXY` 指向自己的隧道，`claude` 子进程原样继承；隧道一断，claude 会对着一个没人监听的本机端口重试几分钟才报 `ECONNREFUSED`。脚本现在先探测端点，代理不通就自动改直连。

### AGY (`agy`)
- `-p` 必须放最后；cwd 必须在 `$HOME` 下（`/tmp` 写文件被拒）；加 `--print-timeout 300s`。
- 支持 `--json-schema` 强约束结构化输出、`--mode plan` 只读评审、`--resume <conversation_id>` 多轮复用。
- 读取 `AGENTS.md` 和 `GEMINI.md`。
- **headless（`-p`）下没人能审批权限**：模型一旦调用需要授权的工具就被自动拒绝，输出一句 `no output produced` 却**以退出码 0 结束**。只读评审的简报要写明「不要调用任何工具」（脚本对 plan 模式自动加这句）。
- **不要在 AGY 会话里再嵌套 `agy -p`**：要先过沙箱（工作区外的脚本会 `Operation not permitted`）、OAuth 资格检查和模型校验，任何一步受网络影响都会拖上几十秒。要 Hydrogen 直接用原生 `invoke_subagent(TypeName="self", Model="flash")`，但只接 `fast` 级小活（见第 6 节）；守卫为 `deny` 时这类调用会被拦截，写码任务走 `coder`。
- **`~/.gemini/config/skills.json` 里的目录必须写绝对路径**：写成 `~/.agents/skills` 时 AGY 每次重载 skill 都报 `must be an absolute path`，`multi-agent-delegation` 不会被当成 skill 加载，主会话只能靠规则里的路径手动去读 SKILL.md。
- **原生子代理的 `Model` 只有四个别名**：`inherit`（主会话当前模型）、`flash_lite`（gemini-3.5-flash-lite）、`flash`（Hydrogen 高思考档）、`pro`（Hydrogen 更高思考档）。
- **权限规则是 `command(<前缀>)`**：每次点「始终允许」存下的是整条命令，简报路径一变就要重新确认；用前缀规则或守卫 Hook（见第 6 节）才能一次解决。

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

## 4. 主会话验收清单（不信自报，自己验，且不膨胀）

1. `git diff --stat` / `diff -ru` 确认只改了允许文件、测试未改、无多余文件（`*.snap` / `*snapshots*.json` / `package-lock.json` 等大文件不裸跑 `git diff`，交由 `scout` 或 `coder` 摘要）；
2. 短输出单点校验可轻跑；**全量测试、评测跑批与构建验收走 `coder` 通道并回传 5–10 行摘要**（禁止派只读无网 `research` 跑需本地端口或家目录配置的测试，也禁止主会话裸跑）；
3. 逐行读关键 diff 防硬编码、特判或弱化校验；
4. 检查输出 JSON 的 `is_error`、`permission_denials` 或回复文本中有无“被拒/未能运行”；输出是 `status: "failed"` 的失败报告时，先看 `attempts[].reason` 再决定下一步；
5. 核对耗时与 `usage`；通过后合入主分支并清理 worktree / scratch（常规 Git 整理与收尾也可交由 `coder` 执行）。

---

## 5. 用量画像：一次真实项目的复盘

下面是对**一个约 2,900 个单测的 Node.js 仓库、单日**的 agy 会话做只读解码后得到的结果（会话库在 `~/.gemini/antigravity-cli/`，SQLite 加 protobuf）。它是 SKILL.md 里几条路由规则的依据，数字只代表那一天。

**模型用量**

| 模型 | 生成次数 | 输入（未命中缓存部分） | 输出 | 其中思考 |
| :--- | :--- | :--- | :--- | :--- |
| Neon | 308 | 168 万 | 31.7 万 | 12.4 万 |
| Hydrogen 高思考档（原生 `flash` 子代理） | 316 | 272 万 | 34.0 万 | 23.5 万（69%） |
| Opus（`opus-plan`） | 2 | 2.7 万 | 0.9 万 | — |
| Claude Code + GLM（经脚本委派） | 0 次成功 | — | — | — |

**Neon 的去向**

| 去向 | 生成次数 | 输入 | 输出 |
| :--- | :--- | :--- | :--- |
| 主会话亲自实现（37 次读文件、29 次编辑、21 条命令） | 53 | 19.1 万 | 4.5 万 |
| 3 个 `Model: inherit` 的实现子代理 | 73 | 44.8 万 | 12.4 万 |
| 主会话的规划、编排、验收 | 106 | 60.3 万 | 10.5 万 |
| 另两个独立会话（清理 worktree、查配置位置） | 76 | 43.6 万 | 4.8 万 |

约 41% 的 Neon 生成、53% 的输出花在「亲自干活」上。装上守卫 Hook 之前，这些调用只被文字规则约束；当天下午换成 `deny` 策略的 Hook 后，`inherit` 调用当场被拦下，主会话随即改走 coder 通道。

**由此得到的几条事实**

- **上下文是被「自己读文件」撑爆的。** 主会话的工具结果共 64 万字符，其中 `read_file` 占 75%（58 次、48 万字符），`run_command` 占 14%；15 条子代理回执合计只有 5.3 万字符。上下文峰值 31.5 万 token，期间 3 次缓存整包重读共 18.5 万 token，占主会话 Neon 输入的 23%。
- **Neon 与 Hydrogen 共用同一份 AGY 配额。** 同一批 429 里，Hydrogen 与 Neon 会话的重置时刻完全一致；Claude 系列的 429 重置在另一个时刻。所以把活交给 `flash` 省的是 Neon 的份额，不是 AGY 总量。
- **`flash` 是高思考档。** 它 69% 的输出是思考 token；调研类子代理当天读掉了 204 万输入，是最大的 token 出口。
- **简报质量决定廉价模型能不能接住。** 3 个带 TDD 简报（列明根因、文件行号、「严禁修改既有测试断言」）的 `flash` 实现子代理，主会话首次独立跑全量测试就全绿；而 `inherit` 的两个实现子代理在实机验证时失败，补修了 2 轮。样本很小，只能当信号。

**通道失败记录（同一天）**

- `opus-plan` 试了 4 次才成功：沙箱拒绝执行工作区外脚本（exit 126）→ OAuth 资格检查网络 EOF → headless 下工具被自动拒绝但退出码为 0 → 在简报里写明「不要调用任何工具」后通过。
- `coder` 唯一一次调用失败：本机隧道断开导致 `ECONNREFUSED`，空等 195 秒；回退到嵌套 `agy` 时模型校验又失败。18 分钟后才改用原生 `flash` 子代理完成。

**通道没坏却被误杀（次日）**

- `coder` 被派出去约 6 分钟后遭主会话 `manage_task kill`（12:38:15 启动，12:44:16 被杀），当时任务还是 `RUNNING`，也没有失败报告。它的依据是输出文件 0 字节、`git status` 没变化；stderr 其实只有 Claude Code 的两行启动告警（276 字节），主会话没有读就下了「连接被拒」的结论。隧道进程从 11:57 起一直没有重启；Claude Code 在 12:40:04 派出了 Explore 子代理、12:40:12 执行了第一条 Bash 命令，被杀时还没开始编辑文件。主会话等待用的 `NotificationTimeoutSeconds` 是 300。

前两段记录对应脚本的四个行为：预检、代理自动回退直连、多级回退链、结构化失败报告；最后一段对应进度心跳：运行期间每 30 秒向 stderr 报一行已用时、工具调用次数和最近一次调用，`run_delegate.sh --progress <out.json>` 随时可查，不依赖调用方怎样处理 stderr。

> 配额按什么计权（token、请求数还是按模型打折）本地数据看不出来，用 agy 的 `/quota` 核对。

**实战复盘：Read vs Act 边界与防膨胀（`voice-agent-harness`）**

1. **角色边界错位**：原规则把「全量测试监控」划给 `scout`（原生 `research` 只读无网子代理）。实战中需要绑定本地回环端口或读取 `~/.config` 的 `npm test` 一进 `research` 沙盒就报 `fetch failed` / `EPERM` 甚至悬挂句柄，逼主会话退回 `BypassSandbox: true` 裸跑 5 次 `npm test`，每次塞入约 580 KB 日志预览。→ **解法**：`scout` 收窄为纯只读分析（代码地图、日志/报告定位、大快照摘要），全量测试与评测跑批统一划归 `coder`。
2. **规则 2.3 与 2.4 冲突**：一条要求主会话长输出落盘截断，另一条禁止沙盒外命令拼 `> /tmp/... && tail`。→ **解法**：全量测试不进主会话，彻底走 `coder` 通道只回 5–10 行摘要，从根源消除规则冲突。
3. **机械性 Act 操作消耗主会话额度**：全量验收、评测跑批、精准 `git add` / 拆 commit 等纯执行任务在主会话消耗高配额与轮次。→ **解法**：在项目 `.agents/delegation/config.env` 声明 `DELEGATE_DEFAULT_TEST_CMD`（测试 + 安全本地 Git 子命令白名单），把全量跑测与常规 Git 收尾统一下沉给 `coder`，并用安全红线锁死 `git push`、`--force`、`git reset --hard` 与 `git add -A/.`。
4. **代读源码与大快照裸 diff 撑爆上下文**：写 `coder` 简报前习惯性逐个 `read_file` 参考文件再抄进简报，且对 `*snapshots*.json` 直接跑 `git diff` 灌入上百 KB 截断输出。→ **解法**：简报不抄源码（最多派一次 `scout` 返回 ≤30 行文件:行号地图），大快照文件禁止主会话裸 `git diff`。

---

## 6. 守卫 Hook 语义（实测，agy 1.5.17）

`guard_subagent.py` 是 AGY 的 PreToolUse hook，从 stdin 读 JSON、往 stdout 写一个决策。下表是 headless 模式下实测到的效果：

| Hook 响应 | 实际效果 |
| :--- | :--- |
| `{"decision": "allow", "overwrite": {"Model": "flash"}}` | 参数在执行前被改写，子代理实际跑在 `flash` 上；返回里带一句「参数被 hook 改写」的提示 |
| `{"decision": "allow", "overwrite": {"BypassSandbox": true}}` | 工作区外的脚本零弹窗执行，并绕过沙箱 |
| `{"decision": "ask"}` | 回到 AGY 默认权限流程 |
| `{}`（空对象） | **等同于拒绝** |
| Hook 自身崩溃或超时 | 工具调用直接报错（fail-closed） |

所以这个 Hook 的「不干预」一律回答 `ask`，任何内部异常也回答 `ask`：既不会因为崩溃放行，也不会因为崩溃把所有命令拦掉。

**三种策略对 `invoke_subagent` 的判定**

| `TypeName` | `Model` | `rewrite`（默认） | `deny` | `allow` |
| :--- | :--- | :--- | :--- | :--- |
| `self` / 空 | `inherit` / 空 | 改写为 `flash` | 拦截 | 放行 |
| `self` / 空 | `flash` / `flash_lite` | 放行 | **拦截** | 放行 |
| `self` / 空 | `pro` | 放行 | 拦截 | 放行 |
| `research` | `inherit` / 空 | 改写为 `flash` | 拦截 | 放行 |
| `research` | `flash` / `flash_lite` | 放行 | 放行 | 放行 |
| `research` | `pro` | 放行 | 拦截 | 放行 |
| 内置专家（browser、DeepCoder…） | 任意 | 不干预 | 不干预 | 不干预 |

`deny` 之所以连 `self` 类型一起拦，是一次复盘的结果（2026-11-26）：守卫从硬拦截改成 `rewrite` 之后，同一个长会话里 4 个多文件编码任务全部以 `Model="flash"`、`TypeName="self"` 派给了原生子代理，`run_delegate.sh` 一次没调。只看 `Model` 的守卫对这种调用无能为力；而两天 24 次调用里，`self` 类型全是写任务、`research` 全是只读排查，按类型判别没有误伤。同一份轨迹里还有第二条教训：`coder` 因隧道断开失败过一次之后，主会话在后续任务里一直绕开它。通道恢复后要明确告诉主会话，或者新开会话。

Hook 的工作目录是 `hooks.json` 所在目录，不是 agent 的 cwd；hook 命令里引用同目录文件要写相对该目录的路径（项目级 `.agents/hooks.json` 里是 `python3 guard.py`，不是 `python3 .agents/guard.py`）。
