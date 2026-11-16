"""The skills facts SipAI rests on, re-measured against the INSTALLED CLIs.

Token-free: every child runs under a throwaway HOME / CLAUDE_CONFIG_DIR /
CODEX_HOME in a temp folder, against the repo's fake endpoint
(../ChatOnlyMode/fake_server.py), with anything else sent to a dead
proxy. Nothing under the user's own home is read or written.

  claude  a linked skill is listed by the control requests, with no
          model call and no transcript, and a request claude does not
          know is REFUSED at once (an answer, not a silence); the
          stream-json batch loads two skills and the text in ONE model
          request, each skill message answering with a `num_turns: 0`
          result — with stdin held open, and closed at once as the app
          sends it; the transcript holds the command records and the
          expanded text in the shape the reader expects; a skill claude
          ships itself expands with NO "Base directory" line, known by
          the `promptId` it shares with its command
  codex   `skills/list` reports a linked skill by its realpath; a linked
          mention carrying that path injects the skill — through `exec`
          and through the app-server's text item, and from a folder with
          a space in its name — and a `/tmp` spelling of the same path
          does not (the negative control)
  format  every SKILL.md shape the harness measures, raw and as SipAI
          fixes it: SipAI flags every shape codex skips, says exactly
          which kimi skips (kimi over ACP: a session opened, no prompt),
          and every fix loads in all three
  reach   a SUBFOLDER's skill, from a session started above it: claude
          lists and loads it under `--add-dir <subfolder>` (and, without
          it, the quiet `/name` reaches the model as the text "/name");
          `codex exec` loads nothing by a mention — plain or with
          `--add-dir` — which is why only the app-server turn (handed the
          skills folder, `../CodexAppServerBridge` S) offers it
  after a compaction: codex's next turn carries the user's words but
          not the skill it injected. Kimi's carries a skill the user
          started — in the NEXT process too, through `kimi acp` and
          through its headless run, which is how SipAI runs turns — while
          the user's own messages fit kimi's budget for them, and its
          record of the summary counts them (`keptUserMessageCount`, no
          head count); past the budget the record counts a head too
          (`keptHeadUserMessageCount`) and a long skill loaded first comes
          back without its end. So SipAI re-sends for codex and claude,
          and for kimi only when its record says it trimmed
  a load that did not happen, in claude's own stream: a skill message
          that ran a command says so on its result (`local_command`), one
          for a name claude does not know carries no such key and is in
          no list its `init` gives — the two records
          `ClaudeSkillLoadCheck` reads
  levels  which folders codex and kimi read a skill from when started at
          a repository's root, in a package below it and one level
          further down, and the same with no repository — what
          `SkillRoots.betweenFolders` and the subfolder walk rest on:
          inside a repository codex reads `.codex/skills` and
          `.agents/skills` at every level down to where it starts and
          kimi reads the root alone; with none, each reads the folder it
          starts in alone; neither ever reads below where it starts
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE = os.path.join(HERE, "..", "ChatOnlyMode", "fake_server.py")
SEARCH = [os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

passed = 0
failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("  PASS " + name)
    else:
        failed += 1
        print("  FAIL " + name + (" — " + detail if detail else ""))


def find(tool):
    return shutil.which(tool, path=os.pathsep.join(SEARCH))


def skill(folder, name, marker, extra=""):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "SKILL.md"), "w") as f:
        f.write("---\nname: %s\ndescription: Fixture skill %s.\n%s---\n\n%s\nReply OK.\n"
                % (name, name, extra, marker))


def start_fake(record):
    os.makedirs(record, exist_ok=True)
    p = subprocess.Popen([sys.executable, FAKE, record], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    if not select.select([p.stdout], [], [], 10)[0]:
        p.kill()
        raise RuntimeError("fake server did not start")
    line = p.stdout.readline().strip()
    return p, int(line.split("=")[1])


def stop(p):
    if p and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()


def requests(record):
    out = []
    for n in sorted(os.listdir(record)):
        if n.endswith(".json"):
            with open(os.path.join(record, n)) as f:
                out.append(json.load(f))
    return out


def base_env(home, port):
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": home, "USER": os.environ.get("USER", "nobody"),
        "LANG": "en_US.UTF-8", "TMPDIR": os.path.join(home, "tmp") + "/",
        "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
        "HTTPS_PROXY": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9",
        "https_proxy": "http://127.0.0.1:9", "http_proxy": "http://127.0.0.1:9",
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:%d" % port,
        "ANTHROPIC_API_KEY": "sk-ant-local-fixture",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    }


def stream(argv, cwd, env, lines, until, timeout=60):
    """Feed `lines` to a child's stdin, read its stdout until `until`
    says stop (or the timeout), then close stdin and reap it."""
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    for line in lines:
        p.stdin.write(line + "\n")
    p.stdin.flush()
    got = []
    end = time.time() + timeout
    while time.time() < end:
        if not select.select([p.stdout], [], [], 0.5)[0]:
            if p.poll() is not None:
                break
            continue
        line = p.stdout.readline()
        if not line:
            break
        try:
            got.append(json.loads(line))
        except ValueError:
            continue
        if until(got):
            break
    try:
        p.stdin.close()
    except OSError:
        pass
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
    return got


def claude_checks(root):
    claude = find("claude")
    if not claude:
        print("  SKIP claude is not installed")
        return
    print("claude: " + subprocess.run([claude, "--version"], capture_output=True, text=True,
                                      stdin=subprocess.DEVNULL).stdout.strip())
    home = os.path.join(root, "claude-home")
    cfg = os.path.join(home, ".claude")
    proj = os.path.join(root, "claude-proj")
    for d in (os.path.join(home, "tmp"), proj):
        os.makedirs(d, exist_ok=True)
    lib = os.path.join(home, ".sipai", "skills")
    skill(os.path.join(lib, "alpha"), "alpha", "MARKER_ALPHA_7")
    skill(os.path.join(lib, "beta"), "beta", "MARKER_BETA_9")
    os.makedirs(os.path.join(cfg, "skills"))
    for n in ("alpha", "beta"):
        os.symlink(os.path.join(lib, n), os.path.join(cfg, "skills", n))
    record = os.path.join(root, "claude-requests")
    fake, port = start_fake(record)
    try:
        env = base_env(home, port)
        env["CLAUDE_CONFIG_DIR"] = cfg
        argv = [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                "--verbose", "--model", "claude-opus-5-5"]

        # 1. Listing: two control requests, no model call, no transcript.
        ids = ("h-commands", "h-dialog")
        lines = [json.dumps({"type": "control_request", "request_id": ids[0],
                             "request": {"subtype": "initialize"}}),
                 json.dumps({"type": "control_request", "request_id": ids[1],
                             "request": {"subtype": "get_skills_dialog"}})]

        def both(got):
            seen = {o.get("response", {}).get("request_id") for o in got if o.get("type") == "control_response"}
            return set(ids) <= seen
        got = stream(argv, proj, env, lines, both, timeout=40)
        answers = {o["response"]["request_id"]: o["response"].get("response", {})
                   for o in got if o.get("type") == "control_response" and "response" in o}
        commands = [c.get("name") for c in answers.get(ids[0], {}).get("commands", [])]
        dialog = {s.get("name"): s for s in answers.get(ids[1], {}).get("skills", [])}
        check("claude lists a linked skill (initialize)", "alpha" in commands, str(commands)[:200])
        check("…and the dialog gives its state", dialog.get("alpha", {}).get("state") == "on",
              json.dumps(dialog.get("alpha"))[:200])
        model_calls = [r for r in requests(record) if r.get("path", "").split("?")[0].endswith("/messages")]
        check("…with no model call", not model_calls, "%d calls" % len(model_calls))
        transcripts = []
        for d, _, files in os.walk(os.path.join(cfg, "projects")):
            transcripts += [os.path.join(d, f) for f in files if f.endswith(".jsonl")]
        check("…and no transcript", not transcripts, str(transcripts)[:200])

        # 1b. A request claude does not know: refused at once, by id. The
        # app counts that as an answer — waited out, every read of the
        # skills would stall for its whole ceiling on an older claude.
        t0 = time.time()
        got = stream(argv, proj, env,
                     [json.dumps({"type": "control_request", "request_id": "h-unknown",
                                  "request": {"subtype": "sipai_harness_unknown_request"}})],
                     lambda g: any(o.get("type") == "control_response" for o in g), timeout=20)
        refusal = next((o.get("response", {}) for o in got if o.get("type") == "control_response"), {})
        check("a control request claude does not know is refused at once, under its id",
              refusal.get("request_id") == "h-unknown" and refusal.get("subtype") == "error"
              and "response" not in refusal and time.time() - t0 < 10, json.dumps(refusal)[:200])

        # 2. The batch SipAI sends.
        def user(text, quiet):
            o = {"type": "user", "message": {"role": "user", "content": text},
                 "parent_tool_use_id": None, "session_id": ""}
            if quiet:
                o["shouldQuery"] = False
            return json.dumps(o, sort_keys=True)
        before = len(requests(record))

        def final(got):
            return sum(1 for o in got if o.get("type") == "result") >= 3
        got = stream(argv, proj, env, [user("/alpha", True), user("/beta", True), user("do X", False)],
                     final, timeout=90)
        results = [o for o in got if o.get("type") == "result"]
        check("each skill message answers with a num_turns 0 result, then the turn's",
              len(results) == 3 and [r.get("num_turns") for r in results[:2]] == [0, 0]
              and (results[2].get("num_turns") or 0) >= 1,
              str([r.get("num_turns") for r in results]))
        calls = [r for r in requests(record)[before:] if r.get("path", "").split("?")[0].endswith("/messages")]
        body = json.dumps(calls[0].get("body", {})) if calls else ""
        check("ONE model request carries both skills and the text",
              len(calls) == 1 and "MARKER_ALPHA_7" in body and "MARKER_BETA_9" in body and "do X" in body,
              "%d calls" % len(calls))

        # 3. The records the reader is built on.
        transcripts = []
        for d, _, files in os.walk(os.path.join(cfg, "projects")):
            transcripts += [os.path.join(d, f) for f in files if f.endswith(".jsonl")]
        records = []
        for t in transcripts:
            with open(t) as f:
                for line in f:
                    try:
                        records.append(json.loads(line))
                    except ValueError:
                        pass

        def text(o):
            c = (o.get("message") or {}).get("content")
            if isinstance(c, list):
                return "".join(b.get("text", "") for b in c if isinstance(b, dict))
            return c or ""
        users = [o for o in records if o.get("type") == "user"]
        commands = [o for o in users if "<command-name>/alpha</command-name>" in text(o)]
        bodies = [o for o in users if o.get("isMeta") and text(o).strip().startswith("Base directory for this skill:")]
        check("the command record is a user record holding <command-name>/alpha</command-name>",
              len(commands) == 1 and not commands[0].get("isMeta"))
        check("the expanded skill is an isMeta record opening \"Base directory for this skill:\"",
              len(bodies) == 2)
        order = [("cmd" if "<command-name>" in text(o) else "body" if o.get("isMeta") else "text")
                 for o in users]
        check("the order the reader holds: command, body, command, body, then the text",
              order[-5:] == ["cmd", "body", "cmd", "body", "text"], str(order))

        # 4. The batch as the app's runner sends it: written, and stdin
        # closed at once.
        before = len(requests(record))
        p = subprocess.Popen(argv, cwd=proj, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True)
        out, _ = p.communicate("\n".join([user("/alpha", True), user("/beta", True),
                                          user("do Z", False)]) + "\n", timeout=120)
        turns = []
        for line in out.splitlines():
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") == "result":
                turns.append(o.get("num_turns"))
        calls = [r for r in requests(record)[before:] if r.get("path", "").split("?")[0].endswith("/messages")]
        body = json.dumps(calls[0].get("body", {})) if calls else ""
        check("the batch survives stdin closing at once: two empty results, then ONE request with it all",
              turns[:2] == [0, 0] and len(turns) == 3 and (turns[2] or 0) >= 1 and len(calls) == 1
              and "MARKER_ALPHA_7" in body and "MARKER_BETA_9" in body and "do Z" in body,
              "%s, %d calls" % (turns, len(calls)))

        # 5. A skill claude ships itself has no folder. Its expansion is
        # an isMeta record carrying its command's promptId, and does NOT
        # open with "Base directory for this skill:" — which is why the
        # reader knows an expansion by what the record is.
        shipped = "simplify"
        subprocess.run([claude, "-p", "--output-format", "stream-json", "--verbose", "--model",
                        "claude-opus-5-5", "/" + shipped], cwd=proj, env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=120)
        pair = None
        for d, _, files in os.walk(os.path.join(cfg, "projects")):
            for f in files:
                if not f.endswith(".jsonl"):
                    continue
                recs = []
                with open(os.path.join(d, f)) as fh:
                    for line in fh:
                        try:
                            recs.append(json.loads(line))
                        except ValueError:
                            pass
                us = [o for o in recs if o.get("type") == "user"]
                for i, o in enumerate(us[:-1]):
                    if "<command-name>/%s</command-name>" % shipped in text(o):
                        pair = (o, us[i + 1])
        if pair is None:
            print("  SKIP claude wrote no /%s command record: name another skill it ships here" % shipped)
        else:
            command, expansion = pair
            check("a shipped skill's expansion is an isMeta record carrying its command's promptId",
                  expansion.get("isMeta") is True and command.get("promptId")
                  and expansion.get("promptId") == command.get("promptId"),
                  "%s vs %s" % (expansion.get("promptId"), command.get("promptId")))
            check("…and does not open with \"Base directory for this skill:\"",
                  bool(text(expansion).strip())
                  and not text(expansion).strip().startswith("Base directory for this skill:"),
                  text(expansion)[:80])
    finally:
        stop(fake)


def codex_checks(root):
    codex = find("codex")
    if not codex:
        print("  SKIP codex is not installed")
        return
    print("codex: " + subprocess.run([codex, "--version"], capture_output=True, text=True,
                                     stdin=subprocess.DEVNULL).stdout.strip())
    home = os.path.join(root, "codex-home")
    chome = os.path.join(home, ".codex")
    proj = os.path.join(root, "codex-proj")
    for d in (os.path.join(home, "tmp"), proj, os.path.join(chome, "skills")):
        os.makedirs(d, exist_ok=True)
    lib = os.path.join(home, ".sipai", "skills")
    skill(os.path.join(lib, "alpha"), "alpha", "MARKER_CODEX_ALPHA")
    os.symlink(os.path.join(lib, "alpha"), os.path.join(chome, "skills", "alpha"))
    record = os.path.join(root, "codex-requests")
    fake, port = start_fake(record)
    try:
        with open(os.path.join(chome, "config.toml"), "w") as f:
            f.write('model_provider = "fake"\nmodel = "gpt-5.5"\n\n[model_providers.fake]\n'
                    'name = "fake"\nbase_url = "http://127.0.0.1:%d"\nwire_api = "responses"\n'
                    'requires_openai_auth = false\n' % port)
        env = base_env(home, port)
        env["CODEX_HOME"] = chome
        env["PATH"] = os.pathsep.join(SEARCH + ["/bin", "/usr/sbin", "/sbin"])

        # 1. skills/list over the app-server.
        lines = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                             "params": {"clientInfo": {"name": "sipai-harness", "version": "1"}}}),
                 json.dumps({"jsonrpc": "2.0", "method": "initialized"}),
                 json.dumps({"jsonrpc": "2.0", "id": 2, "method": "skills/list",
                             "params": {"cwds": [proj], "forceReload": True}})]
        got = stream([codex, "app-server"], proj, env, lines,
                     lambda g: any(o.get("id") == 2 for o in g), timeout=40)
        answer = next((o for o in got if o.get("id") == 2), {})
        skills = [s for d in (answer.get("result") or {}).get("data", []) for s in d.get("skills", [])]
        alpha = next((s for s in skills if s.get("name") == "alpha"), None)
        real = os.path.realpath(os.path.join(lib, "alpha", "SKILL.md"))
        check("codex lists a linked skill", alpha is not None, str([s.get("name") for s in skills])[:200])
        check("…by its realpath", alpha is not None and alpha.get("path") == real,
              "%s vs %s" % (alpha and alpha.get("path"), real))

        # 2. A mention injects only with codex's own spelling.
        def turn(mention_path, label):
            before = len(requests(record))
            subprocess.run([codex, "exec", "--json", "--skip-git-repo-check",
                            "[$alpha](%s)\n\ndo X %s" % (mention_path, label)],
                           cwd=proj, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, timeout=120)
            bodies = [json.dumps(r.get("body", {})) for r in requests(record)[before:]
                      if r.get("path", "").split("?")[0].endswith("/responses")]
            return any("<skill>" in b and "MARKER_CODEX_ALPHA" in b for b in bodies), len(bodies)
        injected, n = turn(real, "canonical")
        check("a mention carrying codex's path injects the skill", injected, "%d requests" % n)
        if real.startswith("/private/"):
            injected, n = turn(real[len("/private"):], "short")
            check("…and the same path without /private does not (the control)", not injected,
                  "%d requests" % n)

        # 3. A project skill under a folder with a space in its name: the
        # link holds the path as it is.
        spaced = os.path.join(root, "codex proj two")
        skill(os.path.join(spaced, ".codex", "skills", "gamma"), "gamma", "MARKER_CODEX_GAMMA")
        spaced_real = os.path.realpath(os.path.join(spaced, ".codex", "skills", "gamma", "SKILL.md"))
        before = len(requests(record))
        subprocess.run([codex, "exec", "--json", "--skip-git-repo-check",
                        "[$gamma](%s)\n\ndo X spaced" % spaced_real],
                       cwd=spaced, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        bodies = [json.dumps(r.get("body", {})) for r in requests(record)[before:]
                  if r.get("path", "").split("?")[0].endswith("/responses")]
        check("a mention whose path holds a space injects the skill",
              " " in spaced_real and any("<skill>" in b and "MARKER_CODEX_GAMMA" in b for b in bodies),
              "%d requests" % len(bodies))

        # 4. The app-server's text item takes the same line (Agent and Plan turns).
        before = len(requests(record))
        p = subprocess.Popen([codex, "app-server"], cwd=proj, env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

        def send(o):
            p.stdin.write(json.dumps(o) + "\n")
            p.stdin.flush()

        def wait(pred, timeout):
            end = time.time() + timeout
            while time.time() < end:
                if not select.select([p.stdout], [], [], 0.5)[0]:
                    if p.poll() is not None:
                        return None
                    continue
                line = p.stdout.readline()
                if not line:
                    return None
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if pred(o):
                    return o
            return None
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "sipai-harness", "version": "1"},
                         "capabilities": {"experimentalApi": True}}})
        wait(lambda o: o.get("id") == 1, 30)
        send({"jsonrpc": "2.0", "method": "initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "thread/start",
              "params": {"cwd": proj, "approvalPolicy": "on-request", "approvalsReviewer": "user",
                         "sandbox": "workspace-write"}})
        started = wait(lambda o: o.get("id") == 2, 30) or {}
        thread = ((started.get("result") or {}).get("thread") or {}).get("id")
        send({"jsonrpc": "2.0", "id": 3, "method": "turn/start",
              "params": {"threadId": thread,
                         "input": [{"type": "text", "text": "[$alpha](%s)\n\ndo X served" % real}]}})
        done = wait(lambda o: o.get("method") == "turn/completed", 90)
        try:
            p.stdin.close()
        except OSError:
            pass
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
        bodies = [json.dumps(r.get("body", {})) for r in requests(record)[before:]
                  if r.get("path", "").split("?")[0].endswith("/responses")]
        check("the app-server's text item takes the mention line too",
              done is not None and any("<skill>" in b and "MARKER_CODEX_ALPHA" in b for b in bodies),
              "%d requests" % len(bodies))
    finally:
        stop(fake)


def install_shapes(shapes, which, into):
    """Copy the harness's shapes (`raw` or `fixed`) into a skills folder,
    each under a folder named after its shape."""
    src = os.path.join(shapes, which)
    os.makedirs(into, exist_ok=True)
    for name in sorted(os.listdir(src)):
        shutil.copytree(os.path.join(src, name), os.path.join(into, name))


def claude_listed(root, tag, skills_tree):
    """The folders of the user skills claude lists, read with no model
    call: its dialog keys each one by its folder's name."""
    claude = find("claude")
    home = os.path.join(root, "claude-fmt-" + tag)
    cfg = os.path.join(home, ".claude")
    os.makedirs(os.path.join(home, "tmp"), exist_ok=True)
    shutil.copytree(skills_tree, os.path.join(cfg, "skills"))
    env = base_env(home, 9)
    env["CLAUDE_CONFIG_DIR"] = cfg
    got = stream([claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
                 home, env, [json.dumps({"type": "control_request", "request_id": "f-dialog",
                                         "request": {"subtype": "get_skills_dialog"}})],
                 lambda g: any(o.get("type") == "control_response" for o in g), timeout=40)
    answer = next((o["response"].get("response", {}) for o in got
                   if o.get("type") == "control_response" and "response" in o), {})
    return {s.get("name") for s in answer.get("skills", []) if s.get("source") == "user"}


def codex_listed(root, tag, skills_tree):
    """The folders codex loads a skill from, and the ones it skipped."""
    codex = find("codex")
    home = os.path.join(root, "codex-fmt-" + tag)
    chome = os.path.join(home, ".codex")
    proj = os.path.join(home, "proj")
    for d in (os.path.join(home, "tmp"), proj):
        os.makedirs(d, exist_ok=True)
    shutil.copytree(skills_tree, os.path.join(chome, "skills"))
    with open(os.path.join(chome, "config.toml"), "w") as f:
        f.write('model_provider = "fake"\nmodel = "gpt-5.5"\n\n[model_providers.fake]\nname = "fake"\n'
                'base_url = "http://127.0.0.1:9"\nwire_api = "responses"\nrequires_openai_auth = false\n')
    env = base_env(home, 9)
    env["CODEX_HOME"] = chome
    env["PATH"] = os.pathsep.join(SEARCH + ["/bin", "/usr/sbin", "/sbin"])
    lines = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"clientInfo": {"name": "sipai-harness", "version": "1"}}}),
             json.dumps({"jsonrpc": "2.0", "method": "initialized"}),
             json.dumps({"jsonrpc": "2.0", "id": 2, "method": "skills/list",
                         "params": {"cwds": [proj], "forceReload": True}})]
    got = stream([codex, "app-server"], proj, env, lines, lambda g: any(o.get("id") == 2 for o in g), timeout=40)
    answer = next((o for o in got if o.get("id") == 2), {})
    data = (answer.get("result") or {}).get("data", [])
    loaded = {os.path.basename(os.path.dirname(s.get("path", ""))) for d in data for s in d.get("skills", [])}
    skipped = {os.path.basename(os.path.dirname(e.get("path", ""))) for d in data for e in d.get("errors", [])}
    return loaded, skipped


def kimi_listed(root, tag, skills_tree):
    """The folders of the skills kimi offers as commands when a session
    opens over ACP — no prompt, so no model call. Kimi offers a skill by
    the name in its header, read back to its folder here."""
    kimi = os.path.expanduser("~/.kimi-code/bin/kimi")
    home = os.path.join(root, "kimi-fmt-" + tag)
    kh = os.path.join(home, "kh")
    proj = os.path.join(home, "proj")
    for d in (os.path.join(home, "tmp"), proj):
        os.makedirs(d, exist_ok=True)
    shutil.copytree(skills_tree, os.path.join(kh, "skills"))
    with open(os.path.join(kh, "config.toml"), "w") as f:
        f.write('default_model = "fake/fake-model"\n\n[providers.fake]\nbase_url = "http://127.0.0.1:9/v1"\n'
                'type = "openai"\napi_key = "junk"\n\n[models."fake/fake-model"]\nprovider = "fake"\n'
                'model = "fake-model"\nmax_context_size = 262144\ncapabilities = [ "tool_use" ]\n')
    env = base_env(home, 9)
    env["KIMI_CODE_HOME"] = kh
    lines = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"protocolVersion": 1, "clientCapabilities": {
                             "fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}}}),
             json.dumps({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                         "params": {"cwd": proj, "mcpServers": []}})]

    def offered(g):
        return any(o.get("method") == "session/update"
                   and o.get("params", {}).get("update", {}).get("sessionUpdate") == "available_commands_update"
                   for o in g)
    got = stream([kimi, "acp"], proj, env, lines, offered, timeout=40)
    names = set()
    for o in got:
        upd = o.get("params", {}).get("update", {}) if o.get("method") == "session/update" else {}
        if upd.get("sessionUpdate") == "available_commands_update":
            names = {c.get("name", "")[len("skill:"):] for c in upd.get("availableCommands", [])
                     if c.get("name", "").startswith("skill:")}
    loaded = set()
    for folder in os.listdir(skills_tree):
        with open(os.path.join(skills_tree, folder, "SKILL.md"), encoding="utf-8-sig", errors="replace") as fh:
            lines = fh.read().splitlines()
        name = folder
        for line in lines[1:]:
            if line.strip() == "---":
                break
            if line.startswith("name:"):
                name = line[len("name:"):].strip().strip('"')
        if name in names:
            loaded.add(folder)
    return loaded


def format_checks(root):
    """Each shape the harness wrote (SIPAI_SKILLS_SHAPES_DIR), raw and as
    SipAI fixes it, handed to the installed CLIs: SipAI must flag every
    shape an agent skips, and every fix must load in all three."""
    shapes = os.environ.get("SIPAI_SKILLS_SHAPES_DIR")
    if not shapes or not os.path.isdir(shapes):
        print("  SKIP no shapes were written (run through run.sh)")
        return
    with open(os.path.join(shapes, "expect.json")) as f:
        expect = json.load(f)
    raw_tree = os.path.join(root, "fmt-raw")
    fixed_tree = os.path.join(root, "fmt-fixed")
    install_shapes(shapes, "raw", raw_tree)
    install_shapes(shapes, "fixed", fixed_tree)
    raw = sorted(expect)
    fixed = sorted(n for n in expect if expect[n]["fixable"])

    if find("claude"):
        listed = claude_listed(root, "raw", raw_tree)
        missing = [n for n in raw if n not in listed]
        check("claude loads every raw shape", not missing, str(missing))
        listed = claude_listed(root, "fixed", fixed_tree)
        missing = [n for n in fixed if n not in listed]
        check("…and every fixed one", not missing, str(missing))
    else:
        print("  SKIP claude is not installed")
    if find("codex"):
        loaded, skipped = codex_listed(root, "raw", raw_tree)
        unflagged = [n for n in raw if n not in loaded and not expect[n]["codex"]]
        check("every shape codex skips, SipAI flags for codex", not unflagged,
              "%s (codex skipped: %s)" % (unflagged, sorted(skipped)))
        flagged_loaded = [n for n in raw if expect[n]["codex"] and n in loaded]
        if flagged_loaded:
            print("  note codex loads these flagged shapes anyway (SipAI fixes them for it all the same): %s"
                  % ", ".join(flagged_loaded))
        loaded, _ = codex_listed(root, "fixed", fixed_tree)
        missing = [n for n in fixed if n not in loaded]
        check("…and loads every fixed one", not missing, str(missing))
    else:
        print("  SKIP codex is not installed")
    if os.path.exists(os.path.expanduser("~/.kimi-code/bin/kimi")):
        loaded = kimi_listed(root, "raw", raw_tree)
        wrong = [n for n in raw if (n not in loaded) != expect[n]["kimi"]]
        check("SipAI's rules say exactly which shapes kimi skips", not wrong,
              ", ".join("%s (kimi %s)" % (n, "loads" if n in loaded else "skips") for n in wrong))
        loaded = kimi_listed(root, "fixed", fixed_tree)
        missing = [n for n in fixed if n not in loaded]
        check("…and kimi loads every fixed one", not missing, str(missing))
    else:
        print("  SKIP kimi is not installed")


def levels_tree(root, tag, git):
    """A workspace with a skill in each agent folder at three depths."""
    home = os.path.join(root, "levels-" + tag)
    ws = os.path.join(home, "ws")
    for d in (os.path.join(home, "tmp"), ws, os.path.join(home, ".codex"), os.path.join(home, "kh")):
        os.makedirs(d, exist_ok=True)
    with open(os.path.join(home, ".codex", "config.toml"), "w") as f:
        f.write('model_provider = "fake"\nmodel = "gpt-5.5"\n\n[model_providers.fake]\nname = "fake"\n'
                'base_url = "http://127.0.0.1:9"\nwire_api = "responses"\nrequires_openai_auth = false\n')
    with open(os.path.join(home, "kh", "config.toml"), "w") as f:
        f.write('default_model = "fake/fake-model"\n\n[providers.fake]\nbase_url = "http://127.0.0.1:9/v1"\n'
                'type = "openai"\napi_key = "junk"\n\n[models."fake/fake-model"]\nprovider = "fake"\n'
                'model = "fake-model"\nmax_context_size = 262144\ncapabilities = [ "tool_use" ]\n')
    if git:
        subprocess.run(["/usr/bin/git", "init", "-q", ws], check=True,
                       env={"PATH": "/usr/bin:/bin", "HOME": home, "GIT_CONFIG_NOSYSTEM": "1"})
    for depth, rel in (("top", ""), ("pkg", "pkg"), ("sub", "pkg/sub")):
        for kind, folder in (("common", ".agents/skills"), ("codex", ".codex/skills"), ("kimi", ".kimi-code/skills")):
            name = "%s-%s" % (depth, kind)
            skill(os.path.join(ws, rel, folder, name), name, "LEVEL")
    return home, ws


def codex_level_names(home, cwd):
    env = base_env(home, 9)
    env["CODEX_HOME"] = os.path.join(home, ".codex")
    env["PATH"] = os.pathsep.join(SEARCH + ["/bin", "/usr/sbin", "/sbin"])
    lines = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"clientInfo": {"name": "sipai-harness", "version": "1"}}}),
             json.dumps({"jsonrpc": "2.0", "method": "initialized"}),
             json.dumps({"jsonrpc": "2.0", "id": 2, "method": "skills/list",
                         "params": {"cwds": [cwd], "forceReload": True}})]
    got = stream([find("codex"), "app-server"], cwd, env, lines, lambda g: any(o.get("id") == 2 for o in g), timeout=40)
    answer = next((o for o in got if o.get("id") == 2), None)
    if answer is None:
        return None
    data = (answer.get("result") or {}).get("data", [])
    return sorted(n for n in (s.get("name", "") for d in data for s in d.get("skills", []))
                  if n.split("-")[0] in ("top", "pkg", "sub"))


def kimi_level_names(home, cwd):
    env = base_env(home, 9)
    env["KIMI_CODE_HOME"] = os.path.join(home, "kh")
    lines = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"protocolVersion": 1, "clientCapabilities": {
                             "fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}}}),
             json.dumps({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                         "params": {"cwd": cwd, "mcpServers": []}})]

    def offered(g):
        return any(o.get("method") == "session/update"
                   and o.get("params", {}).get("update", {}).get("sessionUpdate") == "available_commands_update"
                   for o in g)
    got = stream([os.path.expanduser("~/.kimi-code/bin/kimi"), "acp"], cwd, env, lines, offered, timeout=40)
    names = None
    for o in got:
        upd = o.get("params", {}).get("update", {}) if o.get("method") == "session/update" else {}
        if upd.get("sessionUpdate") == "available_commands_update":
            names = sorted(c.get("name", "")[len("skill:"):] for c in upd.get("availableCommands", [])
                           if c.get("name", "").startswith("skill:"))
    return names


def levels_checks(root):
    """Where codex and kimi read skills from, by where they start."""
    def both(depths):
        return sorted(d + "-" + k for d in depths for k in ("codex", "common"))
    codex_wants = {
        (True, ""): both(["top"]), (True, "pkg"): both(["top", "pkg"]), (True, "pkg/sub"): both(["top", "pkg", "sub"]),
        (False, ""): both(["top"]), (False, "pkg"): both(["pkg"]), (False, "pkg/sub"): both(["sub"]),
    }
    kimi_wants = {
        (True, ""): ["top-common", "top-kimi"], (True, "pkg"): ["top-common", "top-kimi"],
        (True, "pkg/sub"): ["top-common", "top-kimi"],
        (False, ""): ["top-common", "top-kimi"], (False, "pkg"): ["pkg-common", "pkg-kimi"],
        (False, "pkg/sub"): ["sub-common", "sub-kimi"],
    }
    trees = {git: levels_tree(root, "repo" if git else "plain", git) for git in (True, False)}
    if find("codex"):
        wrong = []
        for (git, rel), want in codex_wants.items():
            home, ws = trees[git]
            got = codex_level_names(home, os.path.join(ws, rel) if rel else ws)
            if got != want:
                wrong.append("%s ws/%s: %s" % ("repo" if git else "plain", rel, got))
        check("codex: in a repository, .codex/skills and .agents/skills at every level down to where it starts; "
              "with none, the folder it starts in; never below", not wrong, "; ".join(wrong))
    else:
        print("  SKIP codex is not installed")
    if os.path.exists(os.path.expanduser("~/.kimi-code/bin/kimi")):
        wrong = []
        for (git, rel), want in kimi_wants.items():
            home, ws = trees[git]
            got = kimi_level_names(home, os.path.join(ws, rel) if rel else ws)
            if got != want:
                wrong.append("%s ws/%s: %s" % ("repo" if git else "plain", rel, got))
        check("kimi: in a repository, the root alone; with none, the folder it starts in; never below",
              not wrong, "; ".join(wrong))
    else:
        print("  SKIP kimi is not installed")


def user_line(text, quiet):
    o = {"type": "user", "message": {"role": "user", "content": text},
         "parent_tool_use_id": None, "session_id": ""}
    if quiet:
        o["shouldQuery"] = False
    return json.dumps(o, sort_keys=True)


def reach_checks(root):
    ws = os.path.join(root, "reach-ws")
    sub = os.path.join(ws, "sub")
    skill(os.path.join(sub, ".claude", "skills", "subc"), "subc", "MARKER_SUBC")
    skill(os.path.join(sub, ".agents", "skills", "suba"), "suba", "MARKER_SUBA")
    with open(os.path.join(sub, "CLAUDE.md"), "w") as f:
        f.write("MARKER_SUB_CLAUDEMD\n")
    claude = find("claude")
    if claude:
        home = os.path.join(root, "reach-claude-home")
        cfg = os.path.join(home, ".claude")
        os.makedirs(os.path.join(home, "tmp"), exist_ok=True)
        os.makedirs(cfg, exist_ok=True)
        record = os.path.join(root, "reach-claude-req")
        fake, port = start_fake(record)
        try:
            env = base_env(home, port)
            env["CLAUDE_CONFIG_DIR"] = cfg
            seen = {}
            for label, extra in (("plain", []), ("add-dir", ["--add-dir", sub])):
                argv = [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                        "--verbose", "--model", "claude-opus-5-5"] + extra
                got = stream(argv, ws, env, [json.dumps({"type": "control_request", "request_id": "r1",
                                                        "request": {"subtype": "initialize"}})],
                             lambda g: any(o.get("type") == "control_response" for o in g), timeout=40)
                ans = next((o["response"].get("response", {}) for o in got
                            if o.get("type") == "control_response" and "response" in o), {})
                listed = "subc" in [c.get("name") for c in ans.get("commands", [])]
                before = len(requests(record))
                stream(argv, ws, env, [user_line("/subc", True), user_line("do X " + label, False)],
                       lambda g: sum(1 for o in g if o.get("type") == "result") >= 2, timeout=90)
                bodies = [json.dumps(r.get("body", {})) for r in requests(record)[before:]
                          if r.get("path", "").split("?")[0].endswith("/messages")]
                turn = [b for b in bodies if ("do X " + label) in b]
                seen[label] = (listed, any("MARKER_SUBC" in b for b in turn),
                               any("MARKER_SUB_CLAUDEMD" in b for b in turn))
            check("claude: a subfolder's skill is not listed from a session above it, and its quiet /name loads nothing",
                  seen["plain"][0] is False and seen["plain"][1] is False, str(seen))
            check("claude: --add-dir <subfolder> lists it and the quiet load puts its text in the turn's request",
                  seen["add-dir"][0] and seen["add-dir"][1], str(seen))
            check("…and does not send the subfolder's CLAUDE.md along", not seen["add-dir"][2], str(seen))
        finally:
            stop(fake)
    else:
        print("  SKIP claude is not installed")
    codex = find("codex")
    if codex:
        chome_root = os.path.join(root, "reach-codex-home")
        chome = os.path.join(chome_root, ".codex")
        os.makedirs(os.path.join(chome_root, "tmp"), exist_ok=True)
        os.makedirs(chome, exist_ok=True)
        record = os.path.join(root, "reach-codex-req")
        fake, port = start_fake(record)
        try:
            with open(os.path.join(chome, "config.toml"), "w") as f:
                f.write('model_provider = "fake"\nmodel = "gpt-5.5"\n\n[model_providers.fake]\nname = "fake"\n'
                        'base_url = "http://127.0.0.1:%d"\nwire_api = "responses"\nrequires_openai_auth = false\n' % port)
            env = base_env(chome_root, port)
            env["CODEX_HOME"] = chome
            env["PATH"] = os.pathsep.join(SEARCH + ["/bin", "/usr/sbin", "/sbin"])
            path = os.path.realpath(os.path.join(sub, ".agents", "skills", "suba", "SKILL.md"))
            loaded = []
            for extra in ([], ["--add-dir", sub]):
                before = len(requests(record))
                subprocess.run([codex, "exec", "--json", "--skip-git-repo-check"] + extra
                               + ["[$suba](%s)\n\ndo X reach" % path],
                               cwd=ws, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
                bodies = [json.dumps(r.get("body", {})) for r in requests(record)[before:]
                          if r.get("path", "").split("?")[0].endswith("/responses")]
                loaded.append((len(bodies), any("MARKER_SUBA" in b for b in bodies)))
            check("codex exec: a mention of a subfolder's skill loads nothing, with or without --add-dir",
                  all(n > 0 and not hit for n, hit in loaded), str(loaded))
        finally:
            stop(fake)
    else:
        print("  SKIP codex is not installed")


class _Peer:
    def __init__(self, argv, cwd, env):
        self.p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def send(self, o):
        self.p.stdin.write(json.dumps(o) + "\n")
        self.p.stdin.flush()

    def wait(self, pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if not select.select([self.p.stdout], [], [], 0.5)[0]:
                if self.p.poll() is not None:
                    return None
                continue
            line = self.p.stdout.readline()
            if not line:
                return None
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if pred(o):
                return o
        return None

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.p.kill()


def compaction_checks(root):
    codex = find("codex")
    if codex:
        proj = os.path.join(root, "compact-codex-proj")
        os.makedirs(proj, exist_ok=True)
        skill(os.path.join(proj, ".codex", "skills", "alpha"), "alpha", "MARKER_CX_KEEP")
        chome_root = os.path.join(root, "compact-codex-home")
        chome = os.path.join(chome_root, ".codex")
        os.makedirs(os.path.join(chome_root, "tmp"), exist_ok=True)
        os.makedirs(chome, exist_ok=True)
        record = os.path.join(root, "compact-codex-req")
        fake, port = start_fake(record)
        try:
            with open(os.path.join(chome, "config.toml"), "w") as f:
                f.write('model_provider = "fake"\nmodel = "gpt-5.5"\n\n[model_providers.fake]\nname = "fake"\n'
                        'base_url = "http://127.0.0.1:%d"\nwire_api = "responses"\nrequires_openai_auth = false\n' % port)
            env = base_env(chome_root, port)
            env["CODEX_HOME"] = chome
            env["PATH"] = os.pathsep.join(SEARCH + ["/bin", "/usr/sbin", "/sbin"])
            path = os.path.realpath(os.path.join(proj, ".codex", "skills", "alpha", "SKILL.md"))
            peer = _Peer([codex, "app-server"], proj, env)
            peer.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": {"clientInfo": {"name": "sipai-harness", "version": "1"},
                                  "capabilities": {"experimentalApi": True}}})
            peer.wait(lambda o: o.get("id") == 1, 30)
            peer.send({"jsonrpc": "2.0", "method": "initialized"})
            peer.send({"jsonrpc": "2.0", "id": 2, "method": "thread/start",
                       "params": {"cwd": proj, "approvalPolicy": "never", "sandbox": "read-only"}})
            thread = (((peer.wait(lambda o: o.get("id") == 2, 30) or {}).get("result") or {}).get("thread") or {}).get("id")

            def turn(text, rid):
                before = len(requests(record))
                peer.send({"jsonrpc": "2.0", "id": rid, "method": "turn/start",
                           "params": {"threadId": thread, "input": [{"type": "text", "text": text}]}})
                ans = peer.wait(lambda o: o.get("id") == rid, 30) or {}
                tid = ((ans.get("result") or {}).get("turn") or {}).get("id")
                peer.wait(lambda o: o.get("method") == "turn/completed"
                          and ((o.get("params") or {}).get("turn") or {}).get("id") == tid, 90)
                time.sleep(0.5)
                return [json.dumps(r.get("body", {})) for r in requests(record)[before:]]
            first = turn("[$alpha](%s)\n\nfirst turn" % path, 3)
            second = turn("second turn", 4)
            peer.send({"jsonrpc": "2.0", "id": 5, "method": "thread/compact/start", "params": {"threadId": thread}})
            peer.wait(lambda o: o.get("id") == 5, 30)
            peer.wait(lambda o: o.get("method") == "turn/completed", 90)
            time.sleep(1)
            third = [b for b in turn("third turn after compaction", 6) if "third turn after compaction" in b]
            peer.close()
            check("codex: a mentioned skill stays in the turns that follow",
                  any("MARKER_CX_KEEP" in b for b in first) and any("MARKER_CX_KEEP" in b for b in second))
            check("codex: after a compaction the next turn carries the user's words, not the skill (codex drops it)",
                  bool(third) and not any("MARKER_CX_KEEP" in b for b in third)
                  and any("first turn" in b for b in third), "%d requests" % len(third))
        finally:
            stop(fake)
    else:
        print("  SKIP codex is not installed")
    kimi = find("kimi") or os.path.expanduser("~/.kimi-code/bin/kimi")
    if kimi and os.path.exists(kimi):
        proj = os.path.join(root, "compact-kimi-proj")
        os.makedirs(proj, exist_ok=True)
        skill(os.path.join(proj, ".kimi-code", "skills", "alpha"), "alpha", "MARKER_K_KEEP")
        khome = os.path.join(root, "compact-kimi-home")
        os.makedirs(khome, exist_ok=True)
        osh = os.path.join(root, "compact-kimi-os")
        os.makedirs(os.path.join(osh, "tmp"), exist_ok=True)
        record = os.path.join(root, "compact-kimi-req")
        fake, port = start_fake(record)
        try:
            with open(os.path.join(khome, "config.toml"), "w") as f:
                f.write('default_model = "fake/fake-model"\n\n[providers.fake]\nbase_url = "http://127.0.0.1:%d/v1"\n'
                        'type = "openai"\napi_key = "junk"\n\n[models."fake/fake-model"]\nprovider = "fake"\n'
                        'model = "fake-model"\nmax_context_size = 262144\ncapabilities = [ "tool_use" ]\n' % port)
            env = base_env(osh, port)
            env["KIMI_CODE_HOME"] = khome
            peer = _Peer([kimi, "acp"], proj, env)
            peer.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": {"protocolVersion": 1,
                                  "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False},
                                                         "terminal": False}}})
            peer.wait(lambda o: o.get("id") == 1, 30)
            peer.send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": proj, "mcpServers": []}})
            sid = ((peer.wait(lambda o: o.get("id") == 2, 40) or {}).get("result") or {}).get("sessionId")
            rid = [10]

            def prompt(text):
                rid[0] += 1
                before = len(requests(record))
                peer.send({"jsonrpc": "2.0", "id": rid[0], "method": "session/prompt",
                           "params": {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}})
                peer.wait(lambda o: o.get("id") == rid[0], 90)
                time.sleep(0.5)
                return [json.dumps(r.get("body", {})) for r in requests(record)[before:]
                        if "chat/completions" in r.get("path", "")]
            loaded = prompt("/skill:alpha please do the thing\nand a second line")
            prompt("/compact")
            time.sleep(3)
            after = [b for b in prompt("after compaction") if "after compaction" in b]
            peer.close()
            check("kimi: /skill:name and words is ONE request holding the skill and the words, a second line included",
                  len([b for b in loaded if "MARKER_K_KEEP" in b and "please do the thing" in b
                       and "and a second line" in b]) == 1,
                  "%d requests" % len(loaded))
            check("kimi: after /compact the next turn still carries the activated skill (kimi keeps it)",
                  bool(after) and any("MARKER_K_KEEP" in b for b in after), "%d requests" % len(after))

            def compactions(session):
                out = []
                for dp, _, files in os.walk(os.path.join(khome, "sessions")):
                    if session in dp and dp.endswith(os.path.join("agents", "main")) and "wire.jsonl" in files:
                        with open(os.path.join(dp, "wire.jsonl")) as f:
                            for line in f:
                                try:
                                    o = json.loads(line)
                                except ValueError:
                                    continue
                                if o.get("type") == "context.apply_compaction":
                                    out.append(o)
                return out
            kept = compactions(sid)
            check("kimi: its record of that summary counts the user's messages it kept, and no head — kept whole",
                  len(kept) == 1 and isinstance(kept[0].get("keptUserMessageCount"), int)
                  and "keptHeadUserMessageCount" not in kept[0] and kept[0].get("legacyTail") is not True,
                  json.dumps([{k: v for k, v in c.items() if k.startswith("kept") or k == "legacyTail"} for c in kept]))

            # The NEXT process, which is how SipAI runs every turn: a new
            # `kimi acp` resuming the session, then kimi's headless run.
            def acp():
                p = _Peer([kimi, "acp"], proj, env)
                p.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": 1,
                                   "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False},
                                                          "terminal": False}}})
                p.wait(lambda o: o.get("id") == 1, 30)
                return p
            peer = acp()
            peer.send({"jsonrpc": "2.0", "id": 3, "method": "session/resume",
                       "params": {"sessionId": sid, "cwd": proj, "mcpServers": []}})
            peer.wait(lambda o: o.get("id") == 3, 40)
            resumed = [b for b in prompt("in a new acp process") if "in a new acp process" in b]
            peer.close()
            before = len(requests(record))
            subprocess.run([kimi, "--prompt", "in the headless run", "--output-format", "stream-json",
                            "--session", sid], cwd=proj, env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=120)
            headless = [json.dumps(r.get("body", {})) for r in requests(record)[before:]
                        if "chat/completions" in r.get("path", "")]
            headless = [b for b in headless if "in the headless run" in b]
            check("kimi: …in the next process too — a new `kimi acp` resuming the session, and its headless run",
                  any("MARKER_K_KEEP" in b for b in resumed) and any("MARKER_K_KEEP" in b for b in headless),
                  "%d acp, %d headless" % (len(resumed), len(headless)))

            # Past kimi's budget for the user's own messages (20,000
            # tokens of them): a long skill loaded FIRST is cut short, and
            # the record counts the head it kept.
            long_dir = os.path.join(proj, ".kimi-code", "skills", "long")
            os.makedirs(long_dir, exist_ok=True)
            filler = "\n".join("Rule %04d: keep the ledger balanced and say so plainly." % i for i in range(220))
            with open(os.path.join(long_dir, "SKILL.md"), "w") as f:
                f.write("---\nname: long\ndescription: A long fixture skill.\n---\n\nLONG_SKILL_START\n%s\nLONG_SKILL_END\n"
                        % filler)
            peer = acp()
            peer.send({"jsonrpc": "2.0", "id": 4, "method": "session/new", "params": {"cwd": proj, "mcpServers": []}})
            sid = ((peer.wait(lambda o: o.get("id") == 4, 40) or {}).get("result") or {}).get("sessionId")
            whole = prompt("/skill:long go")
            for i in range(9):
                prompt(("LONGMSG_%d " % i) + ("lorem ipsum dolor sit amet " * 370))
            prompt("/compact")
            time.sleep(4)
            cut = [b for b in prompt("after the long one") if "after the long one" in b]
            peer.close()
            trimmed = compactions(sid)
            check("kimi: past its budget for the user's messages a long skill loaded first comes back cut short",
                  any("LONG_SKILL_START" in b and "LONG_SKILL_END" in b for b in whole)
                  and bool(cut) and not any("LONG_SKILL_END" in b for b in cut),
                  "%d loaded, %d after" % (len(whole), len(cut)))
            check("kimi: …and its record of that summary counts a head — the mark SipAI sends the skill again on",
                  len(trimmed) == 1 and isinstance(trimmed[0].get("keptHeadUserMessageCount"), int),
                  json.dumps([{k: v for k, v in c.items() if k.startswith("kept")} for c in trimmed]))
        finally:
            stop(fake)
    else:
        print("  SKIP kimi is not installed")


def load_checks(root):
    claude = find("claude")
    if not claude:
        print("  SKIP claude is not installed")
        return
    ws = os.path.join(root, "loadcheck-ws")
    skill(os.path.join(ws, ".claude", "skills", "known"), "known", "MARKER_LOADCHECK")
    home = os.path.join(root, "loadcheck-home")
    cfg = os.path.join(home, ".claude")
    os.makedirs(os.path.join(home, "tmp"), exist_ok=True)
    os.makedirs(cfg, exist_ok=True)
    record = os.path.join(root, "loadcheck-req")
    fake, port = start_fake(record)
    try:
        env = base_env(home, port)
        env["CLAUDE_CONFIG_DIR"] = cfg
        argv = [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                "--verbose", "--model", "claude-opus-5-5"]
        got = stream(argv, ws, env,
                     [user_line("/known", True), user_line("/sipai-no-such-skill", True), user_line("do X", False)],
                     lambda g: sum(1 for o in g if o.get("type") == "result") >= 3, timeout=90)
        inits = [o for o in got if o.get("type") == "system" and o.get("subtype") == "init"]
        results = [o for o in got if o.get("type") == "result"]
        listed = (inits[0].get("slash_commands") if inits else None) or []
        check("claude: a turn's init lists the session's commands — the folder's skill, and no name it does not have",
              "known" in listed and "sipai-no-such-skill" not in listed, str(listed)[:160])
        check("claude: a skill message that ran a command says so on its result; one for an unknown name carries no such key",
              len(results) == 3 and [r.get("num_turns") for r in results[:2]] == [0, 0]
              and bool(results[0].get("local_command")) and "local_command" not in results[1],
              json.dumps([{k: r.get(k) for k in ("num_turns", "local_command")} for r in results]))
        bodies = [json.dumps(r.get("body", {})) for r in requests(record)
                  if r.get("path", "").split("?")[0].endswith("/messages")]
        turn = [b for b in bodies if "do X" in b]
        check("claude: …and that name reached the model as words, beside the skill that did load",
              any("MARKER_LOADCHECK" in b and "/sipai-no-such-skill" in b for b in turn), "%d requests" % len(turn))
    finally:
        stop(fake)


def claude_name_checks(root):
    """The names claude offers a skill under (ClaudeSkillNames): a folder
    name holding a hidden or direction-changing character, a blank other
    than a space (a space at either end or doubled included), a stray
    accent mark, < or > is not offered, while an emoji's own selector or
    joiner and a non-joiner inside an Arabic word are; such a name: gives
    way to the folder's; a subfolder's namesake handed with a RELATIVE
    --add-dir is offered as <subfolder>:<name> and loads by that name.
    Token-free: claude's own listing and a quiet skill message, no model
    call."""
    claude = find("claude")
    if not claude:
        print("  SKIP claude is not installed")
        return
    home = os.path.join(root, "names-home")
    cfg = os.path.join(home, ".claude")
    proj = os.path.join(root, "names-proj")
    for d in (os.path.join(home, "tmp"), os.path.join(cfg, "skills"), proj):
        os.makedirs(d, exist_ok=True)
    subprocess.run(["git", "init", "-q", proj], check=False)
    refused = {"angle": "a<b", "zero-width": "zw\u200bx", "bidi": "b\u202ex", "no-break": "n\u00a0x",
               "hangul-filler": "h\u3164x", "variation": "v\ufe0fx", "private-use": "p\ue000x",
               "leading-space": " lead", "double-space": "dou  ble", "leading-colon": ":lead",
               "bare-keycap": "1\u20e3x", "leading-mark": "\u0301leadmark",
               "joiner-before-text": "he\u2764\ufe0f\u200dx"}
    offered = {"space": "sp ace", "accent": "caf\u00e9", "heart-vs16": "he\u2764\ufe0fx",
               "rgi-keycap": "1\ufe0f\u20e3x", "zwj-family": "fam\U0001f468\u200d\U0001f469\u200d\U0001f467x",
               "persian-zwnj": "\u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645", "colon-inside": "a:b"}
    for name in list(refused.values()) + list(offered.values()):
        skill(os.path.join(cfg, "skills", name), name, "MARKER_NAME")
    skill(os.path.join(cfg, "skills", "clean-folder"), "dirty\u202ename", "MARKER_DIRTY")
    skill(os.path.join(proj, ".claude", "skills", "review"), "review", "MARKER_OWN_REVIEW")
    skill(os.path.join(proj, "packages", "web", ".claude", "skills", "review"), "review", "MARKER_SUB_REVIEW")
    record = os.path.join(root, "names-requests")
    fake, port = start_fake(record)
    try:
        env = base_env(home, port)
        env["CLAUDE_CONFIG_DIR"] = cfg
        argv = [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        listing = [json.dumps({"type": "control_request", "request_id": "n-init",
                               "request": {"subtype": "initialize"}})]
        def answered(got):
            return any(o.get("type") == "control_response" for o in got)
        got = stream(argv + ["--add-dir", "packages/web"], proj, env, listing, answered, timeout=40)
        names = [c.get("name") for o in got if o.get("type") == "control_response"
                 for c in o.get("response", {}).get("response", {}).get("commands", [])]
        check("claude offers no skill under a folder name with a hidden or direction-changing character, a blank other than a space, < or >",
              not any(n in names for n in refused.values()),
              ", ".join(k for k, n in refused.items() if n in names))
        check("…and does offer one with a plain space, an accent, an emoji with its selector, a keycap, a joined emoji, a non-joiner inside an Arabic word or a colon inside",
              all(n in names for n in offered.values()),
              ", ".join(k for k, n in offered.items() if n not in names))
        check("…a name: it ignores gives way to the folder's name", "clean-folder" in names and "dirty\u202ename" not in names)
        check("claude offers a subfolder's namesake as <subfolder>:<name>, the subfolder as --add-dir was handed it",
              "packages/web:review" in names and "review" in names, str([n for n in names if n and "review" in n]))
        quiet = [json.dumps({"type": "user", "message": {"role": "user", "content": "/packages/web:review"},
                             "parent_tool_use_id": None, "session_id": "", "shouldQuery": False})]
        def ended(got):
            return any(o.get("type") == "result" for o in got)
        got = stream(argv + ["--add-dir", "packages/web"], proj, env, quiet, ended, timeout=60)
        results = [o for o in got if o.get("type") == "result"]
        check("…and a quiet load by that name runs it",
              bool(results) and results[0].get("num_turns") == 0 and bool(results[0].get("local_command")),
              json.dumps([{k: r.get(k) for k in ("num_turns", "local_command")} for r in results]))
    finally:
        stop(fake)


def main():
    root = os.path.realpath(tempfile.mkdtemp(prefix="sipai-skills-live-"))
    try:
        print("\nLive: claude")
        claude_checks(root)
        print("\nLive: codex")
        codex_checks(root)
        print("\nLive: what each agent needs of a SKILL.md")
        format_checks(root)
        print("\nLive: the folders each agent reads, by where it starts")
        levels_checks(root)
        print("\nLive: a subfolder's skill, from a session started above it")
        reach_checks(root)
        print("\nLive: a loaded skill after a compaction")
        compaction_checks(root)
        print("\nLive: a load that did not happen, in claude's own stream")
        load_checks(root)
        print("\nLive: the names claude offers a skill under")
        claude_name_checks(root)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("\n%d/%d live checks passed" % (passed, passed + failed))
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
