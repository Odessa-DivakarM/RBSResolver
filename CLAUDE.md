# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RBS Resolver is a **single-file static web app** that implements and visualizes the Odessa Framework's Role-Based Security (RBS) permission-resolution algorithm. A user uploads an RBS `.xlsx` workbook (or loads the built-in demo), and the app shows how the sheet resolves into a final permission for a given user/record/field.

**Everything lives in `index.html`** — inline `<style>`, HTML body, and one inline `<script>` (~3300 lines). There is no build system, no framework, no bundler, no `package.json`, no transpile step. The only external dependency is the XLSX library loaded from a CDN.

`SPEC.md` is the **source of truth for the algorithm** — it documents the exact Odessa resolution rules, verified against the framework source, and lists its two flagged divergences (§11). Treat `evaluate()` as an implementation of SPEC.md; do not change its semantics without reconciling against the spec.

## Commands

- **Run locally:** serve the folder over HTTP (not `file://` — the workbook parser runs in a Web Worker that `importScripts` the CDN XLSX build, which needs http). Matches `.claude/launch.json`:
  ```
  npx http-server . -p 7788
  ```
  then open `http://localhost:7788`. (With the Claude preview tooling, the launch config is named "RBS Resolver".)
- **Build / lint / typecheck:** none exist. It's plain ES + DOM, served as-is.
- **Tests:** no external runner. The suite is *in-app* — open the app and click the **"Run algorithm tests"** link (calls `runTests()`, index.html:2354). It runs ~98 assertions in nine groups (core `evaluate()` cases, the Field View `MAX(rows)==combined` invariant, advisor raise/lower **reachability**, the record-caps-field **UI effect** cases, and two **framework parity** groups: case-insensitive role matching + the filtered-`*` defect, and which same-named block the framework uses; plus the held-back marker check across Matrix, Trace and Field View, and the child-list Add/Remove button rule) and prints `N / N passed` in the right pane. The link forces Trace mode so results are visible from any mode.
  - There is **no per-test CLI selection**. To run/inspect one case, edit the case arrays inside `runTests()`, or call the functions directly in the browser console after loading the demo, e.g. `evaluate(currentBlock, 'Amount', userRoles, siteLevelDefault, entityState)` or `computeFieldCoverageRows(currentBlock, null, userRoles, siteLevelDefault, entityState)`.
- **Deploy:** `powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1` (or the `/deploy` command). It backs up the site, stops the IIS app pool, copies **only four files** — `index.html`, `SPEC.html`, `SPEC.md`, `web.config` — over UNC to `LWPRODAPP-009`, restarts the pool, and health-checks `http://rbsresolver.s009.odessacore.local`. Nothing outside those four files is released.

## The algorithm (core of the app)

`evaluate(block, operationName, userRoles, siteLevel, entityState)` (index.html:1076) is the heart. Key concepts:

- **Permission ordering** `PERM_RANK = { X:0, N:1, R:2, M:3, F:4 }`. Resolution is **MAX — the most permissive wins; there is no "deny".** `X` means "no rule here, keep looking" (not "deny").
- **5-step cascade** per role column (`cascadeForColumn`, index.html:1231), stopping at the first non-`X`: ① field-row × role column, ② field-row × `*` column, ③ Permissions-row × role column, ④ Permissions-row × `*` column, ⑤ role's DB default.
- **Group A** = the user's roles that have a matched column → each runs the cascade; results are MAX'd. **Group B** = roles whose name is in *no* column (names match ignoring case, via `roleNameIn`) → contribute their DB default (`unconfiguredPerm`); a Group-B default of `F` **short-circuits** to Full.
- **The `*` (shared / catch-all) column** is the fallback for any role without its own answer. Critical subtlety: the `*` common path is applied as a standalone contributor **only when there are no Group-A cascades**. When a role *does* hold a matched column, the `*` is consumed inside its cascade and does **not** separately lift column-less roles.
- **X-substitution:** a role whose DB default is `X` is replaced with `siteLevel` (the "GP fallback") before resolving.
- **Conditions** gate columns: each cell is a `Bool3` (`X`/`T`/`F`, parsed from blank/`Y`/`N`). A column whose conditions don't match the `entityState` is excluded entirely (`columnMatches`). Duplicate role columns (same name, different conditions) are legal and tracked by index.

**Data model** (built by `makeBlock` index.html:2254 / parsed by `parseBlocks` index.html:837): a block is `{ identifier, roleColumns:[{name, colIndex, columnIndex, conditionValues}], conditions, permissions:[…], operations:[{name, values:[…]}] }`. Workbooks load off the main thread in a Web Worker (index.html:~1321); `buildDemoWorkbook()` (index.html:2273) provides the demo.

## Three UI modes

`appMode` (`'matrix' | 'single' | 'field'`) switched by `setAppMode()` (index.html:1614). `userRoles` (each `{name, defaultPermission}`) and `siteLevelDefault` are **shared across all three modes**.

- **Role Matrix** (`'matrix'`, `renderMatrix` index.html:2849) — a user's roles → grid of effective permissions across every block. Clicking a cell drills into Trace.
- **Trace** (`'single'`, `renderResults` index.html:1846, narrative in `buildNarrativeTrace`) — a user's roles + one block/field → the full step-by-step cascade explanation.
- **Field View** (`'field'`, `renderFieldMode` index.html:3588) — field-centric. Shows every role's effective permission (`computeFieldCoverageRows` index.html:3258) plus a **Change Advisor** that recommends how to raise/lower a role to an exact target (`computeChangeOptions` index.html:3331 for raising, `fieldLowerLever` index.html:3473 for lowering).

## Invariants & conventions to preserve

- **Field View accuracy:** `MAX(table rows) === evaluate(combined)`. The table must show each role's *in-context* contribution — `computeFieldCoverageRows` strips the `*` value from column-less roles when a column-holder is present. There are automated invariant tests guarding this; run them after touching Field View.
- **Change Advisor levers** carry a structured `apply` descriptor (`{kind:'opCell'|'permCell'|'roleDefault'|'gp'|'addColumn', …}`) alongside the prose. The reachability tests apply these to a cloned block and re-evaluate; keep `apply` in sync with the prose when editing options. Cascade **precedence** matters: a lever only takes effect if no earlier cell intercepts — that's what the "precondition" warnings encode.
- **User-facing copy avoids algorithm jargon.** Use the established vocabulary ("shared `*` rule", "default access level", "this user's effective permission") rather than internal terms (cascade, Group A/B, MAX, step numbers). Deep mechanics go behind a "Why?" expander / the Trace "Technical details" section.
- **Theming: never hard-code a colour.** Every colour (CSS rules *and* inline styles built in JS) goes through a `:root` token; the dark theme is the single `:root[data-theme="dark"]` block that redefines them. A literal `white`/`#hex`/`rgba()` renders wrong in dark mode. A new colour means adding a token to *both* blocks and checking the dark pair meets WCAG AA (4.5:1 text). The theme is resolved by the first `<head>` script (`window.rbsTheme`, `localStorage['rbs-theme']`), which must stay ahead of the stylesheet so there's no flash. That script and the sun/moon `.theme-btn` CSS are **identical copies in `index.html` and `SPEC.html`** (no shared `.js` — deploy ships only four files); change both together.
- **Single source file → edits are line-precise.** Reuse existing helpers rather than re-implementing: `PERM_NAME`, `permChip`, `escapeHtml`, `normCode`, `normBool3`, `columnMatches`, `maxPerm`.
- **Framework-parity helpers** (each mirrors a specific Lw.System rule; see SPEC.md): `fieldUiEffect` / `recordLimitFor` (record caps field — Entities only), `roleNameIn` / `sameRoleName` (case-insensitive role match; `roleNameIn` is cached per block because `evaluate()` calls it in hot loops — never replace it with a per-call scan), `frameworkWouldFail` (filtered-`*` defect), `blockUsage` (which same-named block the framework uses), `uxEffect(sheet, perm)` (on-screen meaning per sheet), `childListAction` / `childEntityLevel` / `combineLimit` (child-list Add/Remove buttons need the child entity at Modify — detected only from a `Create<X>` + `Remove<X>` pair plus an Entities block `X`, and never for a one-to-one child, which has no list: `isOneToOneChild` / `pluralForms`; SPEC.md §7.4). Blocks are selected by **position**, not identifier.
