#!/data/data/com.novainc.agt/files/usr/bin/python3
# session_run.py: runs INSIDE one agent's xfce-<agent> deployment.
#
# Starts that agent's private desktop stack in its own space:
#   Xvfb (virtual display) -> x11vnc (-viewonly, loopback only)
#   -> websockify (loopback only) -> xfce4-session (own HOME)
# Mints the one-time token, writes the session record the gate
# reads, and on exit (deployment stop / close) tears everything
# down and deletes the record, which kills the link.
#
# If the add-on holds a close marker for this agent (agt-xfce
# close), the stack is NOT started: the process idles so the
# deployment supervisor does not spin it, holding no session.
import atexit
import json
import os
import signal
import subprocess
import sys
import time

ADDON = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ADDON, "bin"))
import importlib.util
from importlib.machinery import SourceFileLoader
# agt-xfce has no .py extension, so spec_from_file_location leaves
# the loader None and module_from_spec dies; pass the loader
# explicitly (found live 2026-11-20 in the first session deploy).
_loader = SourceFileLoader("agt_xfce", os.path.join(ADDON, "bin", "agt-xfce"))
spec = importlib.util.spec_from_loader("agt_xfce", _loader)
agt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agt)

CHILDREN = []
SESSION_FILES = []


def spawn(argv, env, log):
    f = open(log, "ab")
    p = subprocess.Popen(argv, env=env, stdout=f, stderr=subprocess.STDOUT,
                         start_new_session=True)
    CHILDREN.append(p)
    return p


def teardown():
    for p in reversed(CHILDREN):
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except Exception:
            pass
    time.sleep(1)
    for p in reversed(CHILDREN):
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            pass
    for path in SESSION_FILES:
        try:
            os.remove(path)
        except Exception:
            pass


def cleanup(signum=None, frame=None):
    teardown()
    sys.exit(0)


def wait_for(predicate, seconds, what):
    end = time.time() + seconds
    while time.time() < end:
        if predicate():
            return True
        time.sleep(0.25)
    raise SystemExit("agt-xfce session: timed out waiting for " + what)


def clear_stale_display(var_dir, display):
    # A run killed without cleanup (the supervisor SIGKILLs on
    # stop) can leave an orphaned Xvfb holding this display plus
    # its lock and socket; a fresh Xvfb then refuses to start
    # ("Server is already active"). Found live 2026-11-20: x11vnc
    # died at startup, the run exited without teardown, and Xvfb
    # stayed behind. The session record is gone by then, so
    # nothing live can be using the display: kill the orphan and
    # clear the lock and socket.
    lock = os.path.join(var_dir, ".X%d-lock" % display)
    sock = os.path.join(var_dir, ".X11-unix", "X%d" % display)
    try:
        with open(lock) as f:
            pid = int(f.read().strip())
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            cmd = f.read().replace(b"\x00", b" ").decode("utf-8", "replace")
        if "Xvfb" in cmd:
            os.kill(pid, signal.SIGTERM)
            for _ in range(20):
                if not os.path.exists("/proc/%d" % pid):
                    break
                time.sleep(0.25)
            try:
                os.kill(pid, signal.SIGKILL)
            except Exception:
                pass
    except Exception:
        pass
    for path in (lock, sock):
        try:
            os.remove(path)
        except Exception:
            pass


def port_open(port):
    import socket
    s = socket.socket()
    s.settimeout(0.5)
    try:
        s.connect(("127.0.0.1", port))
        s.close()
        return True
    except Exception:
        return False


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: session_run.py <agent>")
    agent = sys.argv[1]
    agt.check_agent(agent)
    agt.ensure_dirs()
    space = agt.space_for(agent)
    slot, display, vnc_port, ws_port = agt.ports_for(agent)
    logs = os.path.join(space, "logs")
    os.makedirs(logs, exist_ok=True)
    # The X stack's socket and lock dirs live in the add-on's var
    # dir (Android has no /tmp); empty dirs do not survive add-on
    # packaging, so create them at session start.
    var_dir = os.path.join(ADDON, "var")
    # "run" is load-bearing too: the session dbus-daemon binds its
    # socket under var/run and dies if it is missing, which leaves
    # xfce4-session without a bus and the session tears down
    # (found live 2026-11-20 in xfce4-session.log).
    for d in (os.path.join(var_dir, ".X11-unix"),
              os.path.join(var_dir, ".ICE-unix"),
              os.path.join(var_dir, "run")):
        os.makedirs(d, exist_ok=True)

    marker = os.path.join(agt.CLOSED, agent)
    if os.path.exists(marker):
        print("agt-xfce session: closed by request; idling with no desktop", flush=True)
        while os.path.exists(marker):
            time.sleep(5)
        # Marker removed by a fresh `agt-xfce start`: fall through
        # and bring the desktop up in this same process.

    token = agt.new_token()
    prefix_bin = os.path.join(ADDON, "bin")
    env = dict(os.environ)
    env.update({
        "HOME": space,
        "DISPLAY": ":%d" % display,
        "XDG_CONFIG_HOME": os.path.join(space, ".config"),
        "XDG_CACHE_HOME": os.path.join(space, ".cache"),
        "XDG_DATA_HOME": os.path.join(space, ".local", "share"),
        # XDG_DATA_DIRS and XDG_CONFIG_DIRS are load-bearing
        # (0.1.13): without them the session never sees the add-on's
        # own share/ and etc/xdg trees. GTK found no icon theme at
        # all (not even hicolor), fontconfig's <dir prefix="xdg">
        # fonts entry resolved nowhere so every label rendered as
        # empty boxes despite DejaVu shipping in the package, and
        # the packaged xfconf defaults never applied. Found live
        # 2026-11-20 from the owner's own look at the desktop plus
        # the browser proof screenshots.
        "XDG_DATA_DIRS": os.path.join(ADDON, "share") + ":/usr/local/share:/usr/share",
        "XDG_CONFIG_DIRS": os.path.join(ADDON, "etc", "xdg"),
        "AGT_XFCE_AGENT": agent,
        "PATH": prefix_bin + ":" + env.get("PATH", ""),
    })

    clear_stale_display(var_dir, display)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    # Any other exit (a startup wait timing out, an exception)
    # must still tear the stack down; atexit covers those paths.
    atexit.register(teardown)

    # -extension MIT-SHM is load-bearing (0.1.12): xfwm4 calls shmget
    # during core startup and Android's app seccomp filter kills the
    # process with SIGSYS (proven live 2026-11-20 with a ptrace
    # tracer: last syscall 194 = shmget). Disabling the extension on
    # the server stops every client from ever making that call, since
    # clients only use MIT-SHM when the server advertises it. Same
    # family as x11vnc -noshm (0.1.8), but fixed once at the source
    # instead of one client at a time.
    xvfb = spawn(["Xvfb", ":%d" % display, "-screen", "0", "1280x800x24",
                  "-nolisten", "tcp", "-extension", "MIT-SHM"],
                 env, os.path.join(logs, "xvfb.log"))
    wait_for(lambda: os.path.exists(os.path.join(
                 ADDON, "var", ".X11-unix", "X%d" % display))
             or xvfb.poll() is not None, 15, "Xvfb")
    if xvfb.poll() is not None:
        raise SystemExit("agt-xfce session: Xvfb exited; see logs/xvfb.log")

    # Per-agent session dbus (XFCE session components expect one).
    dbus = subprocess.run(["dbus-launch", "--sh-syntax"], env=env,
                          capture_output=True, text=True)
    for line in dbus.stdout.splitlines():
        if line.startswith("DBUS_SESSION_BUS_ADDRESS="):
            env["DBUS_SESSION_BUS_ADDRESS"] = line.split("=", 1)[1].strip().strip(";").strip("'")
        if line.startswith("DBUS_SESSION_BUS_PID="):
            try:
                CHILDREN.append(subprocess.Popen(["true"]))  # placeholder keep list ordered
                CHILDREN.pop()
                dbus_pid = int(line.split("=", 1)[1].strip().strip(";"))
                env["DBUS_SESSION_BUS_PID"] = str(dbus_pid)
            except Exception:
                pass

    # -noshm is load-bearing: x11vnc's default MIT-SHM path calls
    # shmget, and Android's app seccomp filter kills the process
    # with SIGSYS (proven live 2026-11-20: died in 2s, rc -31;
    # with -noshm the port opened in 2s). XGetImage fallback is
    # fine for a view-only stream.
    vnc = spawn(["x11vnc", "-display", ":%d" % display,
                 "-rfbport", str(vnc_port), "-localhost", "-viewonly",
                 "-forever", "-shared", "-nopw", "-quiet", "-noshm"],
                env, os.path.join(logs, "x11vnc.log"))
    wait_for(lambda: port_open(vnc_port), 20, "x11vnc")

    web = os.path.join(ADDON, "share", "xview", "web")
    ws = spawn(["websockify", "--web", web,
                "127.0.0.1:%d" % ws_port, "127.0.0.1:%d" % vnc_port],
               env, os.path.join(logs, "websockify.log"))
    wait_for(lambda: port_open(ws_port), 20, "websockify")

    session = spawn(["xfce4-session"], env, os.path.join(logs, "xfce4-session.log"))

    rec = {
        "agent": agent,
        "display": display,
        "vncPort": vnc_port,
        "wsPort": ws_port,
        "pid": os.getpid(),
        "startedAt": int(time.time()),
    }
    rec_path = os.path.join(agt.SESSIONS, token + ".json")
    link_path = os.path.join(agt.BY_AGENT, agent + ".json")
    agt.save_json(rec_path, rec)
    agt.save_json(link_path, {"token": token})
    SESSION_FILES.extend([rec_path, link_path])
    print("agt-xfce session live for agent '%s'" % agent, flush=True)
    print("link: %s/%s" % (agt.HOST, token), flush=True)

    # Hold the deployment foreground; if the desktop session dies,
    # exit so the supervisor restarts the whole stack cleanly.
    while True:
        if session.poll() is not None:
            print("agt-xfce session: xfce4-session exited; tearing down", flush=True)
            cleanup()
        if os.path.exists(marker):
            print("agt-xfce session: closed by request; tearing down", flush=True)
            cleanup()
        time.sleep(2)


if __name__ == "__main__":
    main()
