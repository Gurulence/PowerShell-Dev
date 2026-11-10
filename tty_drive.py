#!/usr/bin/env python3
"""Drive the agent through a real TTY, answering the approval prompt with keystrokes."""
import os, pty, sys, time, select

def run(answers, timeout=90):
    argv = ["/home/user/.local/pwsh/pwsh", "-NoLogo", "-NoProfile", "-File",
            "/home/user/psagent/Agent.ps1", "-NoColor",
            "-ConfigPath", "/tmp/testcfg.json", "interactive test"]
    env = dict(os.environ, MOCK_KEY="x",
               MOCK_SCRIPT="/home/user/psagent/tests/script_tty.json")
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
    out = b""
    sent = 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.4)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if b"?" in chunk and sent < len(answers):
                time.sleep(0.15)
                os.write(fd, answers[sent].encode())
                sent += 1
        else:
            # child gone?
            try:
                wpid, status = os.waitpid(pid, os.WNOHANG)
                if wpid: break
            except ChildProcessError:
                break
    try: os.waitpid(pid, 0)
    except Exception: pass
    return out.decode(errors="replace")

if __name__ == "__main__":
    # y = approve write, n = deny edit, f + text = feedback, q = quit is not reached
    res = run(["y", "n", "f", "please use a record instead\r"])
    print(res)
