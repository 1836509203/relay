# 录制真实 Claude Code 的 PTY 字节流：保留每个 read() 块的真实边界与时间戳。
# 会话流程：启动 → 发提示词产多屏输出 → 注入 Relay 同款 SGR 滚轮上报（wheel-up 回看）→ 退出。
import os, pty, sys, time, json, base64, signal, struct, fcntl, termios, select, re

COLS, ROWS = 105, 38
OUT = sys.argv[1] if len(sys.argv) > 1 else "recording.jsonl"
PROMPT = "请输出 1 到 120 的数字，每行一个，不要任何解释和多余文字"

pid, fd = pty.fork()
if pid == 0:
    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = str(COLS)
    env["LINES"] = str(ROWS)
    # 不继承本会话的嵌套标记
    for k in list(env):
        if k.startswith("CLAUDE") or k == "CLAUDECODE":
            env.pop(k, None)
    os.chdir("/Users/zhanghao/Project/iterm")
    os.execvpe("claude", ["claude"], env)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
log = open(OUT, "w")
t0 = time.time()

def rec(kind, data=b"", note=""):
    log.write(json.dumps({"t": round(time.time() - t0, 4), "kind": kind,
                          "data": base64.b64encode(data).decode(), "note": note}) + "\n")
    log.flush()

CPR = re.compile(rb"\x1b\[6n")
DA1 = re.compile(rb"\x1b\[0?c")

def answer_queries(chunk):
    # CC/Ink 启动会查询光标位置(CPR)与设备属性(DA1)，不回会卡等超时。
    for _ in CPR.finditer(chunk):
        resp = b"\x1b[%d;1R" % ROWS
        rec("in", resp, "cpr-reply")
        os.write(fd, resp)
    for _ in DA1.finditer(chunk):
        resp = b"\x1b[?62c"
        rec("in", resp, "da1-reply")
        os.write(fd, resp)

def drain(seconds, quiet_exit=0.0):
    # 读满 seconds 秒；quiet_exit>0 时静默该时长即提前返回。
    end = time.time() + seconds
    last = time.time()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                return False
            if not chunk:
                return False
            rec("out", chunk)
            answer_queries(chunk)
            last = time.time()
        elif quiet_exit and (time.time() - last) > quiet_exit:
            return True
    return True

def send(b, note=""):
    rec("in", b, note)
    os.write(fd, b)

print("启动 claude…", flush=True)
drain(15, quiet_exit=4)
send(PROMPT.encode(), "prompt")
drain(1.5)
send(b"\r", "enter")
print("等待流式输出…", flush=True)
drain(90, quiet_exit=6)

print("注入 wheel-up（Relay 转发同款 SGR button4）…", flush=True)
for i in range(40):
    send(b"\x1b[<64;40;10M", "wheel-up-%d" % i)
    drain(0.15)
drain(2, quiet_exit=1)

print("注入 wheel-down…", flush=True)
for i in range(25):
    send(b"\x1b[<65;40;10M", "wheel-down-%d" % i)
    drain(0.15)
drain(2, quiet_exit=1)

send(b"\x03", "ctrl-c")
drain(1)
send(b"\x03", "ctrl-c")
drain(1)
try:
    os.kill(pid, signal.SIGKILL)
except ProcessLookupError:
    pass
rec("end")
print("录制完成: %s" % OUT, flush=True)
