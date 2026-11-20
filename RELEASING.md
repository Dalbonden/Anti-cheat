# Releasing ACF

## Channels

| Channel | What it is | How it is made | `ACF.Channel` |
|---------|------------|----------------|---------------|
| development | Every commit on `main` | `tools/verify.sh` must print `VERIFY OK` before each commit | `"development"` |
| canary | A release candidate, run in real servers before anyone relies on it | `tools/release.sh canary` → tag `v<VERSION>-rc.<N>` | `"canary"` |
| stable | A canary that met the promotion criteria, re-labelled, not rebuilt from new code | `tools/release.sh stable` → tag `v<VERSION>` | `"stable"` |

The repository always says `development`. The release script stamps the channel and
release version, for example `1.0.0-rc.1`, into a staged copy of `src/`. A running server
reports it in `ACF.Version`, `ACF.Channel` and `ACF:GetStatus()`, so audit entries and
logs can be attributed to a build.

## Making a release

```bash
tools/release.sh canary     # v1.0.0-rc.1, v1.0.0-rc.2, ...
git push origin v1.0.0-rc.1
```

The script refuses to run unless:

- the working tree is clean;
- `tools/verify.sh` passes (tests, strict type check, build);
- `CHANGELOG.md` has a `## [<VERSION>]` entry.

It writes these files to `build/release/`:

| File | Contents |
|------|----------|
| `ACF-<release>.rbxl` | A place with ACF installed |
| `ACF-<release>.rbxm` | A model with three folders. Drag their contents into ServerScriptService, ReplicatedStorage and StarterPlayerScripts. |
| `ACF-<release>.json` | Manifest: version, channel, commit, test result, SHA-256 checksums |

```bash
tools/release.sh stable     # only on a commit already tagged v<VERSION>-rc.N
git push origin v1.0.0
```

**Stable is never new code.** The script requires the exact commit to carry a canary tag.

## Running a canary in Roblox

Roblox runs one copy of your code in every server, so a canary is the new build
**published everywhere with enforcement held back**. `examples/CanaryBootstrap.server.luau`
shows how:

1. Publish with automatic enforcement in shadow mode on every server
   (`ENFORCE_PERCENT = 0`). Detection, risk and enforcement *decisions* all run; nothing
   automatic is applied. Staff actions still work.
2. Ship the audit log (`ACF:OnEnforcementAudit`) to your own storage. Watch it against
   the criteria below.
3. Raise `ENFORCE_PERCENT` (10 → 50 → 100). Servers are chosen by a hash of `JobId`.
4. Promote the commit to stable.

**Rollback** is publishing the previous stable build. Ban records and risk history use
versioned DataStore records (`Version = 1`) that older builds read unchanged.

## Promotion criteria (canary → stable)

These must hold over at least 3 days and 500 player-hours of real traffic:

| Criterion | Where to see it |
|-----------|-----------------|
| No automatic removal (`ShadowAction` Kick/Ban) of a player staff judge honest | Audit log, reviewed by staff |
| Restrictions (`Rejected`) on honest players are rare and explained | Audit log; `Rejected` entries with `Tags` |
| No framework errors: no `Failed` modules, no disabled scheduled tasks except your own | `ACF:GetStatus()` (Modules, Scheduler), logs |
| Per-tick cost within budget (target < 2 ms at your player cap) | `GetStatus().Scheduler[...].MaxCpuSeconds` |
| DataStore writes succeed (`PersistenceFailed` absent, or explained by an outage) | Audit log, logs |
| The offline evaluation is unchanged: no honest evidence, every cheat caught | `tools/evaluate.sh full`, [docs/EVALUATION.md](docs/EVALUATION.md) |

If any criterion fails, fix it on `main` and cut a new canary (`rc.N+1`). Never promote
a canary that needed a fix.

## Version numbers

- **Semantic Versioning.** Major for breaking API, configuration or record-format changes.
  Minor for features. Patch for fixes.
- **Configuration.** Changing a configuration *default* that alters enforcement is at
  least a minor version, and the CHANGELOG says so.
- **Stored records.** Record formats carry `Version`. A new format must read the old one.
