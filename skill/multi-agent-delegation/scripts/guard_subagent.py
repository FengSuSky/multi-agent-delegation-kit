#!/usr/bin/env python3
"""AGY PreToolUse hook: keep the primary model orchestrating and take friction out of delegation.

invoke_subagent
  A subagent that would run on the primary model (Model "inherit" or empty, the default) follows
  DELEGATE_INHERIT_SUBAGENT from the kit's layered config:
    rewrite  run it on a lighter native tier instead (DELEGATE_INHERIT_REWRITE_MODEL, default "flash")
    deny     block it and point the agent at run_delegate.sh --role coder
    allow    pass it through
  Under deny a worker (TypeName "self" or empty) is blocked on every tier, light ones included: a
  session that was told to pass Model="flash" does so for its coding tasks as well. Only the
  read-only "research" agent stays available natively, and only on a light tier.
  A prompt containing "[allow-inherit]" always passes through untouched.

run_command
  With DELEGATE_AUTO_ALLOW_DELEGATE=1, a canonical run_delegate.sh invocation whose paths stay
  inside the workspace is allowed outside the sandbox, so delegating never waits on a prompt.
  A canonical read-only load_config.sh query (--show / --json / --list-profiles, optionally
  --dir inside the workspace) gets the same treatment: the guard itself runs it for settings.

Anything unexpected answers "ask", which is AGY's own permission flow: a failing hook makes the tool
call fail, and this hook must never widen permissions by accident.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

SCRIPTS_DIR = Path(__file__).resolve().parent
LOADER = SCRIPTS_DIR / "load_config.sh"
DELEGATE_SCRIPT = SCRIPTS_DIR / "run_delegate.sh"
ESCAPE_HATCH = "[allow-inherit]"
NATIVE_TIERS = ("flash", "flash_lite")
# Agents that take a Model argument. The built-in specialists (browser, DeepCoder, ...) are left alone.
MODELLED_AGENTS = ("", "self", "research")
# Modelled agents that work on the workspace and can change it; "research" only reads.
WORKER_AGENTS = ("", "self")
VALUE_OPTIONS = {
    "--role", "--preset", "--dir", "--brief", "--out",
    "--effort", "--max-budget", "--timeout", "--resume", "--fallback", "--progress",
}
FLAG_OPTIONS = {"--keep-session", "--resolve-only"}
ROLE_VALUES = {
    "scout", "fast", "coder", "heavy", "architect",
    "hydrogen-low", "hydrogen", "glm", "glm-opus", "sonnet-agy", "sonnet-cursor", "opus-plan",
}
# Any of these lets a command line stop being "one script with plain arguments".
SHELL_SYNTAX = set(";&|<>`$(){}*?[]\\\"'\n\r\t")
# load_config.sh flags that only ever read; every other flag writes or initializes config.
LOADER_READ_ONLY_FLAGS = {"--show", "--json", "--list-profiles"}


def ask():
    return {"decision": "ask"}


def deny_reason():
    return (
        "已由 multi-agent-delegation 守卫拦截（DELEGATE_INHERIT_SUBAGENT=deny）：deny 策略下不让任何子代理跑在主模型上，"
        "也不让 self 子代理充当写码工人，以免消耗主订阅额度。\n"
        "请按任务类型改用对应通道：\n"
        "1) 检索/摘要/只读排查（scout）：仍用 invoke_subagent，但显式传 TypeName='research'，Model 用 'flash' 或 'flash_lite'。\n"
        "2) 编码实现、补测试、带测试闭环修 Bug（coder）：改走 multi-agent-delegation skill，"
        "用 `bash ~/.agents/skills/multi-agent-delegation/scripts/run_delegate.sh --role coder ...`，无需重新阅读 SKILL.md。"
        "数行以内的单点改动由主会话直接完成。\n"
        "3) 全量测试/构建等大输出：在主会话用 Shell 重定向落盘后只取末尾摘要，或写进 coder 简报的验收段。\n"
        "4) 仅当用户明确要求使用原生子代理或主模型时，在 Prompt 中加 `[allow-inherit]` 放行。\n"
        "切换本策略：修改 ~/.config/multi-agent-delegation/config.env 的 DELEGATE_INHERIT_SUBAGENT（rewrite | deny | allow）。"
    )


def load_settings(cwd):
    """The kit's layered config for this directory, or an empty dict when the loader cannot run."""
    try:
        result = subprocess.run(
            ["bash", str(LOADER), "--json", "--dir", cwd or "."],
            capture_output=True, text=True, timeout=3, check=True,
        )
        values = json.loads(result.stdout).get("values")
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        return {}
    return values if isinstance(values, dict) else {}


def decide_subagent(args, settings):
    type_name = str(args.get("TypeName") or "").strip().lower()
    model = str(args.get("Model") or "").strip().lower()
    if ESCAPE_HATCH in str(args.get("Prompt") or ""):
        return {"decision": "allow"}
    if type_name not in MODELLED_AGENTS:
        return {"decision": "allow"}

    policy = str(settings.get("DELEGATE_INHERIT_SUBAGENT") or "rewrite").strip().lower()
    if policy == "deny":
        # Keyed on the model alone this missed workers pointed at a light tier, so the agent
        # type counts as well: only a read-only researcher on a light tier stays native.
        if type_name in WORKER_AGENTS or model not in NATIVE_TIERS:
            return {"decision": "deny", "reason": deny_reason()}
        return {"decision": "allow"}
    if model not in ("", "inherit"):
        return {"decision": "allow"}
    if policy == "allow":
        return {"decision": "allow"}
    tier = str(settings.get("DELEGATE_INHERIT_REWRITE_MODEL") or "flash").strip().lower()
    if tier not in NATIVE_TIERS:
        tier = "flash"
    return {"decision": "allow", "overwrite": {"Model": tier}}


def resolved_path(text, base, home):
    """Absolute, symlink-resolved form of a path as the agent sees it, or None when it cannot be told.

    The hook runs in its own directory, so a relative path must be anchored on the agent's
    working directory explicitly instead of being resolved against the hook's.
    """
    if text.startswith("~"):
        text = str(home) + text[1:]
    candidate = Path(text)
    if not candidate.is_absolute():
        if not base or not Path(base).is_absolute():
            return None
        candidate = Path(base) / candidate
    return candidate.resolve()


def accepted_script_paths(script_path, home):
    paths = {str(script_path)}
    home_prefix = str(home) + os.sep
    if str(script_path).startswith(home_prefix):
        # AGY agents usually write the script path with a tilde.
        paths.add("~/" + script_path.relative_to(home).as_posix())
    return paths


def is_canonical_delegation(command, settings, cwd, workspace_paths, home, artifact_dir=None):
    """The command's options when it is exactly `bash <run_delegate.sh>` with known flags and
    in-workspace paths, otherwise None.

    A custom --test-cmd is not among the known flags on purpose: it is what grants the delegated
    Claude Code its shell permissions, so only the configured command may ever be used unattended.

    Briefs and output reports may also live under AGY's per-conversation artifact scratch dir, which
    keeps them out of `git status` and out of the permission prompt for writing outside the
    workspace. --dir stays restricted to the workspace: that is where the delegated agent writes.
    """
    if any(char in SHELL_SYNTAX for char in command):
        return None
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    if len(tokens) < 2 or tokens[0] not in ("bash", "/bin/bash"):
        return None
    if tokens[1] not in accepted_script_paths(DELEGATE_SCRIPT, home):
        return None

    options = {}
    index = 2
    while index < len(tokens):
        flag = tokens[index]
        if flag in FLAG_OPTIONS:
            options[flag] = True
            index += 1
        elif flag in VALUE_OPTIONS and index + 1 < len(tokens) and flag not in options:
            options[flag] = tokens[index + 1]
            index += 2
        else:
            return None

    dir_roots = workspace_roots(settings, cwd, workspace_paths, home)
    io_roots = dir_roots + artifact_scratch_roots(artifact_dir, home)

    def inside_roots(text, roots):
        candidate = resolved_path(text, cwd, home)
        return candidate is not None and any(candidate == root or root in candidate.parents for root in roots)

    # A progress query reads two files next to the output path and nothing else, so on its own it
    # needs no role; mixed with a delegation it stops being a form that can be told apart.
    if "--progress" in options:
        return options if set(options) == {"--progress"} and inside_roots(options["--progress"], io_roots) else None

    if ("--role" in options) == ("--preset" in options):
        return None
    if (options.get("--role") or options.get("--preset")) not in ROLE_VALUES:
        return None
    if "--dir" not in options:
        return None
    if not inside_roots(options["--dir"], dir_roots):
        return None
    for flag in ("--brief", "--out"):
        if flag in options and not inside_roots(options[flag], io_roots):
            return None
    return options


def artifact_scratch_roots(artifact_dir, home):
    """AGY's scratch dir for this conversation, where briefs and reports can be written without a
    workspace escape. Empty when the payload carries no usable artifact directory."""
    if not artifact_dir:
        return []
    resolved = resolved_path(artifact_dir, None, home)
    if resolved is None:
        return []
    return [(resolved / "scratch").resolve()]


def workspace_roots(settings, cwd, workspace_paths, home):
    roots = []
    for path in list(workspace_paths) + [cwd]:
        resolved = resolved_path(path, None, home)
        if resolved is not None:
            roots.append(resolved)
    scratch = str(settings.get("DELEGATE_SCRATCH_DIR") or "").strip()
    if scratch:
        resolved = resolved_path(scratch, cwd, home)
        if resolved is not None:
            roots.append(resolved)
    return roots


def is_canonical_config_read(command, settings, cwd, workspace_paths, home):
    """The command's action flags when it is exactly `bash <load_config.sh>` asking only for
    read-only output (--show / --json / --list-profiles, at least one, no repeats) with an
    optional non-repeated --dir inside the workspace or scratch dir, otherwise None."""
    if any(char in SHELL_SYNTAX for char in command):
        return None
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    if len(tokens) < 2 or tokens[0] not in ("bash", "/bin/bash"):
        return None
    if tokens[1] not in accepted_script_paths(LOADER, home):
        return None

    actions = set()
    workdir = None
    index = 2
    while index < len(tokens):
        flag = tokens[index]
        if flag in LOADER_READ_ONLY_FLAGS and flag not in actions:
            actions.add(flag)
            index += 1
        elif flag == "--dir" and workdir is None and index + 1 < len(tokens):
            workdir = tokens[index + 1]
            index += 2
        else:
            return None
    if not actions:
        return None
    if workdir is not None:
        roots = workspace_roots(settings, cwd, workspace_paths, home)
        candidate = resolved_path(workdir, cwd, home)
        if candidate is None or not any(candidate == root or root in candidate.parents for root in roots):
            return None
    return actions


def decide(payload):
    call = payload.get("toolCall")
    if not isinstance(call, dict):
        return ask()
    args = call.get("args")
    if not isinstance(args, dict):
        return ask()
    if call.get("name") == "invoke_subagent":
        return decide_subagent(args, load_settings(payload.get("cwd")))
    command = str(args.get("CommandLine") or "")
    if call.get("name") == "run_command" and ("run_delegate.sh" in command or "load_config.sh" in command):
        settings = load_settings(payload.get("cwd"))
        workspace_paths = payload.get("workspacePaths")
        if not isinstance(workspace_paths, list):
            workspace_paths = []
        enabled = str(settings.get("DELEGATE_AUTO_ALLOW_DELEGATE") or "").strip() == "1"
        if enabled:
            cwd = payload.get("cwd")
            home = Path.home()
            if "run_delegate.sh" in command:
                options = is_canonical_delegation(
                    command, settings, cwd, workspace_paths, home,
                    artifact_dir=payload.get("artifactDirectoryPath"),
                )
                if options:
                    return {"decision": "allow", "overwrite": {"BypassSandbox": True}}
            elif is_canonical_config_read(command, settings, cwd, workspace_paths, home):
                return {"decision": "allow", "overwrite": {"BypassSandbox": True}}
    return ask()


def main():
    try:
        payload = json.load(sys.stdin)
        decision = decide(payload) if isinstance(payload, dict) else ask()
    except Exception:
        decision = ask()
    print(json.dumps(decision, ensure_ascii=False))


if __name__ == "__main__":
    main()
