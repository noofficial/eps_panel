# Star Trek TBN EPS Power Routing Addon

An in-house Garry's Mod addon built for the **Star Trek TBN** roleplay server. It recreates a shipboard EPS (Electro-Plasma System) routing console so Engineering and Operations players can monitor demand, rebalance subsystem power, and react to incidents from interactive wall panels placed around the ship.

## Why it exists

- Keeps the TBN engineering loop active with meaningful slider management instead of static filler props.
- Provides hooks for bridge officers to respond to spikes, maintenance locks, and sabotage without leaving immersion.
- Drives environmental feedback (sounds, sparks, fire) that sells the fiction when systems misbehave.

## Getting started in-game

1. Locate an EPS routing panel (`ent_eps_panel`) on the ship and press `E` to interact.
2. The panel pushes a fresh state to your client and opens the EPS interface (`eps_open`).
3. Review subsystem sliders, deck metadata, and current budget usage before making changes.
4. Drag sliders to shift allocation as required; totals must stay under the available EPS budget.
5. Watch for blue/purple highlights indicating unmet demand or orange/red highlights indicating increased power load conditions beyond demand.

Maintenance locks may engage during conduit work. When locked, the panel plays a warning tone and chat message; only authorized staff (or an override) may adjust allocations until the lock clears.

## Operating procedures

- **Routine balancing** – Use `/eps` or the panel to nudge subsystems back toward their defaults. The system mirrors UI updates to all consoles, so coordinate with fellow engineers.
- **Responding to spikes** – When an automated spike fires, the panel broadcasts a location-specific alert (e.g. `Power fluctuations detected in Auxiliary Power Matrix (Deck 3, Section 9 Officers Quarters 5).`). Restore the affected slider to satisfy the temporary demand and the system will acknowledge stabilization early.
- **Manual incidents** – Admin/engineering leads can drive story beats with manual commands:
	- `/pwrspike1` – Quiet “natural” spike that respects the normal schedule.
	- `/pwrspike2` – Forced spike that supersedes the current timer.
	- `/epsdamage1` / `/epsdamage2` – Natural vs forced overloads for localized damage events.
- **Telemetry syncing** – If a client desyncs, run `eps_sync` (console) to request the full state without reopening the UI.

## Interaction & effects

- The panel emits confirmation sounds on use, warning beeps when maintenance locks are active, and distinctive tones when spike alerts or recoveries trigger.
- **Sparks**: Generated via `cball_explode` at the spark offset (configurable per ship variant). This sells overloads and draws attention to the console.
- **Fires**: Severe overloads can spawn a fire entity at the configured fire offset until engineers resolve the state.
- Both offsets are configurable in `PanelSparkOffset` and `PanelFireOffset` so mappers can fine-tune attachment points to match custom wall props.

## Commands at a glance

| Command | Role | Notes |
| --- | --- | --- |
| `eps_sync` | Console | Replays the current state without reopening the UI.
| `/pwrspike1` | Privileged (admin/engineering) | Natural spike for subtle disruptions.
| `/pwrspike2` | Privileged | Forced spike that resets the spike timer.
| `/epsdamage1` | Privileged | Natural overload on a random routed subsystem.
| `/epsdamage2` | Privileged | Forced overload with explicit sabotage messaging.
| `eps_damage` | Console, privileged | Console-only shortcut for forced overloads.

Privilege checks default to admin status; adjust `AllowedGroups` or hook overrides if your TBN ranks differ.

## Configuration overview

All tuning lives in `lua/eps_routing/config.lua`:

- **Subsystem library** (`Subsystems`) – Defines min/max/overdrive/default allocations for every EPS branch used on the TBN ship.
- **Spike settings** (`Spikes`) – Controls frequency, duration, weighting, demand increase, and alert/recovery copy (including the spark timer behavior).
- **Command bindings** (`Commands`) – Chat and console command strings for the UI and manual incidents.
- **Effects** – `PanelSparkOffset` and `PanelFireOffset` let you reposition visual effects relative to the panel model. Leave fire offset `nil` to inherit spark + 24uu.

Changes require a server restart or Lua refresh (`lua_openscript`/`lua_refresh`) to propagate.

## Development reference

- Server bootstrap: `lua/eps/core/server_setup.lua`
- Spike lifecycle: `lua/eps/systems/spikes.lua`
- Command routing: `lua/eps/systems/commands.lua`
- Shared state & netcode: `lua/eps_routing/sh_state.lua`
- Panel entity & effects: `lua/entities/ent_eps_panel`

Keep comments short, prefer config-driven tweaks, and remember that the addon expects ASCII-safe edits for easy deployment across the Star Trek TBN infrastructure.
