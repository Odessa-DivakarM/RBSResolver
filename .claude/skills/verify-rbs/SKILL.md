---
name: verify-rbs
description: >-
  Launch the RBS Resolver app over HTTP and run its in-app test + smoke checks
  (the 33-assertion runTests() suite plus a three-mode smoke and a console-error
  check). Use this whenever you need to confirm a change to index.html actually
  works — before deploying, after editing the resolver/advisor/Field-View code,
  when asked to "verify", "smoke test", "run the tests", "check the app still
  works", or to reproduce a UI behaviour. The project's tests are NOT a CLI: they
  live behind an in-app link and the app must be served over HTTP, so reach for
  this skill instead of trying to run a test command or opening the file directly.
---

# Verify RBS Resolver

RBS Resolver is a single static `index.html` (see the repo's `CLAUDE.md`). It has
**no CLI test runner** — its test suite is the in-app `runTests()` function,
reachable from the **"Run algorithm tests"** link, and it must run **in a real
browser served over HTTP** (the workbook parser is a Web Worker that
`importScripts` a CDN build; `file://` and Node both fail). This skill captures
the launch-and-check recipe so verification is one repeatable step instead of a
cold start every time.

## What "verified" means here

A change passes verification only when all three hold:

1. **`runTests()` reports `33 / 33 passed`** (or `N / N` — every group green). This
   is the project's real regression suite: core `evaluate()` cases, the Field View
   `MAX(rows) == combined` invariant, and the advisor raise/lower reachability
   tests.
2. **The three modes smoke clean** — Role Matrix, Trace, and Field View each
   render without throwing.
3. **The browser console has no errors.** A green test count with a console
   exception is still a FAIL — capture the error.

Running the tests is necessary but not sufficient: also drive whatever the change
actually touched (the specific mode/field/advisor path), because the suite uses
fixtures, not the live UI state.

## Get a handle (launch over HTTP)

Use whichever is available, in this order:

- **Claude Code preview tooling** (preferred): start the server from
  `.claude/launch.json` (config name **"RBS Resolver"**, port 7788) and drive it
  with the preview eval/screenshot tools. This is what gives you a console you can
  read and a DOM you can query.
- **Plain http-server**: `npx http-server . -p 7788`, then open
  `http://localhost:7788` in a browser you can script (Playwright, Chrome MCP,
  etc.).

Do **not** open `index.html` as a file and do **not** try to `require`/`import`
the script in Node — the worker + CDN dependency mean neither reflects real
behaviour.

## Run the checks

After the page is loaded, run this in the page context (it loads the demo
workbook, runs the suite, smokes the three modes, and reports). Adapt the
mechanism to your driver (e.g. the preview `eval` tool); the script is the part
that matters:

```js
(function () {
  const r = {};
  // 1) In-app test suite (switches to Trace mode and renders results in #output)
  document.getElementById('loadDemo').click();
  document.getElementById('runTests').click();
  r.tests = document.querySelector('#output .summary')?.textContent || 'no summary';
  r.testFails = Array.from(document.querySelectorAll('#output .fail'))
    .map(d => d.textContent).filter(t => t.startsWith('FAIL'));

  // 2) Three-mode smoke — each should render its own output container
  setAppMode('matrix'); r.matrix = document.getElementById('matrixOutput').children.length > 0;
  setAppMode('single'); document.getElementById('evaluate').click();
  r.trace = !!document.querySelector('#output .final-card, #output .empty-state');
  setAppMode('field'); r.field = document.getElementById('fieldOutput').style.display !== 'none';

  return JSON.stringify(r, null, 1);
})()
```

Then **read the console** for errors (preview `console_logs` at level `error`, or
the browser devtools). If the change touched a specific surface, drive that too —
e.g. for a Field View advisor change, set roles + a target permission and confirm
the recommended/lower levers read correctly; for a Trace change, evaluate a
field and read the narrative.

## Report

Keep it short and evidence-first:

```
Verify RBS Resolver — <one line: what was checked>
- Tests:   33 / 33 passed   (or list each FAIL line)
- Modes:   Role Matrix ✓  Trace ✓  Field View ✓
- Console: clean   (or paste the error)
- Drove:   <the specific change path you exercised, + what you observed>
Verdict: PASS | FAIL
```

A FAIL must include the captured evidence (the failing assertion text or the
console error), not a paraphrase.

## Notes

- The screenshot tool in some environments times out on this app; that's a
  harness quirk, not a failure. Fall back to reading the rendered DOM text /
  computed styles as evidence.
- This skill verifies; it does not deploy. Deploy is the separate `deploy`
  command, and only `index.html`, `SPEC.html`, `SPEC.md`, `web.config` ship.
