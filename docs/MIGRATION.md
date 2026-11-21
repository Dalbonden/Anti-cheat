# Upgrading ACF

How to move a game from one ACF version to another. Each section lists what changed in
behaviour, what you must do, and what you can ignore.

**General rules:**

- **Configuration keys are only ever added**, never removed or renamed. A configuration
  that worked on an older version still loads. Unknown keys fail `Initialize` with a
  "did you mean" suggestion.
- **Stored data is versioned.** Ban records and risk history carry `Version = 1`. Newer
  builds read older records, and records are never rewritten in a format an older build
  can't read without saying so here.
- **Removals are announced.** From 1.0.0, anything removed is deprecated for at least one
  minor version first and listed here (Semantic Versioning, RELEASING.md).

## Upgrade procedure (any version)

1. **Replace the folders.** Swap `ServerScriptService.ACF` and `ReplicatedStorage.ACFShared`,
   plus `StarterPlayerScripts.ACFTelemetry` if you use telemetry, with the new build. Use
   the release model `ACF-<version>.rbxm` (RELEASING.md) or your Rojo checkout.
2. **Start in shadow mode.** Set `Enforcement = { ShadowMode = true }`, even if you
   enforced before. Detection and calibration change between versions.
3. **Check the boot.** Confirm `ACF:GetStatus()` shows every module `Running`, and
   `ACF.Version` / `ACF.Channel` match what you installed.
4. **Watch the audit log** (`ACF:GetAuditLog()`, or `examples/AuditToDataStore.server.luau`)
   on real servers, then turn shadow mode off. RELEASING.md has the criteria.

## 0.7 → 1.0

**Behaviour changes, from calibration on measured data (docs/EVALUATION.md):**

| Change | Effect on your game |
|--------|---------------------|
| `Risk.RepeatCap` 2 → 3 | Sustained cheating now reaches correction and review. A flyer, teleporter or noclipper can be kicked automatically after a minute or two; before, they stayed restricted. |
| Movement `Severity.Speed` 20 → 25 | Sustained speed hacks reach correction (level 3). |
| Behavioral severities 20/25 → 30; `Violation.ConfidenceScale` 6 → 3 | Duping and aimbots reach Restrict and Investigation sooner. They still never remove anyone automatically. |
| Movement time credit capped at `MaxTimeCreditSeconds` (3 s) | Closes a bypass: idling, then teleporting. A player who freezes longer than 3 s and catches up may get one Teleport *violation*; one never reports on its own. |
| Lag stalls in mid-air no longer count as flight | Removes a false positive. Nothing to do. |
| Players restricted for 10 min get a review case | Staff see restricted players (`Cases.ReviewAfterRestrictedSeconds`). |
| Departed players' enforcement state is forgotten after 1 h | Memory stays bounded. Bans still apply, from the stored record. |

**Do this:**

- To keep the 0.7 calibration, set `Risk = { RepeatCap = 2 }` and the old severities in
  `ModuleSettings.Movement.Severity` and `ModuleSettings.Behavioral.Severity`.
- Handle `ACF.Channel` (new) if you log versions.

**New keys, all optional:**

- `ModuleSettings.Movement.MaxTimeCreditSeconds`, `MaxStallCreditSeconds`,
  `StallMinVelocity`;
- `Enforcement.Cases.ReviewAfterRestrictedSeconds`, `Enforcement.ForgetAfterSeconds`.

## 0.6 → 0.7 (enforcement)

**The big one: ACF acts on its own.** Before 0.7 it only recorded evidence. With default
settings it now:

- refuses operations tagged with a suspicious player's risk groups (level 2);
- rubber-bands Movement-flagged players (level 3);
- locks out everything tagged for 10 min (level 4);
- **kicks automatically** on corroborated, non-statistical evidence (`AutoKick = true`).

Bans stay off (`AutoBan = false`), and permanent bans always need a person.

**Do this:**

- **Turn on shadow mode first** (above). If you want the old record-only behaviour, set
  `Enforcement = { Mode = "Off" }`.
- **Remote handlers.** Protected remotes can now be refused with reason `restricted`, but
  only if you add `Restrict = "<tag>"` to their spec. Without it nothing changes.
- **Combat results.** `ACF:ValidateAttack` can return `Reason = "Restricted"` (with
  `ShotAccepted = false`) for players restricted for `Combat` or `Aim`. Treat it like any
  refused shot.
- **Staff.** Cases appear (`ACF:GetCases`). Without a staff workflow they expire after
  72 h. See `examples/StaffCommands.server.luau`.
- **DataStore.** Every join reads `ACF_Bans_v1` (`Enforcement.Bans.CheckOnJoin`), and
  bans call `Players:BanAsync` (`Bans.UseRobloxBanApi`).

**Custom environments** (`ACF.Framework.new(env)`). `Enforcer`, `Store`, `OnShutdown` and
`Physics.Correct` are optional. Without an `Enforcer`, kicks and bans are recorded but
not applied.

**Custom modules.** `context.Enforcement` is new (`IsRestricted`, `ShouldCorrect`,
`NoteCorrected`). Nothing was removed.

## 0.5 → 0.6 (risk)

- **The RiskEngine is on by default** (`Risk.Enabled`). It only computes scores; nothing
  acts on them until 0.7.
- **Risk persistence** is opt-in (`Risk.Persistence.Enabled`). When on, sessions ending at
  risk ≥ 40 write to DataStore `ACF_Risk_v1`.
- **New:** topic `ACF.RiskChanged`, `ACF:GetRisk`, `GetRiskHistory`, `ResetRisk` and
  `OnRiskChanged`.
- **Custom environments:** `Store` and `OnShutdown` are optional.

## 0.4 → 0.5 (behavioural)

- **`Modules.Economy` is gone.** It was a reserved name that never did anything. Use
  Behavioral signals instead: `ACF:DefineSignal("Coins")` and
  `ACF:RecordSignal(player, "Coins", amount)`. A config that still sets `Modules.Economy`
  loads, with a "not registered" warning.
- **Behavioral is on by default.** It is passive until you record signals or actions,
  except accuracy statistics from Combat, which need no code.
- **Combat publishes `Combat.Shot`** for every accepted shot. Nothing to do.

## 0.3 → 0.4 (combat)

- **Combat is a built-in module, on by default.** It is passive until you call
  `ACF:DefineWeapon`.
- **Damage is computed by the server** (`result.Damage`). Stop applying damage the client
  sent. See docs/COMBAT.md and `examples/CombatWiring.server.luau`.

## 0.2 → 0.3 (movement)

- **Movement and Physics are on by default.** Grant server-driven motion, or it may be
  reported:
  - `ACF:AuthorizeTeleport(player)` before `PivotTo`, spawn points and portals;
  - `ACF:AllowMovement(player, "Speed" | "Flight" | "Impulse" | "Noclip" | "All", seconds)`
    for dashes, jetpacks, knockback and cutscenes.
- **WalkSpeed changes made on the server are picked up automatically.**

## 0.1 → 0.2 (remote security)

- **Built-in modules register at `Initialize`.** `RemoteSecurity` now appears in
  `GetStatus().Modules`.
- **Protecting remotes is opt-in.** Use `ACF:ProtectEvent` / `ProtectFunction`, and audit
  coverage with `ACF:FindUnprotectedRemotes`.
