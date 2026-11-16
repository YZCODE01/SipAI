#!/usr/bin/env python3
"""The REAL claude, codex and kimi rewind a session in place, each its own
way, and SipAI's readers must draw exactly the conversation the CLI sends
next. What each is asked comes from SipAI's own code (the harness binary's
helper commands): the entry claude resumes at, the turn codex reverts
before (through SipAI's app-server client), the turn kimi's undo takes
back from (named from kimi's own turn list, or counted on an older kimi)
and the route it goes to. Token-free: throwaway homes, local stand-in
endpoints, no provider.

  claude  -p --resume <id> --resume-session-at <the entry above the edit>
  codex   app-server thread/resume + thread/revert {beforeTurnId}
  kimi    kimi web -> GET  /api/v1/sessions/<id>/agents/main/turns, then
                     POST /api/v1/sessions/<id>:undo {turn_id} ({count} on an older kimi)

Usage: live.py <harness binary> <scratch dir>
Prints the harness's own "ok"/"FAIL"/"SKIP" lines; exits 1 on a failure.
"""
import json
import os
import pty
import re
import select
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

BINARY, SCRATCH = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
FAKE = os.path.join(HERE, "..", "ChatOnlyMode", "fake_server.py")
ECHO = os.path.join(HERE, "anthropic_echo.py")
MARKS = ("ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOX")
failures = 0


def check(label, ok, detail=""):
    global failures
    print(("  ok   " if ok else "  FAIL ") + label + (" — " + detail if detail and not ok else ""))
    if not ok:
        failures += 1


def skip(label, why):
    print("  SKIP " + label + " — " + why)


def which(name):
    home = os.path.expanduser("~")
    for d in os.environ.get("PATH", "").split(":") + [home + "/.local/bin", home + "/.kimi-code/bin",
                                                      "/opt/homebrew/bin", "/usr/local/bin"]:
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return os.path.realpath(p)
    return None


def server(script, rec, *args):
    os.makedirs(rec, exist_ok=True)
    p = subprocess.Popen([sys.executable, "-I", script, rec, *args], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    while True:
        line = p.stdout.readline()
        if not line:
            raise RuntimeError("stand-in server did not start")
        if line.startswith("PORT="):
            return p, int(line.strip().split("=")[1])


def newest_request(rec, path_suffix):
    files = sorted(os.listdir(rec), key=lambda f: os.path.getmtime(os.path.join(rec, f)))
    for f in reversed(files):
        with open(os.path.join(rec, f)) as fh:
            o = json.load(fh)
        path = o.get("path", "").split("?")[0]
        if path.endswith(path_suffix):
            return o.get("body") or {}
    return {}


def marks_in(texts):
    """The probe's words, in order, out of a list of message texts."""
    out = []
    for t in texts:
        for m in MARKS:
            if t.strip() == m or t.strip().endswith("\n" + m) or t.strip().endswith(">" + m):
                out.append(m)
                break
    return out


def sipai_reads(agent, *paths):
    r = subprocess.run([BINARY, "read", agent, *paths], capture_output=True, text=True, timeout=60)
    try:
        return marks_in(json.loads(r.stdout.strip() or "[]"))
    except ValueError:
        return ["<unreadable: %s>" % r.stdout[:200]]


def sipai(*argv, env=None, timeout=120):
    """One of the harness binary's helper commands, its JSON answer."""
    r = subprocess.run([BINARY, *argv], capture_output=True, text=True, timeout=timeout, env=env)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"unreadable": r.stdout[:300] + r.stderr[:300]}


def isolated_env(home):
    tmp = os.path.join(home, "tmp")
    os.makedirs(tmp, exist_ok=True)
    return {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": home,
            "USER": os.environ.get("USER", "nobody"), "LANG": "en_US.UTF-8", "TMPDIR": tmp + "/",
            # Anything a CLI tries beyond the stand-in fails at once rather
            # than waiting on a network it must not reach.
            "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
            "HTTPS_PROXY": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9",
            "https_proxy": "http://127.0.0.1:9", "http_proxy": "http://127.0.0.1:9"}


# ---------------------------------------------------------------- claude

def claude_part():
    print("\n4. The real claude: an edit in place, then a branch from the edited session")
    claude = which("claude")
    if not claude:
        skip("claude", "not installed")
        return
    root = os.path.join(SCRATCH, "claude")
    home = os.path.join(root, "home")
    cfg = os.path.join(home, "cfg")
    work = os.path.join(root, "work")
    os.makedirs(cfg, exist_ok=True)
    os.makedirs(work, exist_ok=True)
    rec = os.path.join(root, "rec")
    srv, port = server(ECHO, rec)
    try:
        env = isolated_env(home)
        env.update({"CLAUDE_CONFIG_DIR": cfg, "ANTHROPIC_BASE_URL": "http://127.0.0.1:%d" % port,
                    "ANTHROPIC_API_KEY": "sk-ant-harness-junk", "CLAUDE_CODE_MAX_RETRIES": "0",
                    "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
        gate = subprocess.run([claude, "-p", "--resume-session-at", "x", "hi"], env=env, cwd=work,
                              capture_output=True, text=True, timeout=60)
        if "requires --resume" not in (gate.stdout + gate.stderr):
            skip("claude's truncating resume", "this claude does not name --resume-session-at")
            check("SipAI reads the installed claude as not naming the flag",
                  sipai("names-flag", claude).get("names") is False, json.dumps(sipai("names-flag", claude)))
            return
        check("SipAI reads the installed claude as naming the flag Send needs",
              sipai("names-flag", claude).get("names") is True, json.dumps(sipai("names-flag", claude)))
        check("…and a program that does not as not naming it",
              sipai("names-flag", "/bin/ls").get("names") is False, json.dumps(sipai("names-flag", "/bin/ls")))

        def turn(prompt, *extra):
            r = subprocess.run([claude, "-p", prompt, "--output-format", "stream-json", "--verbose",
                                "--model", "haiku", *extra], env=env, cwd=work,
                               capture_output=True, text=True, timeout=120)
            sid = None
            for line in r.stdout.splitlines():
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get("type") == "system" and o.get("subtype") == "init":
                    sid = o.get("session_id")
            body = newest_request(rec, "/messages")
            texts = []
            for m in body.get("messages", []):
                if m.get("role") != "user":
                    continue
                c = m.get("content")
                if isinstance(c, str):
                    texts.append(c)
                else:
                    texts += [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
            return sid, marks_in(texts)

        sid, _ = turn("ALPHA")
        if not sid:
            check("claude answers the stand-in", False)
            return
        turn("BRAVO", "--resume", sid)
        transcript = None
        for d, _, files in os.walk(os.path.join(cfg, "projects")):
            for f in files:
                if f == sid + ".jsonl":
                    transcript = os.path.join(d, f)
        records = [json.loads(l) for l in open(transcript) if l.strip()]
        bravo = next(r for r in records if r.get("type") == "user" and "BRAVO" in json.dumps(r.get("message")))
        handle = sipai("handle", "claude", transcript, "BRAVO").get("handle")
        by_row = sipai("anchor-claude", transcript, handle or "-", "", "0")
        by_words = sipai("anchor-claude", transcript, "-", "BRAVO", "0")
        check("SipAI's edit of BRAVO resumes at the entry above it — from its row and from its words",
              handle == bravo["uuid"] and by_row.get("entry") == bravo["parentUuid"]
              and by_words.get("entry") == bravo["parentUuid"],
              "%s %s %s" % (handle, by_row, by_words))
        first = sipai("anchor-claude", transcript, "-", "ALPHA", "0")
        check("…and an edit of the first message starts a new session",
              first.get("error") == "nothingToBranch", json.dumps(first))
        entry = by_row.get("entry") or bravo["parentUuid"]
        _, sent = turn("CHARLIE", "--resume", sid, "--resume-session-at", entry)
        check("claude sends the edit without the turn it replaced", sent == ["ALPHA", "CHARLIE"], str(sent))
        gone = sipai("anchor-claude", transcript, "-", "BRAVO", "0")
        check("…after which the message it replaced is not there to edit again",
              gone.get("error") == "cutPointNotFound", json.dumps(gone))
        _, sent = turn("DELTA", "--resume", sid)
        check("…and resumes on the new line afterwards", sent == ["ALPHA", "CHARLIE", "DELTA"], str(sent))
        drawn = sipai_reads("claude", transcript)
        check("SipAI draws what claude sends", drawn == sent, "drew %s, claude sent %s" % (drawn, sent))

        r = subprocess.run([BINARY, "cut-claude", transcript, "BRAVO", "0"], capture_output=True,
                           text=True, timeout=60)
        check("a live row's words never resolve to the turn the edit replaced",
              json.loads(r.stdout or "{}").get("uuid") is None, r.stdout.strip())

        records = [json.loads(l) for l in open(transcript) if l.strip()]
        charlie = next(r for r in records if r.get("type") == "user" and "CHARLIE" in json.dumps(r.get("message")))
        r = subprocess.run([BINARY, "fork-claude", transcript, charlie["uuid"]], capture_output=True,
                           text=True, timeout=60)
        branch = json.loads(r.stdout or "{}")
        if "id" not in branch:
            check("a branch at the edited message is written", False, r.stdout.strip())
            return
        _, sent = turn("ECHO", "--resume", branch["id"])
        check("claude resumes the branch on the line above the edit", sent == ["ALPHA", "ECHO"], str(sent))
        drawn = sipai_reads("claude", branch["file"])
        check("SipAI draws the branch as claude sends it", drawn == sent, "drew %s, claude sent %s" % (drawn, sent))

        # An edit whose turn loads a chosen skill too: SipAI's batch on
        # stdin (the skill's message, then the text), at the entry above.
        skill = os.path.join(cfg, "skills", "rewind-demo")
        os.makedirs(skill, exist_ok=True)
        with open(os.path.join(skill, "SKILL.md"), "w") as fh:
            fh.write("---\nname: rewind-demo\ndescription: A harness skill.\n---\nSKILL-BODY-MARK\n")
        records = [json.loads(l) for l in open(transcript) if l.strip()]
        delta = next(r for r in reversed(records)
                     if r.get("type") == "user" and "DELTA" in json.dumps(r.get("message")))
        entry = sipai("anchor-claude", transcript, delta["uuid"], "", "0").get("entry") or ""
        stdin = subprocess.run([BINARY, "claude-stdin", "rewind-demo", "FOX"], capture_output=True,
                               text=True, timeout=60).stdout
        subprocess.run([claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                        "--verbose", "--model", "haiku", "--resume", sid, "--resume-session-at", entry],
                       input=stdin, env=env, cwd=work, capture_output=True, text=True, timeout=120)
        body = newest_request(rec, "/messages")
        texts = []
        for m in body.get("messages", []):
            if m.get("role") == "user":
                c = m.get("content")
                texts += [c] if isinstance(c, str) else [b.get("text", "") for b in c
                                                         if isinstance(b, dict) and b.get("type") == "text"]
        sent = marks_in(texts)
        check("an edit whose turn loads a skill: claude sends the skill and the edit, not the turn replaced",
              "SKILL-BODY-MARK" in json.dumps(body.get("messages", [])) and sent == ["ALPHA", "CHARLIE", "FOX"],
              "%s, skill %s" % (sent, "SKILL-BODY-MARK" in json.dumps(body)))
        drawn = sipai_reads("claude", transcript)
        check("…and SipAI draws what claude sends", drawn == ["ALPHA", "CHARLIE", "FOX"], str(drawn))
    finally:
        srv.kill()


# ----------------------------------------------------------------- codex

def codex_part():
    print("\n5. The real codex: a revert through its app-server, twice")
    codex = which("codex")
    if not codex:
        skip("codex", "not installed")
        return
    root = os.path.join(SCRATCH, "codex")
    home = os.path.join(root, "home")
    chome = os.path.join(home, ".codex")
    proj = os.path.join(root, "proj")
    os.makedirs(chome, exist_ok=True)
    os.makedirs(proj, exist_ok=True)
    subprocess.run(["/usr/bin/git", "init", "-q", proj])
    proj = os.path.realpath(proj)
    rec = os.path.join(root, "rec")
    srv, port = server(FAKE, rec)
    try:
        with open(os.path.join(chome, "config.toml"), "w") as fh:
            fh.write('model_provider = "fake"\nmodel = "gpt-5.5"\n\n[model_providers.fake]\n'
                     'name = "fake"\nbase_url = "http://127.0.0.1:%d"\nwire_api = "responses"\n'
                     'requires_openai_auth = false\n' % port)
        env = isolated_env(home)
        env["CODEX_HOME"] = chome

        def exec_turn(prompt, resume=None):
            argv = [codex, "exec", "--json", "--skip-git-repo-check"] + (["resume", resume] if resume else []) + [prompt]
            r = subprocess.run(argv, cwd=proj, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                               text=True, timeout=120)
            tid = None
            for line in r.stdout.splitlines():
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get("type") == "thread.started":
                    tid = o.get("thread_id")
            body = newest_request(rec, "/responses")
            texts = []
            for it in body.get("input", []):
                if it.get("type") == "message" and it.get("role") == "user":
                    texts += [c.get("text", "") for c in it.get("content", [])]
            return tid, marks_in(texts)

        def turn_ids():
            ids = []
            for d, _, files in os.walk(os.path.join(chome, "sessions")):
                for f in sorted(files):
                    if tid in f:
                        for line in open(os.path.join(d, f)):
                            if '"task_started"' in line:
                                ids.append(json.loads(line)["payload"]["turn_id"])
            return ids

        tid, _ = exec_turn("ALPHA")
        if not tid:
            check("codex answers the stand-in", False)
            return
        exec_turn("BRAVO", tid)
        exec_turn("CHARLIE", tid)
        turns = turn_ids()

        def current_rollout():
            found = []
            for d, _, files in os.walk(os.path.join(chome, "sessions")):
                found += [os.path.join(d, f) for f in files if tid in f]
            return max(found, key=os.path.getmtime) if found else ""

        # SipAI's own client, under the same throwaway home: its readers
        # take Foundation's home, codex its CODEX_HOME.
        senv = dict(env)
        senv["CFFIXED_USER_HOME"] = home
        first = sipai("revert-codex", codex, current_rollout(), tid, "-", "ALPHA", "0", env=senv)
        check("SipAI: an edit of codex's first message starts a new session",
              first.get("error") == "nothingToBranch", json.dumps(first))
        answer = sipai("revert-codex", codex, current_rollout(), tid, "-", "BRAVO", "0", env=senv)
        if answer.get("unsupported"):
            skip("codex's revert", "this codex does not know thread/revert")
            return
        check("SipAI asks codex to revert before BRAVO's turn, and codex does",
              answer.get("turn") == turns[1] and bool(answer.get("reverted")), json.dumps(answer))
        check("…and the file codex names is the one SipAI's reader takes for the thread",
              answer.get("reverted") and os.path.realpath(answer.get("reverted"))
              == os.path.realpath(answer.get("current") or ""), json.dumps(answer))
        _, sent = exec_turn("ECHO", tid)
        check("codex sends the kept turns and the new one", sent == ["ALPHA", "ECHO"], str(sent))
        drawn = sipai_reads("codex", os.path.join(chome, "sessions"), os.path.join(chome, "sessions"), tid)
        check("SipAI draws what codex sends", drawn == sent, "drew %s, codex sent %s" % (drawn, sent))
        echo_turn = [t for t in turn_ids() if t not in turns][-1]
        handle = sipai("handle", "codex", current_rollout(), "ECHO", env=senv).get("handle")
        check("ECHO's row carries its turn", handle == echo_turn, "%s vs %s" % (handle, echo_turn))
        answer = sipai("revert-codex", codex, current_rollout(), tid, handle or "-", "", "0", env=senv)
        ok, detail = bool(answer.get("reverted")), json.dumps(answer)
        check("codex reverts again, inside its first revert, from the row's handle", ok, detail)
        _, sent = exec_turn("FOX", tid)
        check("…and sends the kept turns and the new one", sent == ["ALPHA", "FOX"], str(sent))
        drawn = sipai_reads("codex", os.path.join(chome, "sessions"), os.path.join(chome, "sessions"), tid)
        check("SipAI draws what codex sends after two reverts", drawn == sent,
              "drew %s, codex sent %s" % (drawn, sent))
        refused = sipai("revert-codex-at", codex, tid, "turn-that-does-not-exist", env=senv)
        check("a revert codex refuses comes back in codex's own words",
              bool(refused.get("refused")), json.dumps(refused))
    finally:
        srv.kill()


# ------------------------------------------------------------------ kimi

def kimi_acp_turn(kimi, cwd, env, text, sid=None):
    """One turn through `kimi acp`, the front end a Default turn runs on; the session's id.
    `text` must call no tool: nothing here answers a card."""
    p = subprocess.Popen([kimi, "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, cwd=cwd, env=env)
    pending = [b""]

    def answer(number, method, params):
        p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": number, "method": method,
                                   "params": params}) + "\n").encode())
        p.stdin.flush()
        end = time.time() + 60
        while time.time() < end:
            if select.select([p.stdout], [], [], 0.3)[0]:
                chunk = os.read(p.stdout.fileno(), 65536)
                if not chunk:
                    break
                pending[0] += chunk
            while b"\n" in pending[0]:
                line, pending[0] = pending[0].split(b"\n", 1)
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get("id") == number and "method" not in o:
                    return o.get("result") or {}
        return {}

    answer(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {},
                             "clientInfo": {"name": "harness", "version": "0"}})
    if sid:
        answer(2, "session/resume", {"sessionId": sid, "cwd": cwd, "mcpServers": []})
    else:
        sid = answer(2, "session/new", {"cwd": cwd, "mcpServers": []}).get("sessionId")
    answer(3, "session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]})
    p.stdin.close()
    try:
        p.wait(timeout=12)
    except subprocess.TimeoutExpired:
        p.kill()
    return sid


def kimi_part():
    print("\n6. The real kimi: an undo through its local server")
    kimi = which("kimi")
    if not kimi:
        skip("kimi", "not installed")
        return
    root = os.path.join(SCRATCH, "kimi")
    home = os.path.join(root, "home")
    khome = os.path.join(home, ".kimi-code")
    work = os.path.join(root, "work")
    os.makedirs(khome, exist_ok=True)
    os.makedirs(work, exist_ok=True)
    work = os.path.realpath(work)
    rec = os.path.join(root, "rec")
    chat_script = os.path.join(root, "chat-script.json")
    with open(chat_script, "w") as fh:
        json.dump([{"marker": "SIPAI-BASH", "steps": [
            {"tool_calls": [{"id": "c1", "name": "Bash", "arguments": {"command": "echo hi-from-bash"}}]},
            {"text": "done after bash"}]}], fh)
    srv, port = server(FAKE, rec, "--chat-script", chat_script)
    web = None
    master = None
    try:
        with open(os.path.join(khome, "config.toml"), "w") as fh:
            fh.write('default_model = "fake/fake-model"\n\n[providers.fake]\nbase_url = "http://127.0.0.1:%d/v1"\n'
                     'type = "openai"\napi_key = "junk"\n\n[models."fake/fake-model"]\nprovider = "fake"\n'
                     'model = "fake-model"\nmax_context_size = 262144\ncapabilities = [ "tool_use" ]\n' % port)
        env = isolated_env(home)
        env["KIMI_CODE_HOME"] = khome
        tool_answers = [[]]

        def turn(prompt, sid=None):
            r = subprocess.run([kimi, "--prompt", prompt, "--output-format", "stream-json"] +
                               (["--session", sid] if sid else []), cwd=work, env=env,
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
            got = sid
            for line in r.stdout.splitlines():
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get("type") == "session.resume_hint":
                    got = o.get("session_id")
            body = newest_request(rec, "/chat/completions")
            texts = []
            for m in body.get("messages", []):
                if m.get("role") != "user":
                    continue
                c = m.get("content")
                texts += [c] if isinstance(c, str) else [b.get("text", "") for b in (c or []) if isinstance(b, dict)]
            tool_answers[0] = [str(m.get("content")) for m in body.get("messages", []) if m.get("role") == "tool"]
            return got, marks_in(texts)

        sid, _ = turn("ALPHA")
        if not sid:
            check("kimi answers the stand-in", False)
            return
        turn("BRAVO", sid)
        turn("CHARLIE", sid)

        def find_wire(session):
            for d, _, files in os.walk(os.path.join(khome, "sessions")):
                if os.path.basename(os.path.dirname(os.path.dirname(d))) == session and "wire.jsonl" in files:
                    return os.path.join(d, "wire.jsonl")
            return None
        wire = find_wire(sid)
        if not wire:
            check("kimi's session is on disk", False)
            return
        handle = sipai("handle", "kimi", wire, "BRAVO").get("handle")
        by_row = sipai("undo-kimi", wire, sid, handle or "-", "", "0")
        by_words = sipai("undo-kimi", wire, sid, "-", "BRAVO", "0")
        check("SipAI's edit of BRAVO takes back two turns, at kimi's route for the session",
              by_row.get("count") == 2 and by_words.get("count") == 2
              and by_row.get("path") == "/api/v1/sessions/%s:undo" % sid,
              "%s %s %s" % (handle, by_row, by_words))
        first = sipai("undo-kimi", wire, sid, "-", "ALPHA", "0")
        check("…and an edit of kimi's first message starts a new session",
              first.get("error") == "nothingToBranch", json.dumps(first))
        # An ACP turn's binding is written as the session opens, above its prompt, and
        # SipAI's hand-back after the turn, so an undo of that turn takes back what lies
        # between them. SipAI reads the newest binding in the file, undone or not: a kimi
        # that replayed the binding of what the undo left would run the session on ACP's
        # runtime with the file still saying `local`. The newest is read here as well,
        # because kimi's server itself writes `local` on opening a session left on `acp:`,
        # so a hand-back that did nothing would pass the check below all the same.
        bound = kimi_acp_turn(kimi, work, env, "ECHO")
        sipai("kimi-hand-back", find_wire(bound))
        kimi_acp_turn(kimi, work, env, "FOX", bound)
        handed = sipai("kimi-hand-back", find_wire(bound))
        check("SipAI hands an ACP turn back to the session's own binding",
              handed.get("restored") is True and handed.get("bound") == "local", json.dumps(handed))
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        wport = s.getsockname()[1]
        s.close()
        master, slave = pty.openpty()
        web = subprocess.Popen([kimi, "web", "--no-open", "--port", str(wport)], cwd=work, env=env,
                               stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
        os.close(slave)
        buf, token, end = b"", None, time.time() + 30
        while time.time() < end and token is None:
            if select.select([master], [], [], 0.5)[0]:
                try:
                    buf += os.read(master, 4096)
                except OSError:
                    break
                text = buf.decode("utf-8", "replace")
                at = text.find("#token=")
                if at >= 0:
                    rest = text[at + 7:]
                    stops = [i for i in (rest.find("\r"), rest.find("\n")) if i >= 0]
                    if stops:
                        token = rest[:min(stops)].strip()
        if not token:
            skip("kimi's undo", "kimi web did not start")
            return
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def call(path, body):
            req = urllib.request.Request("http://127.0.0.1:%d%s" % (wport, path), method="POST",
                                         data=json.dumps(body).encode(),
                                         headers={"Authorization": "Bearer " + token,
                                                  "Content-Type": "application/json"})
            try:
                with opener.open(req, timeout=30) as resp:
                    return resp.status, resp.read().decode()
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode()

        def get(path):
            req = urllib.request.Request("http://127.0.0.1:%d%s" % (wport, path),
                                         headers={"Authorization": "Bearer " + token})
            try:
                with opener.open(req, timeout=30) as resp:
                    return resp.status, resp.read().decode()
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode()

        # A newer kimi's undo names a turn of kimi's own list, an older one takes a count;
        # SipAI picks by the installed version (`kimiUndoNamesTurn`), as here.
        version = re.search(r"\d+(?:\.\d+)+", subprocess.run([kimi, "--version"], env=env, capture_output=True,
                                                             text=True, timeout=30).stdout or "")
        names_turn = sipai("kimi-names-turn", version.group(0) if version else "").get("namesTurn") is True
        print("    (kimi %s: its undo names %s)" % (version.group(0) if version else "?",
                                                    "a turn" if names_turn else "a count"))
        page_file = os.path.join(root, "turns-page.json")

        def turn_of(turns_path, message):
            """The turn `message` opened, from kimi's own list, page by page as SipAI asks."""
            path, status, body = turns_path, 0, ""
            for _ in range(50):
                status, body = get(path)
                with open(page_file, "w") as fh:
                    fh.write(body)
                page = sipai("kimi-turn", page_file, message)
                if page.get("turnId") or not page.get("hasMore") or page.get("oldest") is None:
                    return page.get("turnId"), "%s %s" % (status, body[:300])
                path = "%s&before_ordinal=%d" % (turns_path, page["oldest"])
            return None, "%s %s" % (status, body[:300])

        undo_path = by_row.get("path") or "/api/v1/sessions/%s:undo" % sid
        answer_file = os.path.join(root, "undo-answer.json")
        if names_turn:
            # What the version gate is for: a kimi whose undo names a turn refuses the count an
            # older kimi takes, and nothing is undone by it. The other way round is never tried:
            # an older kimi reads any body as a count — one, when it gives none — so a body
            # naming a turn would take a turn back there.
            status, detail = call(undo_path, {"count": 2})
            with open(answer_file, "w") as fh:
                fh.write(detail)
            check("control: this kimi refuses the count an older kimi's undo takes",
                  "refused" in sipai("kimi-answer", answer_file), "%s %s" % (status, detail[:300]))
        body = {"count": by_row.get("count") or 2}
        if names_turn:
            tid, listed = turn_of(by_row.get("turns"), by_row.get("message"))
            check("kimi's own turn list names the turn SipAI's edit of BRAVO opened", bool(tid), listed)
            body = {"turn_id": tid or "t_000000000000"}
        status, detail = call(undo_path, body)
        if status == 404 and not names_turn:
            skip("kimi's undo", "this kimi's server has no :undo")
            return
        with open(answer_file, "w") as fh:
            fh.write(detail)
        check("kimi undoes the last two turns, and SipAI reads its answer as done",
              status == 200 and sipai("kimi-answer", answer_file).get("undone") is True,
              "%s %s" % (status, detail[:300]))
        status, detail = call(undo_path, {"turn_id": "t_000000000000"} if names_turn else {"count": 9})
        with open(answer_file, "w") as fh:
            fh.write(detail)
        refused = sipai("kimi-answer", answer_file)
        check("an undo kimi refuses is read as refused, in kimi's own words",
              bool(refused.get("refused")) and "undone" not in refused,
              "%s %s → %s" % (status, detail[:300], refused))
        print("    (kimi's refusal: %s)" % refused.get("refused"))
        fox = sipai("undo-kimi", find_wire(bound), bound, "-", "FOX", "0")
        body = {"count": fox.get("count") or 1}
        if names_turn:
            tid, listed = turn_of(fox.get("turns") or "", fox.get("message") or "")
            check("…and names the ACP turn that was handed back", bool(tid), "%s %s" % (json.dumps(fox), listed))
            body = {"turn_id": tid or "t_000000000000"}
        status, detail = call(fox.get("path") or "/api/v1/sessions/%s:undo" % bound, body)
        with open(answer_file, "w") as fh:
            fh.write(detail)
        check("kimi undoes the ACP turn that was handed back",
              status == 200 and sipai("kimi-answer", answer_file).get("undone") is True,
              "%s %s" % (status, detail[:300]))
        call("/api/v1/shutdown", {})
        try:
            web.wait(timeout=10)
        except subprocess.TimeoutExpired:
            web.kill()
        _, sent = turn("DELTA", sid)
        check("kimi sends the kept turn and the new one", sent == ["ALPHA", "DELTA"], str(sent))
        wire = find_wire(sid)
        drawn = sipai_reads("kimi", wire) if wire else ["<no wire>"]
        check("SipAI draws what kimi sends", drawn == sent, "drew %s, kimi sent %s" % (drawn, sent))
        after = sipai("undo-kimi", wire, sid, "-", "DELTA", "0") if wire else {}
        check("…and counts from what the undo left: an edit of DELTA takes back one turn",
              after.get("count") == 1, json.dumps(after))

        # A session on ACP's runtime has no file or command tools in a headless turn. Kimi
        # still lists them in the request and answers `Tool "Bash" not found` only when one
        # is called, so only a tool that RAN can say. The newest answer: a request carries
        # the earlier turns' too.
        def bash_answer(session):
            turn("SIPAI-BASH please", session)
            return tool_answers[0][-1] if tool_answers[0] else "<no tool answered>"
        answer = bash_answer(sid)
        check("the undo leaves the session's commands running", "hi-from-bash" in answer, answer)
        answer = bash_answer(bound)
        check("…and the undo of an ACP turn leaves its hand-back standing", "hi-from-bash" in answer, answer)
        # Made here, with kimi's server gone: it binds a session back by itself.
        answer = bash_answer(kimi_acp_turn(kimi, work, env, "ECHO"))
        check("control: an ACP turn never handed back runs no command", 'Tool "Bash" not found' in answer, answer)
    finally:
        if web and web.poll() is None:
            web.kill()
        if master is not None:
            try:
                os.close(master)
            except OSError:
                pass
        srv.kill()


for part in (claude_part, codex_part, kimi_part):
    try:
        part()
    except Exception as e:  # a harness bug must read as a failure, never as a pass
        check(part.__name__ + " ran to the end", False, repr(e))
sys.exit(1 if failures else 0)
