# Odessa.Framework Role-Based Security — Verified Specification

This document describes how the Odessa.Framework's RBS sheet resolves into a
final permission for a given user, target, and field. Every claim has been
verified against the framework source; relevant files are linked inline.

The **RBS Resolver** app implements this exact algorithm; its two deliberate,
flagged divergences are listed at the end (§11).

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
- **Subsequent rows up to `Permissions`**: condition rows — **Entities sheet
  only**. Each cell is a `Bool3` value (`blank` / `X` / `Y` / `N`). The
  Transactions and Tasks parsers are built with `allowConditions: false`
  (`TransactionPermissionTableParser`, `TaskPermissionTableParser`).
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

1. The request "has the role" of the column. Role names are compared
   **case-insensitively** (`PermissionRequest.HasRole` → `EqualsIgnoreCase`;
   `PermissionResultBuilder` also uses `EqualsIgnoreCase` for the Group A/B split
   and the step-5 role default).
2. For each entity condition row, the column's `Bool3` value is `X` (don't
   care), or the entity's actual value matches (`T`/`F`).

`PermissionTableExecutor.Run` issues **two** requests: a *user request*
(`SelectMany` with the user's roles — the `*` column never matches it, since no
user holds a role named `*`) and, only when the table has a `*` column, a
*common request* (`SelectSingle` with the single role `*`, still subject to the
`*` column's conditions). The common request's result is the "matched `*`
column" used below.

> **Known framework defect — a `*` column switched off by its conditions throws.**
> When the table has a `*` column but none matches the record,
> `DecisionTable.SelectSingle` returns `null`; `PermissionTableExecutor.Run`
> passes it on unchecked and `PermissionResultBuilder` throws
> `NullReferenceException` the first time it needs the common value. That
> happens unless an unconfigured role default of `F` short-circuits, or every
> matched user-role column has a non-`X` value in its Permissions row **and** in
> every operation row (all operations are built in one pass). With no `*`
> column at all, the non-null all-`X` `CommonUserRolePermission.Instance` is
> used and nothing throws. Reproduced against `PermissionTableExecutor`
> directly. The visualizer detects this (`frameworkWouldFail`) and shows a
> warning in Trace, Role Matrix (⚠ on the record pill) and Field View, while
> still showing the value the rules would give.

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
| 2    | Operation row × **matched `*` column**                | Sheet (`X` if the table has no `*` column; throws if it has one but none matches — §5) |
| 3    | Permissions row × this column                         | Sheet                |
| 4    | Permissions row × **matched `*` column**              | Sheet (same rule as step 2) |
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
| 1    | If a matched `*` column exists: Operation row × `*` (no `*` column: `X`; filtered out: throws — §5) |
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

Every UI check is `permission.Covers(desired)`; the screen only asks for `Read`
or `Modify`, so for fields and actions `F` and `M` behave identically.

| Entity-level | Effect                                                                  |
| ------------ | ----------------------------------------------------------------------- |
| `F` / `M`    | Record editable; each field/action then limited by its own value (§7.1) |
| `R`          | Record read-only — fields read-only, actions unusable (see Actions, §7.1) |
| `N` / `X`    | Entity not visible (every field hidden); grids show no columns; entity API read denied |

Whether a form can be opened from a menu or command is mostly decided by the
**Transactions** sheet: `CommandHelper.IsAccessible` → `SeekTransactionPermission`
for transaction, browse and view form commands. The exception is `OpenSite`
with a URL naming a form, which checks this sheet (static block, operation row
`Read` or else the entity default, must cover `Read`).

The only places a search of the source (`Permission.Full`, `IsFull`) finds `F` treated differently from `M`: the Group B short-circuit (§6.1); workflow
work-item filtering (`DomainService.FilterWorkItemsBasedOnRBS` →
`GetAllowedTransactions`, requires `Full` on the Transactions sheet); the Outlook
add-in entity list (`IsPermissionGrantedForAddIn(Permission.Full)`).

The table above is the **entity-level** effect. A field's (or action's) effect
combines the entity-level value with the field-level value — the field can only
make things *more* restrictive than its record, never less.

### 7.1 Combining entity and field

Verified in `Lw.System/Model`:

- `EntityPropertiesProxy.IsVisible  = Visible && entityPerm.Covers(Read)`
- `EntityPropertiesProxy.IsReadOnly = ReadOnly || IsOwnerEntityReadOnly(…) || !entityPerm.Covers(Modify)`
- `FieldPropertiesProxy.IsEnabled   = !entity.IsReadOnly && Enabled && fieldPerm.Covers(Modify)`
- `FieldPropertiesProxy.IsVisible   = entity.IsVisible && Visible && fieldPerm.Covers(Read)`

`entityPerm` is `PermissionResult.DefaultPermission`; `fieldPerm` is
`OperationPermissionOrDefault(field)` (falls back to `DefaultPermission` when the
field has no row). `Permission.Covers(X)` is always false. **Actions use the same
gate**: `ActionContext.IsActionEnabled` returns `FieldProperties(actionName).IsEnabled`.

Both values come from **one** `SeekEntityPermission` call — one `PermissionResult` —
and `PermissionResultBuilder` resolves each of them independently over **all** of the
user's roles (unconfigured-role defaults + every matched column) *before* they are
combined. So the cap uses the user's combined entity-level result and combined
field-level result, never one role column's values.

| Entity-level | Field `F` / `M`       | Field `R`             | Field `N` / `X` |
| ------------ | --------------------- | --------------------- | --------------- |
| `F` / `M`    | editable              | visible, read-only    | hidden          |
| `R`          | **visible, read-only** | visible, read-only    | hidden          |
| `N` / `X`    | hidden                | hidden                | hidden          |

**Actions** follow the same table: an action can be used only where it says
*editable*. How an unusable action looks:

- **Normally hidden, not greyed out.** Every first render uses
  `ActionWidgetHtmlElementProperties.IsVisible = IsParentVisible && IsEnabled`
  (`_ActionWidget.cshtml`, `FormActionBar.cshtml`, the App serializer
  `ActionFieldItem`). Grid buttons are hidden too — on first render
  (`framework.grid.js`, `GridActionItem.IsVisible`) and on refresh
  (`prepareGridActionWidget`).
- **Modern UI** (`UserSession.IsModernized`): a form action that RBS shows (its
  entity and row cover `Read`) but that can't be used can turn **greyed out** —
  but only when the form re-sends its properties, and a refresh re-sends only
  widgets whose state changed (`AbstractMetaFormModel.AppendHtmlPropertiesJson`
  → `HtmlElementProperties.HasChangedFromLastCall`). So an action unusable from
  the start stays hidden; one that becomes unusable while the form is open
  (a conditional block, a behaviour rule) shows greyed
  (`CanActionWidgetDisplayedAsVisibleAndDisabled` → `AnyActionsDisabledAndVisible`;
  `prepareActionWidget` in `framework.uicontrols.js`).
- **Form's own record below `Modify`**: the form model is read-only
  (`AbstractEntryFormModel.IsReadOnly` → `HtmlElementProperties.IsModelReadOnly`),
  so the entity-action helpers (PerformAction / OpenActionForm, workflow and
  interim-save actions, list Create / Remove) return false — hidden in every UI.
  This does not cover an action on a sub-entity (a dotted `PerformAction.Property`,
  whose own record's `R` can grey it in the Modern UI as above), nor buttons that
  run a `Command` or an `ExecuteTransactionAction`, which don't check
  `IsModelReadOnly`. View and browse forms are never read-only models.
- **XAML opt-in**: `PerformAction.AlwaysShowDisabledActionWidget="True"` shows
  the button disabled from the first render in every UI, even on a read-only
  record (`ShouldDisplayDisabledActionWidget`). Not used in Framework or Core
  XAML.

The visualizer can't tell which of these applies, so Trace says an unusable
action is "usually hidden; some screens show it greyed out".

Example (FRWK-25772): Permissions row `X`, role default `X`, site-level `R` → entity
`R`; field row `F` → field value `F`, but the field is **read-only**. The visualizer
keeps showing the true `F` value and flags that the record holds it back (Trace,
Role Matrix 🔒 marker, Field View, CSV `LimitedByRecord` column).

This applies to **Entities-sheet fields and actions only**. Tasks have no field
layer (`SeekTaskPermission().DefaultPermission`).

### 7.2 What can restrict a field further (outside the visualizer)

These can only make a field *more* restricted, never less, and the visualizer
cannot see them — its answer is "per RBS", not the final screen state:

- **Transaction permission** (Transactions sheet). Launching a transaction form
  from the UI checks only the transaction permission
  (`CommandHelper`, `BaseTransactionFormController.ValidateTransactionAccess`); the
  REST API additionally requires the entity-level permission
  (`AuthorizationHelper.IsTransactionPermissionGranted`:
  `entity.Covers(desired) && transaction.Covers(desired)`). Inside any form, the
  entity's fields are still gated by §7.1. The visualizer does not combine sheets.
- **Owner entity read-only** — `IsOwnerEntityReadOnly` walks the owner chain.
- **Behaviour input rules** — `Enabled` / `ReadOnly` / `Visible` set by behaviours.

One exception runs the other way: actions performed on an entity that is **not**
part of the root transaction (nested transactions) skip the RBS and input-rule
check entirely (`ActionContext.IsActionEnabled` returns true when
`!BelongsToRootTransaction`).

### 7.3 Transactions and Tasks

| Value | Transactions sheet | Tasks sheet |
| ----- | ------------------ | ----------- |
| `F`   | All modes open, including Create; also counts for workflow work items | Offered when setting up jobs |
| `M`   | All modes open, including Create; **not** enough for workflow work items | Offered when setting up jobs |
| `R`   | View and Edit open; Create refused | Not offered |
| `N` / `X` | Cannot be opened; not offered in menus | Not offered |

Sources: `CommandHelper.IsAccessible` (Create needs `Modify`, other modes
`Read`), `AbstractTransactionFormModel.RaiseAccessDeniedIfRequired`,
`DomainService.FilterWorkItemsBasedOnRBS` → `GetAllowedTransactions` (`Full`),
`JobTaskConfigQueryables` (tasks need `Modify`).


### 7.4 Child-list Add and Remove buttons

For every child whose `ParentRelation` is `OneToMany` or `OneToOneOptional`,
the parent's behaviour gets two implicit actions, `Create<Child>` and
`Remove<Child>` (`Behavior.RegisterDefaultChildActions`, `Category = Compute`;
an explicitly declared action of the same name takes its place). Both appear as
operation rows in the parent's block.

**Only a `OneToMany` child has a list.** An `EditCollection` can bind only a
`OneToMany` child collection (or an editable object-set query) —
`PropertyParser.EditCollectionFlags = ChildrenOneToMany | EditableObjectSetQuery`;
for any other property the parser throws `MetamodelException`
(`PropertyParser.ParseEditableCollection`). A `OneToOneOptional` child is a
single object member, so it never has a list, an Add button or a Remove button.
Its `Create<Child>` / `Remove<Child>` are ordinary parent actions, gated only by
§7.1 (parent entity and row cover `Modify`); the child's own permission is not
checked.

A `OneToOneMandatory` child has no list either, and no actions at all:
`Behavior.RegisterDefaultChildActions` adds `Create<Child>` / `Remove<Child>`
only for `OneToMany` and `OneToOneOptional`, `AbstractBehavior` adds no `Has…`
condition for it, and `AbstractEntity.RemoveChildEntity` refuses to remove it.
Its parent's block has none of these rows, so there is nothing to gate.

| Relation | Implicit actions | Implicit conditions | List (Add / Remove buttons) |
|---|---|---|---|
| `OneToMany` | `Create<X>`, `Remove<X>` | `Has<Plural>`, `HasNew<Plural>` | yes — also needs the child at `Modify` (below) |
| `OneToOneOptional` | `Create<X>`, `Remove<X>` | `Has<X>` | no — ordinary parent actions (§7.1) |
| `OneToOneMandatory` | none | none | no — nothing to gate |

A `OneToMany` child list's (`EditCollection`) Add / Remove buttons are shown
only when **all** hold:

| # | Check | Source |
|---|---|---|
| 1 | The **child** entity covers `Modify` — a lookup by name, so the child's block without conditions, else the highest role default (§9.7, §9.5) | `GridPanelHelper.IsCreateActionAllowed` / `IsRemoveActionAllowed`; when false the button is not built (`GridActionItem.CreateDefaultActions`) |
| 2 | The parent's `Create<Child>` / `Remove<Child>` action is enabled and visible — parent entity **and** that row cover `Modify` (§7.1) | `GridActionWidgetHtmlElementProperties.IsEnabled` → `FieldProperties("Create" + child)` |
| 3 | `ShowCreateAction` / `ShowRemoveAction` on the collection, and the form model is not read-only | XAML — not visible to the visualizer |

`GridActionItem` sends the button with `IsVisible = IsParentVisible && IsEnabled`,
so a disabled button is hidden. The parent's row can only take the button
away, never grant it. Existing child rows follow the child's own entity-level
value (`R` → read-only rows; `N` / `X` → the grid shows no columns).

**Custom grid buttons are not child-list buttons.** A form can add its own
buttons to a list (`EditCollection.ActionBar` → `GridAction` →
`PerformAction`) — e.g. the Asset form hides Remove (`ShowRemoveAction="False"`)
and shows *Delete* = `DeactivateAssetFeatures` instead. Permission-wise, such a
`PerformAction` / `OpenActionForm` button is gated only by the entity that owns
the action — the form's entity, or the one on the `PerformAction.Property` path,
**not necessarily the list's parent** (in `CollateralAssetDialog` the list is
`Asset.AssetFeatures` but `DeactivateAssetFeatures` belongs to `CollateralAsset`)
— and that action's row (§7.1), plus its XAML `Visible` and the form model not
being read-only (`GridActionWidgetHtmlElementProperties.IsAccessible` →
`AnyActionsVisibleAndEnabled`). The usual non-RBS gates still apply (panel
visibility, behaviour `Enabled` / `Visible`). A grid button that runs a
`Command` is gated like that command (`Command.IsAccessible`: the Transactions
sheet for transaction, browse and view commands, the Entities sheet for
`OpenSite`, no check for other commands — see §7); one that runs an
`ExecuteTransactionAction` by the transaction's `Modify`. Neither checks whether
the form is read-only. The child
entity's permission is **not** checked: with `AssetFeature` at `R`, Add is
hidden but Delete is still shown and enabled. To block it, lower that action's
row on the entity that owns it. The visualizer treats these rows as ordinary
actions — nothing in the workbook ties an action like `DeactivateAssetFeatures`
to the child (only its parameter type in the behaviour and the form's
`SelectionParamFields` do), and guessing from the name would mislabel custom
actions.

**How the visualizer detects it.** A row is treated as a child-list button only
when the block has **both** `Create<X>` and `Remove<X>` rows, the Entities
sheet has a block named `X`, and `X` is not a one-to-one child
(`childListAction`):

- *Custom actions.* Hand-written actions that merely start with `Create` are not
  mistaken for one: in the base framework every explicit `Create<X>` action
  whose `X` is an entity creates a record that is *not* a child of the owning
  entity, and the only explicit `Create<X>`/`Remove<X>` pairs are
  `Category = Helper` (never in the workbook).
- *One-to-one vs one-to-many* (`isOneToOneChild`). The workbook does not store
  the relation, but the implicit conditions differ
  (`AbstractBehavior.AddChildExistsConditions`; member name from
  `Helper.MemberName`): `OneToMany` → `Has<Plural>` and `HasNew<Plural>`;
  `OneToOneOptional` → `Has<X>` only. `X` is one-to-one when the block has
  `Has<X>` and no `HasNew<plural of X>`. Plurals come from
  `Pluralizer.Pluralize` (an English pluralization service); `pluralForms`
  covers the regular forms (`s`, `es`, consonant+`y` → `ies`, `f`/`fe` → `ves`,
  `is` → `es`) plus `Person` / `Child`. Without the `Has…` rows the child is
  treated as `OneToMany`.

Measured on a production workbook (3,066 entity blocks) against the entity
models of `Odessa.Framework` and `Odessa.Framework.Core`: of 1,427 detected
pairs, 1,401 could be checked — all are real parent → child relations (0 false
positives, 0 real children missed), and the one-to-one rule classifies all 92
`OneToOneOptional` and all 1,309 `OneToMany` children correctly. The other 26
pairs involve entities from a layer outside those two repositories. None of the
20 `OneToOneMandatory` children in those models has a `Create<X>`, `Remove<X>`
or `Has<X>` row in its parent's block.
The child's value is computed as the framework looks it up — its block without
conditions, else `MAX(role defaults)` (`childEntityLevel`) — and the result is
shown with the same 🔒 marker as §7.1 in all three views and in the CSV
`LimitedByRecord` column.

Not flagged by the visualizer:

- A child that is missing from the workbook (the framework then uses role
  defaults — usually `Full`). Without a block the pair alone is not treated as
  proof of a child list.
- A one-to-many child whose irregular plural is outside `pluralForms` **and**
  whose parent also has an unrelated `Has<X>` row (for example a reference
  named `X`): it would be read as one-to-one and its child check dropped. Not
  seen in the measured workbook.
- A list bound on an entity that is not its source entity's parent (e.g. a
  grandchild collection bound on the root form): its Create button is hidden
  outright, and its Remove button skips the parent's `Remove<Child>` row — only
  the child's `Modify`, `ShowRemoveAction` and the form not being read-only still
  apply (`GridActionWidgetHtmlElementProperties.IsEnabled`, `return !isCreateAction`).
  On the MVC grid both buttons also need an editable grid that is not a sub-grid
  (`_GridWidget.cshtml`).
- Script-driven child edits (`ManipulationContext`), which check only the
  parent's `Create<Child>` action.

`AbstractEntryFormController.CreateChildEntity` →
`AbstractEntity.PerformAddChildEntityAction` performs no RBS check itself; the
checks above are applied when the form and grid are rendered.

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

**Consequence.** A session or login running as `System.User` (case-insensitive) gets
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
its result never lands in `UserPermissionCache`.

**It is only used when a record is present — a missing record never
throws.** (A filtered-out `*` column does — §5.) `PermissionTableExecutorCache` keeps one *static* and one
*dynamic* executor per entity name (a second block of the same kind replaces
the first). `SecurityManager.SeekPermission` asks for the dynamic one only when
a record is passed (`ExecutorOrDefault(name, type, entity != null)`):

| Lookup | Callers (examples) | Block used |
|---|---|---|
| With a record — `SeekEntityPermission(IEntity)` | form fields and actions (`AbstractEntity.IsPermissionGrantedImpl`); grid cell values with `EnableCellSecurity` | dynamic, else static |
| By name only — `SeekEntityPermission(string)` | grid access and grid columns (`GridPanelHelper`), entity API read, REST transaction check | **static only** |
| Neither block exists | — | role defaults (§9.5) |

So an entity whose only block is conditional is governed by it on forms, but by
the user's role defaults for grids and API reads. The `ArgumentNullException`
guard in `PermissionTableExecutor.Run` is reachable only by calling `Run`
directly with no model; `SecurityManager` never hands a dynamic executor to a
record-less lookup. The visualizer evaluates each block as if a record with the
chosen condition values is open (the form path), and says which lookups use a
block (`blockUsage`): Trace shows a note, and Role Matrix tags the block
*open records only*, *grids / API only*, or *ignored (replaced by a later
block)*. Blocks are selected by position, so both blocks of a same-named pair
are reachable.

Workbook regeneration is stricter: `RbsFileGenerator` builds a dictionary keyed
by block identifier from the reference workbook (`ToDictionary(x => x.Key.Trim(), …)`),
so a reference workbook with two blocks of the same name makes regeneration
throw `ArgumentException`.

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
- **The `*` column is itself conditional.** If the table has a `*` column but
  none matches the entity state, the framework throws `NullReferenceException`
  whenever it needs the shared value (known defect, §5). Only a table with no
  `*` column at all treats the shared value as `X`.
- **`OperationPermission` ≠ `OperationPermissionOrDefault`.** When the
  requested operation isn't a row in the block,
  `IPermissionResult.OperationPermission` returns `X` while
  `OperationPermissionOrDefault` returns the block-level default. Most callers
  use the latter.
- **Field-level permissions are moot when the entity is `None`.** The user
  can't open the form, so field rules don't apply.

---

## 11. Visualizer divergence

The **RBS Resolver** app matches the algorithm above, including case-insensitive
role matching (§5) and the record-caps-field rule (§7.1). It departs from the
framework in exactly two deliberate ways, and both are always flagged on screen:

1. **Unparseable cells.** When a workbook contains a value that
   `Permission.Parse` or `Bool3.Parse` would reject, the visualizer warns and
   coerces it to `X` so exploration can continue. Production halts with a
   `ParseException` at load time. Banners name the parser that would have thrown.
2. **The filtered-`*` defect (§5).** Where the framework throws
   `NullReferenceException`, the visualizer shows the value the rules would give
   and a warning that the live system currently fails for that user and record.

Not modelled (the visualizer says so where relevant): combining sheets
(Transactions × Entities, §7.2), and anything decided outside the workbook (§9).

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
