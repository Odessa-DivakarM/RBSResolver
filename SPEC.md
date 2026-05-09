# Odessa.Framework Role-Based Security — Verified Specification

This document describes how the Odessa.Framework's RBS sheet resolves into a
final permission for a given user, target, and field. Every claim has been
verified against the framework source; relevant files are linked inline.

The **RBS Resolver** app implements this exact algorithm, with one
intentional divergence noted at the end.

---

## 1. The sheet

An RBS workbook has five sheets. Three drive permissions:

| Sheet          | Drives                                | What rows mean                                                     |
| -------------- | ------------------------------------- | ------------------------------------------------------------------ |
| `Entities`     | Entity- and field-level access        | `#`-delimited blocks. Header → optional conditions → `Permissions` row → operation rows |
| `Transactions` | Per-transaction access                | Same shape; rows after `Permissions` are transaction names          |
| `Tasks`        | Background task access                | Same shape; rows after `Permissions` are task names                 |
| `Roles`        | Master list, used to validate names   | Single column                                                      |
| `Legend`       | Author documentation only             | Not parsed                                                         |

Within each block:

- **Row 1 (header)**: column 0 is the block identifier. Column 1 is either a
  human-readable label *or* the first role column when its value is `*`. Role
  columns continue until the first blank header cell.
- **Subsequent rows up to `Permissions`**: condition rows. Each cell is a
  `Bool3` value (`blank` / `X` / `Y` / `N`).
- **`Permissions` row**: per-column default permission for the block.
- **Rows after `Permissions`**: operation rows (one per field / transaction /
  task name). Each cell is a permission code.
- **`#`**: end of block.

Loaded by [`Lw.System/Model/Security/Configuration/SecurityConfigLoader.cs`](Lw.System/Model/Security/Configuration/SecurityConfigLoader.cs)
and parsed by [`Lw.System/Model/Security/AbstractPermissionTableParser.cs`](Lw.System/Model/Security/AbstractPermissionTableParser.cs).

### Important: duplicate role columns are legal

Conditional RBS blocks routinely repeat the same role name across multiple
columns, each gated by different condition values. Example:

| identifier | `*` | `Account Manager` | `Account Manager` |
|---|---|---|---|
| `IsActive` | X | Y | N |
| `Permissions` | X | F | R |

Here `Account Manager` has two columns: one that applies when `IsActive=Y`
(grants Full), one when `IsActive=N` (grants Read). The framework preserves
column identity by index — see [`PermissionTable.AddRoleColumn`](Lw.System/Model/Security/PermissionTable.cs)
which uses a `List`, not a name-keyed map.

---

## 2. Permission codes

Defined in [`Lw.System/Model/Security/Permission.cs`](Lw.System/Model/Security/Permission.cs).

| Code | Meaning   |
| ---- | --------- |
| `F`  | Full      |
| `M`  | Modify    |
| `R`  | Read      |
| `N`  | None      |
| `X`  | Undefined |

Order: `X < N < R < M < F`. `MAX(...)` always picks the most permissive across
multiple values.

`Permission.Parse` accepts:

- Single letters (case-insensitive): `f` `m` `r` `n` `x`
- Word forms: `Full` `Modify` `Read` `None` `Undefined`
- Blank → `X`
- Anything else → throws `ArgumentException`

`X` means "fall through" — it never grants anything, but it never blocks the
cascade either. `Permission.Covers(X)` always returns `false`.

---

## 3. Bool3 condition values

Defined in [`Lw.System.Common/DataTypes/Bool3.cs`](Lw.System.Common/DataTypes/Bool3.cs).

`Bool3.Parse` accepts a **different alphabet** than `Permission.Parse`:

| Workbook cell | Bool3 value | Meaning           |
| ------------- | ----------- | ----------------- |
| blank         | `X`         | don't care        |
| `x`           | `X`         | don't care        |
| `y`           | `T`         | true required     |
| `n`           | `F`         | false required    |
| anything else | (throws)    | —                 |

**Note**: the framework's canonical names are `Bool3.T` / `Bool3.F` / `Bool3.X`,
but workbooks use `Y` / `N` / `X` / blank. The parser does the translation.
`T` and `F` are *not* valid workbook tokens.

---

## 4. Site-level default permission

Configured by the global parameter `UserRole.DefaultRolePermission` (default
`Full`, see [`Lw.WebPortal/AppSettings.config.comments`](Lw.WebPortal/AppSettings.config.comments)).

At **login time**, `UserContextHelper.FetchUserRoles` rewrites every role
whose stored `DefaultPermission` is `X` to this site-level value before any
cascade can run:

```csharp
// Lw.Domain.Base.Extension/Helpers/UserContextHelper.cs
var siteLevelPermission = Permission.Parse(
    ComponentContainer.Instance.Resolve<IGlobalExpressionEvaluator>()
        .Eval("Global.UserRole.DefaultRolePermission", Permission.Full.ToString()));

return rolesForUser.Select(r => new UserRole {
    Name = r.Name,
    DefaultPermission = r.DefaultPermission.IsX
        ? siteLevelPermission
        : Permission.Parse(r.DefaultPermission)
});
```

In practice, **step 5 of the cascade never sees `X`** — it sees either the
role's stored value, or the site-level default if the stored value was `X`.

The same pattern is repeated in `RBSDataExtractionTask` and
`RoleProfileReportGeneratorDelegate`.

The master kill switch `Lw.Sys.EnableRoleBasedAccessControl`
([`Config.Instance.EnableRoleBasedAccessControl`](Lw.System)) — when off, all
permission checks return `Full`.

---

## 5. Column matching (decision table)

Implemented in [`Lw.System/Model/Security/PermissionTableExecutor.cs`](Lw.System/Model/Security/PermissionTableExecutor.cs).

Before cascade evaluation, each role column is run through a decision table to
determine whether it applies to the current request. A column matches when
**all** of the following hold:

1. The user "has the role" (for `*` columns: always; for named role columns:
   the user must have that role).
2. For each entity condition row, the column's `Bool3` value is `X` (don't
   care), or the entity's actual value matches (`T`/`F`).

A column that doesn't match is excluded entirely — it contributes neither cell
values nor a cascade. The same role can match through multiple columns
simultaneously (when their conditions are non-conflicting), and each matched
column produces its own cascade result.

---

## 6. Resolution algorithm

Implemented in [`Lw.System/Model/Security/PermissionResultBuilder.cs`](Lw.System/Model/Security/PermissionResultBuilder.cs).

The user's roles are split into two groups by **raw column-name membership**:

- **Group A (configured)**: the role's name appears as at least one column in
  this block. Note this is by name only — even if all of that role's columns
  are filtered out by conditions, the role is still "Group A by name."
- **Group B (unconfigured)**: the role's name does not appear as any column.

### 6.1 Group B parallel — always runs first

```
unconfiguredPerm = MAX over Group B of role.DefaultPermission
                   (after X → site-level substitution at login)
```

Short-circuit:

```
if unconfiguredPerm == Full:
    return Full
```

When this fires, the role-column header has been read (to classify A vs B), but
the Permissions row, operation rows, and per-role cascades are all **skipped**.

### 6.2 Path 1 — at least one matched user-role column

For **each matched column** whose role name is held by the user (production:
`_decisionTable.SelectMany(model, userRoles)`):

| Step | What's read                                           | Where                |
| ---- | ----------------------------------------------------- | -------------------- |
| 1    | Operation row × this column                           | Sheet                |
| 2    | Operation row × **matched `*` column**                | Sheet (skipped if no `*` column matches) |
| 3    | Permissions row × this column                         | Sheet                |
| 4    | Permissions row × **matched `*` column**              | Sheet (same skip rule) |
| 5    | `userRole.DefaultPermission`                          | DB (already resolved at login) |

The cascade stops at the first cell whose value is not `X`. Steps 1 and 2 are
skipped at the entity-block level (no operation specified).

```
roleBasedPerm = MAX over (matched user-role column → cascade-result)
```

Duplicate role columns each contribute their own cascade result and are MAX'd.

### 6.3 Path 2 — no matched user-role columns

This branch runs when:

- Group A is empty (no user role is named in any column), **or**
- Every Group A user-role column is filtered out by conditions.

| Step | What's read                                                                              |
| ---- | ---------------------------------------------------------------------------------------- |
| 1    | If a matched `*` column exists: Operation row × `*` (else `X`)                            |
| 2    | If still `X`: Permissions row × matched `*` column                                       |

```
commonPerm = result of the steps above (or X if no * column matches)
```

### 6.4 Final combine

```
final = MAX(unconfiguredPerm, roleBasedPerm OR commonPerm)
```

If `final == X`, the effective UI verdict is **None**.

---

## 7. UI effects

| Final | Effect                                                         |
| ----- | -------------------------------------------------------------- |
| `F`   | All actions, all fields editable                               |
| `M`   | Open and edit; admin actions hidden                            |
| `R`   | Open form, fields read-only, action buttons hidden             |
| `N`   | Form blocked entirely, entity hidden from grids/menus          |
| `X`   | Treated as `N` at the UI layer                                 |

Field-level `R` on a `Full`-entity form makes that one field read-only inside
an otherwise editable form. Field-level `N` hides/blanks it. Field-level
permissions only matter once entity-level access ≥ `R` (otherwise the form
isn't reachable).

---

## 8. Where this runs

- **At login**: `SecurityService.LoginUser` calls
  `LoadActiveConfiguration()` → reloads `SecurityManager._executorCache` from
  the active RBS file in the DB if its `SystemConfigFileId` differs.
  `UserContextHelper.FetchUserRoles` builds the user's `IUserRole` list and
  performs the `X → site-level` substitution.
- **At request time**: `SecurityManager.SeekEntityPermission()` /
  `SeekTransactionPermission()` / `SeekTaskPermission()` consult
  `_executorCache` and the per-user `UserPermissionCache`.
- **Caching**: per-user permission results live in
  `UserSession.Items<UserPermissionCache>` for the lifetime of the session;
  there is no eviction until logout.
- **Master switch**: `Config.Instance.EnableRoleBasedAccessControl` — when
  off, all checks return `Full` and none of the rest of this document applies.

---

## 9. What RBS does not apply to

Beyond the master switch in §8, the framework has **seven more carve-outs**
that either short-circuit RBS evaluation or quietly remove items from the
workbook before evaluation can ever consider them. Anyone debugging an RBS
issue should know about these — they explain most "why is this not honoured
by my workbook?" moments.

At-a-glance:

| § | Carve-out | Layer |
| - | --------- | ----- |
| 9.1 | `System.User` identity | session |
| 9.2 | Actions with `Category == Helper` | metamodel |
| 9.3 | Entities with `Securable == false` | metamodel |
| 9.4 | `Securable` / `Visible` / `Enabled` filters on attrs, refs, queries, actions, tasks | metamodel |
| 9.5 | Target not present in the workbook → `MAX(role.DefaultPermission)` | runtime |
| 9.6 | Unauthenticated sessions | session |
| 9.7 | `IsDynamic` (conditional) blocks — caching and `model` requirements | runtime |
| 9.8 | The visualizer cannot detect any of these | (note) |

### 9.1 The `System.User` identity is exempt

Defined in [`Lw.System/Model/UserIdentity.cs`](Lw.System/Model/UserIdentity.cs):

```csharp
public const string SystemUserLoginName = "System.User";
...
IsSystemUser = LoginName.Equals(SystemUserIdentity.SystemUserLoginName,
                                StringComparison.OrdinalIgnoreCase);
```

`SecurityManager.IsAuthorizationEnabled`
([`SecurityManager.cs`](Lw.System/Model/Security/SecurityManager.cs)) returns
`false` whenever the current session belongs to a system user:

```csharp
if (userSession.UserIdentity == null || userSession.UserIdentity.IsSystemUser)
    return false;
```

And every public seeker pre-filters on it:

```csharp
if (userRoles == null && !IsAuthorizationEnabled)
    return GenericPermissionResult.PermissionResultFor(Permission.Full);
```

**Consequence.** A session running as `System.User` (case-insensitive) gets
`Permission.Full` for every entity, transaction, and task without ever
consulting the workbook. This is intentional — system users are the framework
running its own internal jobs (scenarios, scheduled tasks, migrations) where
RBS has no business gating execution.

### 9.2 Actions with `Category == Helper` are excluded

Defined in [`Lw.System.Metamodel/Behavior/Actions/ActionCategory.cs`](Lw.System.Metamodel/Behavior/Actions/ActionCategory.cs):

```csharp
public enum ActionCategory
{
    /// A Helper Action encapsulates a unit of business logic.
    /// Other actions can make a call to such Actions.
    Helper,
    ...
}
```

The securables wrapper that builds the per-entity RBS-relevant set explicitly
excludes Helper actions
([`EntitySecurablesWrapper.cs`](Lw.System/Model/Security/Configuration/EntitySecurablesWrapper.cs)):

```csharp
var securableActions = (from action in _entity.Behavior.Actions
    where action.Securable && action.Visible && action.Category != ActionCategory.Helper
    select new SecurableItem(action, true) { ... }).ToHashSet();
```

The same filter is repeated in the Role Profiles report
([`RoleProfileReportGeneratorDelegate.cs`](Lw.Domain.Base.Extension/Components/RoleProfilesReport/RoleProfileReportGeneratorDelegate.cs)):

```csharp
var actionNames = entity.Behavior.Actions
    .Where(x => x.Securable && x.Visible && x.Category != ActionCategory.Helper)
    .Select(x => x.Name).ToList();
```

**Consequence.** A Helper action is invisible to RBS:

- It cannot appear as an operation row in the entity's permission table.
- It is omitted from the Role Profiles report.
- Defining a permission for it in the workbook has no effect.

This is by design — Helper actions are reusable business-logic primitives
called by other actions, not user-facing operations. Their callers carry the
RBS rules; the helpers themselves are plumbing.

### 9.3 Entities with `Securable == false`

`SeekPermission` ([`SecurityManager.cs`](Lw.System/Model/Security/SecurityManager.cs))
short-circuits when the entity is marked non-securable in metamodel:

```csharp
if (userRoles == null && (!MetaContext.Current.EntityModel.Entities[entityName].Securable
                          || !IsAuthorizationEnabled))
    return GenericPermissionResult.PermissionResultFor(Permission.Full);
```

**Consequence.** Any entity whose metamodel has `Securable = false` returns
`Permission.Full` for everyone, regardless of what the workbook says. The
workbook entry is dead config. This is intentional for plumbing entities (lookup
tables, framework-internal records) where RBS doesn't make sense.

### 9.4 Things that never make it into the workbook in the first place

The securables enumerator in
[`EntitySecurablesWrapper.cs`](Lw.System/Model/Security/Configuration/EntitySecurablesWrapper.cs)
filters per-entity contributions before the workbook is even generated:

| Source                     | Filter                                   |
| -------------------------- | ---------------------------------------- |
| Attributes                 | `attribute.Securable && attribute.Visible` |
| References                 | `reference.Securable && reference.Visible` |
| Computed queries           | `query.Securable && query.Visible`        |
| Actions                    | `action.Securable && action.Visible && action.Category != Helper` |
| Projected fields           | `projectedField.Securable`                |

And tasks
([`SecurityConfigWriter.cs`](Lw.System/Model/Security/Configuration/SecurityConfigWriter.cs)):

```csharp
var securableTasks = from task in MetaContext.Current.TaskSet.Tasks
                     where task.Enabled
                     select new SecurableItem(task, ...);
```

**Consequence.** Setting `Securable = false`, `Visible = false`, or
`Enabled = false` on an item makes it invisible to RBS — defining a permission
for it in the workbook has no runtime effect. Often surprising for hidden
fields and disabled jobs.

### 9.5 Targets not present in the workbook → user's role defaults

Inside `SecurityManager.EvaluatePermission`:

```csharp
var userPermissionCache = userRoles == null
    ? UserPermissionCache.Current
    : new UserPermissionCache(userRoles);
if (executor == null) return userPermissionCache.DefaultPermissionResult;
```

And `DefaultPermissionResult` is built once per user
([`UserPermissionCache.cs`](Lw.System/Model/Security/UserPermissionCache.cs)):

```csharp
_defaultPermissionResult = GenericPermissionResult.PermissionResultFor(
    _userRoles.Max(e => e.DefaultPermission));
```

**Consequence — and probably the most important gotcha in the whole spec.**
RBS workbooks are not allow-lists; they are deny-lists layered on top of a
permissive baseline. When an entity / transaction / task is **not in the
workbook at all**, the user gets `MAX(role.DefaultPermission)` over their
roles — which, after the `X → site-level` substitution at login (§4) with the
default `Global.UserRole.DefaultRolePermission = F`, is typically `Full`.

In other words: **the workbook adds restrictions; it does not grant access.**
Removing a target from the workbook to "lock it down" achieves the opposite
effect. To gate something, it must explicitly appear as a block with
restrictive cells.

### 9.6 Unauthenticated sessions

`IsAuthorizationEnabled` requires authentication
([`SecurityManager.cs`](Lw.System/Model/Security/SecurityManager.cs)):

```csharp
return Config.Instance.EnableRoleBasedAccessControl && userSession.IsAuthenticated;
```

**Consequence.** A request that arrives without an authenticated session (and
without explicit `userRoles`) is treated like the system-user case: every
seeker returns `Permission.Full`. RBS does not enforce against anonymous
callers — authentication is assumed to have been enforced upstream by the
host (web portal, API gateway, etc.). If your service surface allows
unauthenticated calls in, RBS is not the layer that will stop them.

### 9.7 Conditional (`IsDynamic`) blocks are not result-cached

`PermissionTable.IsDynamic` is `true` whenever the block has any condition
rows. Two side effects of that:

```csharp
// PermissionResultBuilder.cs
return new PermissionResult(..., cacheable: !_permissionTable.IsDynamic);

// PermissionTableExecutor.cs
if (_permissionTable.IsDynamic && model == null)
    throw new ArgumentNullException("model");
```

**Consequence.** A conditional block re-evaluates for every entity instance;
its result never lands in `UserPermissionCache`. And it cannot be evaluated
without an entity instance (`model`) — block-level lookups against a dynamic
table will throw. The visualizer always passes a synthetic `entityState`, so
this manifests in production as `ArgumentNullException` when caller code
forgets to pass the entity.

### 9.8 The visualizer cannot detect any of these

All of the above are decided at the **caller** or **metamodel** layer, not in
the workbook itself. The visualizer reads the workbook only, so it cannot
warn when:

- The runtime user is `System.User` or unauthenticated (§9.1, §9.6).
- The action being gated has `Category == Helper` (§9.2).
- The entity is `Securable == false` in metamodel (§9.3).
- Fields, references, queries, or tasks were filtered out by `Securable` /
  `Visible` / `Enabled` flags before workbook generation (§9.4).
- The entity / transaction / task is missing from the workbook entirely
  (§9.5) — the user gets their role default permission at runtime, which is
  typically `Full`.

If you suspect an RBS rule is being silently dropped at runtime, walk this
list before assuming the workbook is at fault.

---

## 10. Gotchas

- **`X` does not mean "no opinion."** It means "fall through." If `*` is `R`
  and your role's column is `X`, you get `R`.
- **There is no "deny wins."** Multi-role evaluation is purely additive (`MAX`).
  If any matched column for any of a user's roles grants `Modify`, they get
  `Modify`, regardless of other columns saying `None`.
- **`X` is silently rewritten at login** (per §4). Step 5 of the cascade in
  production never returns `X` — only the role's stored value or the
  site-level default.
- **Conditions are not decoration.** A condition value of `Y` on a column means
  "this column only contributes when the entity's condition field is true."
  Columns that don't match are excluded from the cascade entirely.
- **A role with all-filtered-out columns contributes nothing.** It is *not*
  reclassified into Group B (Group B is by raw name only). The user falls back
  to the matched `*` column for that block.
- **Duplicate role columns each cascade independently.** With two
  `Account Manager` columns matching simultaneously, the cascade runs twice —
  once per column — and the results are `MAX`'d.
- **The `*` column is itself conditional.** If no `*` column matches the entity
  state, steps 2/4 of the cascade are skipped, and the common-only path
  returns `X`.
- **`OperationPermission` ≠ `OperationPermissionOrDefault`.** When the
  requested operation isn't a row in the block,
  `IPermissionResult.OperationPermission` returns `X` while
  `OperationPermissionOrDefault` returns the block-level default. Most callers
  use the latter.
- **Field-level permissions are moot when the entity is `None`.** The user
  can't open the form, so field rules don't apply.

---

## 11. Visualizer divergence

The **RBS Resolver** app matches the algorithm above exactly, with one
deliberate exception: when a workbook contains a value that
`Permission.Parse` or `Bool3.Parse` would reject, the visualizer warns and
coerces to `X` so exploration can continue. Production halts with a
`ParseException` at load time. Banners explicitly call out which parser would
have thrown, so the divergence is never silent.

---

## 12. File index

| Concern                       | File                                                                                                       |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Permission codes & ordering   | [`Lw.System/Model/Security/Permission.cs`](Lw.System/Model/Security/Permission.cs)                          |
| Bool3 condition values        | [`Lw.System.Common/DataTypes/Bool3.cs`](Lw.System.Common/DataTypes/Bool3.cs)                                |
| Sheet → block extraction      | [`Lw.System/Model/Security/Configuration/SecurityConfigLoader.cs`](Lw.System/Model/Security/Configuration/SecurityConfigLoader.cs) |
| Block parsing state machine   | [`Lw.System/Model/Security/AbstractPermissionTableParser.cs`](Lw.System/Model/Security/AbstractPermissionTableParser.cs) |
| In-memory block model         | [`Lw.System/Model/Security/PermissionTable.cs`](Lw.System/Model/Security/PermissionTable.cs)                |
| Role column with conditions   | [`Lw.System/Model/Security/PermissionTableRoleColumn.cs`](Lw.System/Model/Security/PermissionTableRoleColumn.cs) |
| Decision-table column match   | [`Lw.System/Model/Security/PermissionTableExecutor.cs`](Lw.System/Model/Security/PermissionTableExecutor.cs) |
| Cascade + MAX combine         | [`Lw.System/Model/Security/PermissionResultBuilder.cs`](Lw.System/Model/Security/PermissionResultBuilder.cs) |
| Strict vs lenient API         | [`Lw.System/Model/Security/PermissionResult.cs`](Lw.System/Model/Security/PermissionResult.cs)              |
| `X` → site-level substitution | [`Lw.Domain.Base.Extension/Helpers/UserContextHelper.cs`](Lw.Domain.Base.Extension/Helpers/UserContextHelper.cs) |
| Site-level default config     | [`Lw.WebPortal/AppSettings.config.comments`](Lw.WebPortal/AppSettings.config.comments)                      |
| `System.User` exemption       | [`Lw.System/Model/UserIdentity.cs`](Lw.System/Model/UserIdentity.cs), [`Lw.System/Model/Security/SecurityManager.cs`](Lw.System/Model/Security/SecurityManager.cs) |
| Helper-action exclusion       | [`Lw.System.Metamodel/Behavior/Actions/ActionCategory.cs`](Lw.System.Metamodel/Behavior/Actions/ActionCategory.cs), [`Lw.System/Model/Security/Configuration/EntitySecurablesWrapper.cs`](Lw.System/Model/Security/Configuration/EntitySecurablesWrapper.cs) |
| Securable / Visible filters   | [`Lw.System/Model/Security/Configuration/EntitySecurablesWrapper.cs`](Lw.System/Model/Security/Configuration/EntitySecurablesWrapper.cs)                          |
| Disabled-task exclusion       | [`Lw.System/Model/Security/Configuration/SecurityConfigWriter.cs`](Lw.System/Model/Security/Configuration/SecurityConfigWriter.cs)                                |
| Default-grant on missing target | [`Lw.System/Model/Security/UserPermissionCache.cs`](Lw.System/Model/Security/UserPermissionCache.cs)                                                              |
| `IsDynamic` cache & model gating | [`Lw.System/Model/Security/PermissionTable.cs`](Lw.System/Model/Security/PermissionTable.cs), [`Lw.System/Model/Security/PermissionTableExecutor.cs`](Lw.System/Model/Security/PermissionTableExecutor.cs) |
