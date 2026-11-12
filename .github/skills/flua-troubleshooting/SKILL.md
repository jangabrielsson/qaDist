---
name: flua-troubleshooting
description: Common flua runtime errors and how to fix them: "online mode requires HC3_URL", HC3 authentication lockout, proxy callbacks not reaching the emulator, busy ports, unknown --%% directive warnings, unknown device types (and the catalog), virtual-time and keep-alive surprises, debugger notes, bridge errors ("lost reference" and friends, with --%%debug:bridge payload dumps), the machine-readable log surface (--log json, --syslog, /flua/systemLog, /debugMessages, flua-mcp), and how to report a flua bug/feature/docs issue upstream. USE FOR: diagnosing flua startup errors, HC3 connection failures, proxy mode issues, Lua runtime errors, cross-platform remedies for macOS and Windows, or filing an issue in the flua repo.
---

# flua Troubleshooting

---

## "online mode requires HC3_URL"

**Error:**

```
flua: error: online mode requires HC3_URL (or HC3_HOST) in the environment — run with --api local or --%%mode:offline for the simulated HC3
```

**Cause:** the QA (or run) is forced ONLINE — `--api remote`, or
`--%%mode:online`/`--%%mode:proxy` in the QA header — but the environment
chain (local `.env` > `~/.env` > shell) has no `HC3_URL`/`HC3_HOST`.

**Fix:**
- Add the credentials to your `.env` (see flua-setup), or
- run offline explicitly: `--api local`, `--%%mode:offline` in the QA
  header, or a `--%%mode:offline` default in a `.flua-directives` file
  (next to the main QA file — the file-based `-D` spelling; see
  flua-setup).

Offline is always the default; online is opt-in (`--api remote`, or
`--%%mode:online|proxy` on the main QA).

## HC3 authentication lockout

flua never retries a 401/403: the HC3 locks itself after 4 failed
credential attempts, so a wrong password aborts the run immediately with
`HC3 authentication failed ... flua exits immediately`. Fix the
`HC3_USER`/`HC3_PASSWORD` in the environment and re-run — you spent exactly
one attempt.

## Proxy callbacks never reach the emulator

Symptom: the QA runs in proxy mode (`--%%mode:proxy`) and the proxy device
exists on the HC3, but tapping the UI does nothing.

**Cause:** the HC3 cannot reach the emulator's callback server. The proxy
posts actions/UI events to `http://<your-ip>:<port>/api/...`.

**Fix:**
- The machine and the HC3 must be on the same network.
- Your firewall must allow the HC3 to reach the port (default 8080;
  override with `FLUA_PROXY_PORT` in the `.env` chain).
- A busy port silently falls back to the next free one — the startup log
  announces the effective ip:port.
- Restarting the emulator re-CONNECTs the proxy to the current ip:port.

## "--%%mode:proxy needs online mode — proxy disabled"

Running a proxy QA without HC3 credentials: flua logs the warning and runs
the QA offline as usual. Set `HC3_URL`/credentials, or drop the directive.

## Busy ports

The `--ui` server and the proxy callback server both fall back to the next
free port (up to 10 attempts) instead of failing — the startup log
announces the effective port.

## unknown --%% directive warnings

```
WARNING flua.config: unknown --%% directive: --%%instnat:true
```

A typo'd directive is parsed anyway (usually with the wrong type) and
warned about at runtime; `flua --check` reports it with the file context.
Fix the spelling.

## "unknown device type" — and where the catalog lives

```
flua: error: unknown device type: 'com.fibaro.light' — did you mean
'com.fibaro.lightSensor', ... (all supported types: flua --tool catalog)
```

A wrong `--%%type` fails QA startup. The error names close matches
(typos) and points at `flua --tool catalog`, which lists every type the
sim supports (`--json` for a JSON array). The full catalog is
`src/flua/devices/devices.json` (176 captures).

## The machine-readable surface (agents and debugging)

- `--log json` — one JSON object per QA log line
  (`{time, level, tag, qaid, msg}`); `--logfile FILE` — a copy of the log
  (ANSI stripped); `--syslog FILE` — structured system events
  (run_start, qa_load, qa_error, crash, ...) as JSON lines.
- `GET /flua/systemLog?last=N` — the same system events over REST
  (flua-only); `GET /debugMessages?last=N` — the QA console buffer.
- `flua --check --json` — static findings as one JSON document.
- The `flua-mcp` server wraps all of this as typed tools (`qa_check`,
  `qa_run` with `summary`/`filter`, `qa_probe` with cursor deltas,
  `docs_read` for the docs) — `docs/mcp.md` is the reference.

## A faulty --%%var is a startup error

`--%%var:name=expr` values are evaluated as Lua expressions — a syntax
error or indexing a nil key fails the QA startup and names the variable:

```
error in --%%var:name: <expr> — <reason>
```

An expression that merely evaluates to nil leaves the variable unset.

## The run exits immediately (online)

Online runs exit when no timers, messages, or connections are pending — a
QA that must keep waiting for HC3 events opts in with `--%%keep-alive:true`
(proxy QAs imply it). A drained offline run also exits; use `--run-for 0`
or `--ui` to stay alive.

## Virtual time surprises

`--speed`/`--instant`/`--step` accelerate the VIRTUAL clock (`os.time()`,
timers). `--run-for` counts virtual seconds. Real-world waits (HTTP,
debugger) still take wall time. `--instant` collapses the timer heap into
one pass — unsafe for `os.time()`-relative delay logic; `--step` is the
fast mode that stays `os.time()`-coherent.

## The debugger freezes time

While mobdebug is paused at a breakpoint, its blocking socket receive
freezes the event loop — virtual time stands still until you resume. This
is by design.

**Attached runs stay fast:** flua's mobdebug uses line hooks only while
stepping or when breakpoints exist — a plain attached run (F5 without
breakpoints, or ^F5) tracks call events only, so hot numeric loops run at
full speed. A set breakpoint re-enables line hooks everywhere, which is
what makes hot loops slow while actively debugging.

**What does VS Code pass flua?** Add `-v` to the launch config's `args`:
flua then logs its full argv and `MOBDEBUG_PORT` — the quickest way to see
whether F5/^F5 attach a debugger, inject a mobdebug bootstrap, or run
plain.

## Windows/macOS notes

- macOS may prompt for firewall permission when the proxy callback server
  (0.0.0.0) starts — allow it for proxy mode to work.
- `.env` files use plain `KEY=value` lines and are re-read when changed.

## Still stuck?

`--%%debug:refreshState=true,api=true,http=true,ws=true` (with `--%%loglength`)
logs events and calls in a short form — usually the fastest way to see
what the emulator sees (ws adds byte-level websocket traffic). Then: `flua --check` (or `--check --json`) for
static issues, the QA's own `self:debug(...)` lines, `--log json` for a
structured log, and `/flua/systemLog` + `/debugMessages` for the engine's
side of the story.

## Reporting issues to the flua repo

When the diagnosis lands in flua itself — emulator behavior, tooling, or
the bundled docs/skills — file an issue upstream at
**github.com/jangabrielsson/flua**. Never patch the flua repo checkout or
the installed package on this machine: many projects here depend on the
installed flua, and the repo is maintained separately — an issue lets the
flua maintainer (agent) land the fix and ship it through the normal
release channel.

**Before filing**
- Confirm on the latest version: `flua --version`. Reports against older
  releases often hit already-fixed behavior — the repo's own feedback
  template says exactly that.
- Check existing issues for duplicates:
  `gh issue list --repo jangabrielsson/flua --state open --search "<symptom>"`
  — search the symptom (e.g. `uiCallbacks`, `apiVersion`, `loopback`),
  not just the error text.

**Pick the template** — the repo offers three
(https://github.com/jangabrielsson/flua/issues/new/choose):
- **Bug report** — a concrete, reproducible defect. Needs the smallest
  Lua file/command/test case that reproduces it, plus OS, Python
  version, flua version or commit, and mode (offline/online/proxy).
- **Feature request** — a focused improvement: the problem/use case, the
  smallest useful behavior, what flags/APIs/HC3 behaviors it could
  affect, alternatives considered.
- **Feedback / experience report** — "here is what I tried, what worked,
  what did not" — the right shape for live-verification rounds (the
  apiVersion/uiCallbacks saga was this kind: one finding per heading,
  expected vs observed, a minimal repro, the suggested change, and things
  you could NOT verify marked as such).

**Report hygiene**
- Minimal repro: the smallest QA plus one command
  (`flua --step --run-for -N qa.lua` shows it deterministically).
- Environment: OS, Python version, `flua --version`, mode.
- Strip credentials: no `HC3_PASSWORD`/tokens/private HC3 details (see
  hc3-write-safety).
- One issue per finding.

**Submitting**
- Web: https://github.com/jangabrielsson/flua/issues/new/choose
- CLI:
  `gh issue create --repo jangabrielsson/flua --template "Bug report" --title "..." --body "..."`
  (template names: `Bug report`, `Feature request`,
  `Feedback / experience report`).

**After filing** — the issue is the end of the local work. The flua agent
takes it from there: fixes, builds a new release, and installs it on this
machine if necessary. Don't install, pin, or patch a flua version locally
in the meantime — many projects on this machine depend on the installed
flua. Once the agent ships, confirm with `flua --version`.

**Doc/skill corrections**: flua's `.github/skills/` is the canonical
source for the skill files this project mirrors (the wheel's
`setup_templates` are synced from there via `scripts/sync-skills.sh`).
File the issue there and let the maintainer land it; once the fix ships,
mirror the wording into this project's `.github/skills/` so the copies
don't drift apart.

## Bridge errors: "lost reference" and friends

Opaque single-line errors in the QA log can come from the Python↔Lua
bridge (lupa's `table_from`). The lupa message is cryptic — the table maps
it to the invariant flua violated:

| lupa error | likely cause | flua invariant |
|---|---|---|
| `lost reference` | payload shared one object across two paths (aliasing), a cycle, or a lapsed lupa object crossed the bridge | engine state and bridge data are JSON trees; no lupa proxies in engine data (`_fresh_copy` + `_plain_key`/`_plain_value` in `bindings.py`) |
| `cannot mix objects from different Lua runtimes` | object passed between runtimes | one runtime per QA |
| `TypeError: cannot convert …` | non-plain type reached `table_from` | `lua_to_python` output is plain JSON types (unconvertible values become nil, Lua-object keys dropped) |

**The loop (no manual instrumentation):**

1. Re-run with `--%%debug:bridge=true` (or `flua -D debug:bridge=true`).
   You get the full Python traceback, a human line naming the endpoint, and
   a dump: `/tmp/flua-bridge-fail-<ts>-<pid>.json` (`.pkl` for
   cycles/non-plain data). A `bridge_error` event also lands in
   `/flua/systemLog`.
2. Load the dump in a fresh `LuaRuntime` and minimize it (ddmin-style) to
   the smallest structure that still raises in `table_from(recursive=True)`
   — that structure is the root cause's shape.
3. Compare against the table → identify the violated invariant.
4. Locate the state write or route that created it, fix it (independent
   copies at the write site), add a regression test. If the fix belongs
   in flua itself, do NOT patch the repo or the installed package on
   this machine — file an upstream issue instead (see "Reporting issues
   to the flua repo" above).

**Hygiene**: don't instrument site-packages on this machine — the
installed flua serves many projects, and edits outlive the session. If a
session did leave edits behind, find the live copy with
`python -m pip show fibaro-flua` and reset it with
`python -m pip install --force-reinstall fibaro-flua==<version>` — and
file the underlying flua problem upstream instead (see "Reporting issues
to the flua repo" above).
