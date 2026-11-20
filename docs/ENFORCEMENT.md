# Hybrid Enforcement (v1.0.0)

Enforcement is the third subsystem, separate from the other two:

| Subsystem | Answers | Lives in |
|-----------|---------|----------|
| Detection | What happened? | Modules |
| Evidence and risk | How worried should we be? | `Intelligence/` |
| Enforcement | What do we do about it? | `Enforcement/` |

Enforcement reads risk bands. It never detects anything, and modules never punish
anyone: they only ask enforcement questions such as "is this player restricted for
Economy?".

> **Before going live, run in shadow mode.** Set
> `Enforcement = { ShadowMode = true }` and ACF makes every decision and writes every
> audit entry, but applies nothing. Watch `ACF:GetAuditLog()` and the cases on real
> servers, tune severities and bands, then turn shadow mode off.

## Levels

| Level | Name | Effect | Comes from |
|-------|------|--------|------------|
| 0 | Logging | None | Band `Normal` |
| 1 | Monitoring | None (visible in `GetEnforcement`) | Band `Increased` |
| 2 | Rejection | Operations tagged with the player's risk groups are refused | Band `Restrict` |
| 3 | Correction | As 2; Movement-tagged players are rubber-banded | Band `Investigation`, which also opens a review case |
| 4 | Restriction | *Every* tagged operation refused for `TemporaryRestrictionSeconds` (600) | Band `EnforcementReview` |
| 5 | Kick | Removed, with an appeal reference | `EnforcementReview`: automatic if corroborated, otherwise a case |
| 6 | Temporary ban | Banned for 24 h, doubling per earlier temporary ban (capped at 720 h) | After `KicksBeforeTempBan` (2) kicks in 7 days |
| 7 | Permanent ban | Banned | After `TempBansBeforePermanentProposal` (2) temporary bans. **Always needs approval by default.** |

Levels 0–4 are automatic in `Hybrid` and `Manual` mode, and they follow the band both
up and down. Level 4 lasts at least its window once entered.

### When does ACF remove a player on its own?

All of these must hold:

1. Mode is `Hybrid`, and the switch for that level is on:
   - `AutoKick` (default on) for a kick;
   - `AutoBan` (default **off**) for a temporary ban;
   - `AutoBan` with `Bans.RequireApprovalForPermanentBan = false` for a permanent ban.
2. The player is in the `EnforcementReview` band (risk ≥ 80).
3. The evidence is **corroborated**:
   - confidence ≥ 0.9, **and**
   - either one non-statistical group ≥ 40, or ≥ 2 groups at ≥ 15 of which at least one
     is non-statistical.

**Statistical evidence alone (`Aim`, `Economy`, `Automation`) never removes anyone
automatically.** Otherwise the decision becomes a case for staff (tested).

After a removal, ACF waits for **new** evidence before removing the player again.
Rejoining with leftover risk only re-applies level 4. A kicked player who keeps
cheating escalates: kick → kick → temporary-ban proposal (tested).

## Wiring it into your game

**Remotes.** Mark operations that should stop for suspicious players:

```lua
ACF:ProtectEvent(Remotes.Trade, {
    Arguments = { V.string({ MaxLength = 32 }) },
    Restrict = "Economy",   -- refused while the player is restricted for Economy
    Handler = doTrade,
})
ACF:ProtectEvent(Remotes.RedeemCode, { Arguments = { ... }, Restrict = true, Handler = ... }) -- any restriction
```

Refusals are reported to the handler as rejection reason `restricted`. They are **not**
counted as suspicious behaviour, since they are ACF's own decision.

**Combat.** Players restricted for `Combat` or `Aim` cannot deal damage: `ValidateAttack`
returns `Reason = "Restricted"`. No code is needed.

**Movement correction.** At level 3 and above, a `Movement`-tagged player is moved back
to their last grounded position without violations when they speed, teleport, fly or
noclip.

- It happens at most once per `Correction.CooldownSeconds` (1 s).
- It only applies within `MaxDistance` (200 studs).
- It never applies across a respawn.
- The correction is authorised, so it is not itself scored as a teleport.

**Your own code:**

```lua
if ACF:IsRestricted(player, "Economy", "Shop.Buy") then return end
```

**Staff notifications.** Cases need people. Forward them however your team works:

```lua
ACF:OnEnforcementCase(function(case)
    if case.Status == "Open" then
        notifyStaff(case.CaseId, case.UserId, case.ProposedLevel, case.Explanation)
    end
end)
```

## Cases: the approval workflow

Cases open in three situations:

- **Action:** a removal is proposed at `EnforcementReview` without being allowed to run
  automatically.
- **Review, on Investigation:** the band *rises* into `Investigation` while the player is
  in the server. Decaying through the band, or having left, opens nothing.
- **Review, on long restriction:** the player has been restricted (level 2+) for
  `Cases.ReviewAfterRestrictedSeconds` (10 min). Restriction neutralises a cheat but also
  stops new evidence, so without this the restricted cheater never reached staff. It
  also guarantees a human look at anyone restricted for long, whatever the reason.
  Added in Phase 8.

| Field | Meaning |
|-------|---------|
| `CaseId` / `AppealRef` | e.g. `ACF-3F9A21C0` |
| `Type` | `Action` (approve a proposed level 5–7) or `Review` (investigate; staff pick the level) |
| `Status` | `Open`, `Approved`, `Rejected`, `Expired` (after 72 h), or `Shadow` (shadow mode, cannot be approved) |
| `Reason`, `Explanation`, `Risk`, `Band` | Why, captured when the case opened |
| `DecidedBy`, `DecidedAt`, `Note`, `ExecutedLevel` | Filled in by the decision |

```lua
for _, case in ACF:GetCases({ Status = "Open" }) do ... end
ACF:ApproveCase(caseId, { By = "Mod_Alice", Note = "watched replay" })     -- proposed level
ACF:ApproveCase(caseId, { By = "Mod_Alice", Level = 6, Hours = 48 })        -- choose the action
ACF:RejectCase(caseId,  { By = "Mod_Bob", Note = "legit, known pro" })
```

Cases live in the server that opened them. Use `OnEnforcementCase` to keep them
elsewhere, for example a Discord webhook or your own DataStore.

## Staff actions and overrides

Every staff action needs `By`, the person acting. It is written to the audit log, and to
the ban record where relevant.

```lua
local appeal = ACF:Kick(player, { By = "Mod", Reason = "..." })
local appeal = ACF:Ban(userId, { By = "Admin", Reason = "...", Hours = 72 }) -- omit Hours: permanent
ACF:Unban(userId, { By = "Admin", Reason = "appeal ACF-3F9A21C0 upheld" })
ACF:SetEnforcementOverride(player, { Exempt = true, By = "Admin", Reason = "dev testing", Seconds = 3600 })
ACF:SetEnforcementOverride(player, { Level = 2, By = "Mod", Reason = "watch" })   -- 0-4 only
ACF:ClearEnforcementOverride(player, { By = "Admin" })
```

- **Bans work for offline players** (by UserId).
- **Staff actions run even in shadow mode.** Shadow mode only governs automatic
  decisions.
- **Exempt players** are never restricted, corrected or removed automatically.

## Bans, expiry, history and appeals

Each user has one record in the DataStore `ACF_Bans_v1`, at key `Bans_<UserId>`:

```lua
{ Version = 1, UserId = 123,
  Active = { Level = 6, AppealRef = "ACF-…", Reason = "...", By = "...", ApprovedBy = "...",
             IssuedAt = unix, ExpiresAt = unix | nil },
  History = { { Type = "Kick" | "TemporaryBan" | "PermanentBan" | "Unban" | "Expired",
                At, AppealRef, Reason, By, ExpiresAt } } }            -- last 20
```

- **Enforced on join.** Every join loads the record. An active ban kicks the player with
  the ban message and the appeal reference. An expired ban moves into history as
  `Expired`.
- **Roblox ban API.** By default bans also call `Players:BanAsync`, universe-wide, with
  the duration. If that call fails, it is logged, and ACF's own record still enforces the
  ban on join (tested). Set `Bans.UseRobloxBanApi = false` where the API is unavailable.
- **Immediate effect.** A ban removes the player at once, even when the DataStore is
  failing. The record write follows, retried up to `MaxAttempts`. If it can never load
  the old record, it writes a fresh one and audits `PersistenceFailed` (tested).
- **Shutdown.** Pending writes are flushed at shutdown, using `BindToClose`.
- **Concurrency.** Records use read-modify-write. Two servers banning the *same* user
  at the *same* moment could lose one history entry; the ban itself still applies.
- **Lookups.** `ACF:LoadEnforcementRecord(userId, callback)` returns the ban and history
  for an appeal lookup.

## Audit log

Every decision and staff action produces an entry:

```
LevelChanged  Rejected  Corrected  Kicked  Banned  Unbanned  BanEnforced  BanExpired
CaseOpened  CaseUpdated  CaseApproved  CaseRejected  CaseExpired
OverrideSet  OverrideCleared  ShadowAction  PersistenceFailed
```

- **Fields.** Entries carry `UserId`, `By`, `Reason`, `AppealRef`, `CaseId`, `Level`,
  `Band`, `Risk`, `Tags` and `Shadow`, as relevant.
- **Repeats.** Repeated rejections or corrections of one user are summarised: one entry
  per minute, with `Count`.
- **Memory.** The last 500 entries are kept in memory (`ACF:GetAuditLog({ UserId?, Type?,
  Since? })`).
- **Keeping it.** Every entry is also published on `ACF.EnforcementAudit`. To keep the log
  permanently, subscribe with `ACF:OnEnforcementAudit(handler)` and store it yourself.

## Modes

| Mode | Levels 0–4 | Kick / bans |
|------|------------|-------------|
| `Hybrid` (default) | Automatic | Automatic only when corroborated and switched on; otherwise cases |
| `Manual` | Automatic | Always cases |
| `Off` | Level 0 only | Staff actions only |

`ShadowMode = true` works with any mode: everything is decided and audited, and nothing
automatic is applied.

## API

| Method | Notes |
|--------|-------|
| `ACF:GetEnforcement(player)` | `{ Level, LevelName, Tags, RestrictedFor, Shadow, Override, OpenCase, Ban, History }` |
| `ACF:IsRestricted(player, tag, operation?)` | `tag` is a risk group, or `true` for any restriction |
| `ACF:Kick`, `ACF:Ban`, `ACF:Unban` | Return the appeal reference (Kick, Ban) |
| `ACF:SetEnforcementOverride`, `ACF:ClearEnforcementOverride` | As above |
| `ACF:GetCases(filter?)`, `ACF:ApproveCase`, `ACF:RejectCase` | Cases |
| `ACF:GetAuditLog(filter?)` | Audit entries |
| `ACF:OnEnforcementCase(handler)`, `ACF:OnEnforcementAudit(handler)` | Subscriptions |
| `ACF:LoadEnforcementRecord(player, callback)` | Stored ban and history |
| `ACF:GetStatus().Enforcement` | Kicks, bans, rejections, corrections, open cases, levels, pending writes |

## Configuration (`Enforcement`)

| Key | Default |
|-----|---------|
| Mode | `Hybrid` |
| AutoKick | true |
| AutoBan | false |
| ShadowMode | false |
| BandLevels | Normal 0, Increased 1, Restrict 2, Investigation 3, EnforcementReview 4 |
| TagMinScore | 15 |
| StatisticalGroups | Aim, Economy, Automation |
| Corroboration.MinConfidence | 0.9 |
| Corroboration.MinIndependentGroups | 2 |
| Corroboration.HardEvidenceMinScore | 40 |
| TemporaryRestrictionSeconds | 600 |
| Correction.Enabled | true |
| Correction.CooldownSeconds | 1 |
| Correction.MaxDistance | 200 |
| Bans.DataStoreName | `ACF_Bans_v1` |
| Bans.CheckOnJoin | true |
| Bans.UseRobloxBanApi | true |
| Bans.TempBanHours | 24 |
| Bans.EscalationFactor | 2 |
| Bans.MaxTempBanHours | 720 |
| Bans.KicksBeforeTempBan | 2 |
| Bans.TempBansBeforePermanentProposal | 2 |
| Bans.RepeatWindowDays | 7 |
| Bans.RequireApprovalForPermanentBan | **true** |
| Bans.MaxHistory | 20 |
| Bans.FlushIntervalSeconds | 5 |
| Bans.MaxAttempts | 5 |
| Cases.MaxOpen | 200 |
| Cases.ExpiryHours | 72 |
| Cases.ReviewAfterRestrictedSeconds | 600 |
| ForgetAfterSeconds | 3600 |
| Audit.MaxEntries | 500 |
| Audit.RepeatIntervalSeconds | 60 |
| Messages.Kick | Contains `{appeal}` |
| Messages.TempBan | Contains `{until}` and `{appeal}` |
| Messages.PermanentBan | Contains `{appeal}` |

## Limits

- **Correction is server-authoritative but coarse.** It moves the character back; it does
  not replay physics. A fast cheater can still gain ground between corrections, but loses
  it on the next one.
- **Restrictions stop at your code.** They only cover tagged remotes, Combat and your own
  `IsRestricted` checks. Untagged remotes are not restricted.
- **Per-server data.** Cases and the in-memory audit log are per server. Ban records
  persist.
- **Memory.** Departed players are forgotten after `ForgetAfterSeconds` (1 h) unless
  something is pending: a write, an override, or a ban record when there is no Store.
  Their record reloads if they return. Measured in a 2-hour churn soak: steady at the
  present players plus the last hour's departures (docs/EVALUATION.md).
