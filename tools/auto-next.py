"""Continue one explicit CLI task until it reports done, blocked, or a limit."""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

CONFIG = Path(__file__).resolve().parent.parent / "workflows" / "workflow.toml"
STATUS = re.compile(r"AUTO_NEXT_STATUS: (CONTINUE|DONE|BLOCKED)")
SESSION = re.compile(r"[A-Za-z0-9_-]+")
# Windows needs the extension: PATH holds extensionless node shims that cannot
# be launched directly, and the npm shims come before the desktop Codex copy
# (0.162.x, broken Windows sandbox helper).
LAUNCHERS = {
    "codex": ("codex.cmd", "codex.exe", "codex"),
    "opencode": ("opencode.exe", "opencode.cmd", "opencode"),
    "commandcode": ("commandcode.cmd", "commandcode.exe", "commandcode"),
}
CONTRACT = (
    "\n\nStay on this task only. Continue autonomously while safe and useful. "
    "Stop when the task is done, blocked by a decision or approval, or cannot safely proceed. "
    "End your final reply with exactly one line: "
    "AUTO_NEXT_STATUS: CONTINUE, AUTO_NEXT_STATUS: DONE, or AUTO_NEXT_STATUS: BLOCKED. "
    "Use CONTINUE only when this same task has a concrete next step."
)
FOLLOW_UP = "Continue the same task from this session. Do not start another task." + CONTRACT


def max_turns(config=CONFIG):
    with config.open("rb") as source:
        value = tomllib.load(source)["continuation"]["max_turns"]
    if type(value) is not int or value < 1:
        raise ValueError("continuation.max_turns must be a positive integer")
    return value


def parse_run(backend, output):
    """Return (session ID, final reply) only for a complete successful turn."""
    session = None
    final = None
    complete = False
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if backend == "codex":
            if kind == "thread.started":
                session = event.get("thread_id")
            elif kind == "item.completed":
                item = event.get("item")
                if isinstance(item, dict) and item.get("type") == "agent_message":
                    final = item.get("text")
            elif kind == "turn.completed":
                complete = True
            elif kind in ("turn.failed", "error"):
                return None, None
        elif backend == "opencode":
            event_session = event.get("sessionID")
            if event_session:
                if session and session != event_session:
                    return None, None
                session = event_session
            if kind == "text":
                part = event.get("part")
                if (isinstance(part, dict) and part.get("type") == "text"
                        and isinstance(part.get("text"), str) and part["text"]):
                    final = part["text"]
            elif kind == "step_finish":
                part = event.get("part")
                complete = isinstance(part, dict) and part.get("reason") == "stop"
            elif kind == "error":
                return None, None
        elif backend == "commandcode" and kind == "result":
            if event.get("subtype") != "success" or event.get("stopReason") != "end_turn":
                return None, None
            session = event.get("sessionId")
            final = event.get("finalText")
            complete = True
    if complete and isinstance(session, str) and SESSION.fullmatch(session) and isinstance(final, str):
        return session, final
    return None, None


def failure_reason(output):
    """Return the CLI's own error text from a JSON event stream."""
    reason = None
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if kind not in ("error", "turn.failed", "result"):
            continue
        if kind == "result" and event.get("subtype") == "success" and event.get("stopReason") == "end_turn":
            continue
        found = None
        for key in ("message", "error"):
            value = event.get(key)
            if isinstance(value, str) and value:
                found = value
                break
            if isinstance(value, dict):
                inner = value.get("message")
                if isinstance(inner, str) and inner:
                    found = inner
                    break
        if found is None and kind == "result":
            found = "result " + " ".join(
                f"{key}={event[key]}" for key in ("subtype", "stopReason") if event.get(key))
        if found:
            reason = found
    return reason


def launcher(backend):
    """Return the CLI to run, resolved against PATH."""
    for name in LAUNCHERS[backend]:
        found = shutil.which(name)
        if found:
            return found
    return LAUNCHERS[backend][-1]


def command(backend, session):
    if backend == "codex":
        if session:
            return [launcher(backend), "exec", "resume", "--json", session, "-"]
        return [launcher(backend), "exec", "--json", "-"]
    if backend == "opencode":
        args = [launcher(backend), "run", "--format", "json"]
        if session:
            args.extend(["--session", session])
        return args
    args = [launcher(backend), "-p", "--output-format", "json"]
    if session:
        args.extend(["--session", session])
    return args


def run(backend, task, workdir, limit):
    session = None
    for turn in range(1, limit + 1):
        prompt = task + CONTRACT if turn == 1 else FOLLOW_UP
        args = command(backend, session)
        try:
            result = subprocess.run(
                args, input=prompt,
                text=True, encoding="utf-8", errors="replace", capture_output=True,
                cwd=workdir, check=False,
            )
        except OSError as exc:
            print(f"Turn {turn}: CLI launch failed: {exc}", file=sys.stderr)
            return 1
        if result.returncode:
            reason = failure_reason(result.stdout) or result.stderr.strip()
            print(f"Turn {turn}: CLI exited {result.returncode}: {reason}", file=sys.stderr)
            return 1
        new_session, reply = parse_run(backend, result.stdout)
        if not new_session or (session and new_session != session):
            reason = failure_reason(result.stdout)
            detail = f": {reason}" if reason else ""
            print(f"Turn {turn}: missing or changed session/completion data{detail}; stopped", file=sys.stderr)
            return 1
        session = new_session
        print(f"Turn {turn}: {reply}")
        lines = reply.strip().splitlines()
        marker = STATUS.fullmatch(lines[-1].strip()) if lines else None
        if not marker:
            print("Missing exact AUTO_NEXT_STATUS line; stopped", file=sys.stderr)
            return 1
        state = marker.group(1)
        if state != "CONTINUE":
            return 0 if state == "DONE" else 2
    print(f"Reached max_turns={limit}; stopped with task still open", file=sys.stderr)
    return 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=("codex", "opencode", "commandcode"), required=True)
    parser.add_argument("--workdir", type=Path, required=True)
    parser.add_argument("task", help="One explicit task; no ticket discovery")
    args = parser.parse_args()
    if not args.workdir.is_dir():
        parser.error("--workdir must be an existing directory")
    try:
        limit = max_turns()
    except (OSError, KeyError, ValueError, tomllib.TOMLDecodeError) as exc:
        parser.error(f"invalid workflow configuration: {exc}")
    return run(args.backend, args.task, args.workdir.resolve(), limit)


if __name__ == "__main__":
    sys.exit(main())
