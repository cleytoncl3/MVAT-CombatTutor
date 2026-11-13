# MVAT – Combat Tutor (WoW Classic / Classic Era)

A **lightweight, universal and 100% informational** addon that shows, in its own floating icon, the ability
recommended right now: emergency, interrupt, dispel, heal, taunt, damage combo, area (farming)
or a missing buff — together with the **key binding** you use for it.

> The addon **automates nothing**: it does not cast spells, click or change action bars.
> It only reads the game state and draws an icon.

## Features

- **All 9 Classic classes** (Warrior, Rogue, Mage, Priest, Paladin, Hunter, Warlock,
  Shaman, Druid), detected automatically at login (`UnitClass`).
- **Spell IDs** + `GetSpellInfo`/`C_Spell`: works on Portuguese or English clients.
- **Only suggests what you have learned** — the spellbook is read again when you level up, learn a
  spell or change talents. Any rank counts.
- **Priorities** (the first one that applies is shown):
  1. **EMERGENCY** – low health (Shield Wall, Ice Block, Divine Shield, Vanish…)
  2. **INTERRUPT** – target casting something interruptible (Kick, Counterspell, Earth Shock…)
  3. **DEFENSE** – a heavy non-interruptible cast coming at you
  4. **DISPEL** – poison/disease/curse/magic on you or your party/raid
  5. **HEAL** – the most injured party member (name and % in the text)
  6. **TAUNT** – tank: the target is hitting another party member
  7. **COMBO** – reacts to procs and buffs: Presence of Mind → Pyroblast, Clearcasting → free spell,
     Shadow Trance → Shadow Bolt, Seal → Judgement, combo points → finisher,
     Overpower/Revenge/Execute (reactive), Nature's Swiftness → instant heal…
  8. **AREA / FARM** – with several enemies (default 3+): Whirlwind, Arcane Explosion, Consecration,
     Blizzard, Multi-Shot, Rain of Fire, Swipe, Magma Totem…
  9. **DAMAGE** – basic single-target rotation (missing DoTs, main strike, filler)
  10. **BUFF** – your own missing buffs (out of combat)
- **Key binding** read from the game's binding map (`GetBindingKey`): direct spell bindings,
  Blizzard bars, ElvUI, Bartender4 and Dominos — stance/form bars included.
- **Independent HUD** (its own anchor): does not touch ElvUI or the default bars.
  When locked, it does not catch clicks.
- Position, scale and options saved in **SavedVariables** (`MVAT_DB`).

## Install

1. Close the game (or log out).
2. Download this repository: **Code → Download ZIP** (or `git clone`).
3. Copy **the `MVAT` folder** (the one with `MVAT.toc` and `MVAT.lua`) to:
   - `World of Warcraft\_classic_era_\Interface\AddOns\` (Classic Era / Hardcore / SoD)
   - or `World of Warcraft\_classic_\Interface\AddOns\` (Classic progression)

   The result must be `...\Interface\AddOns\MVAT\MVAT.toc`.
   Do **not** copy the whole `MVAT-main` folder — the folder name must be `MVAT`.
4. Open the game, click **AddOns** at the character screen and tick **MVAT – Combat Tutor**.
   If it says "Out of date", tick **Load out of date AddOns**.
5. Log in. You will see: `MVAT loaded for <class>`.

**Tip:** turn on enemy nameplates (key **V**) — the addon uses them to count how many
mobs are in combat and to turn on the area/farm suggestions.

## Updating without downloading the ZIP every time (Windows)

The addon folder comes with **`Atualizar MVAT.bat`**. **Double-click** it:

1. it finds the WoW Forever folder by itself (or asks once and remembers it);
2. it compares the installed version with the one on GitHub (`## Version` in `MVAT.toc`);
3. if there is a new version, it downloads it and updates the addon folder (your settings are kept);
4. it shows **"Done! ... type /reload in game"**.

**First install:** download the repository ZIP (Code → Download ZIP), open the `MVAT` folder inside it
and double-click `Atualizar MVAT.bat`. It installs the addon for you. After that, run it again
whenever you want to update. To reinstall the same version: `Atualizar MVAT.bat force` in a terminal.

- Windows may show the blue "SmartScreen" warning the first time (file downloaded from the internet): click
  **More info → Run anyway**. The file is plain text and can be read first.
- It needs internet access and the public repository. The updater code is inside the `.bat` itself.
- **In-game notice:** the addons exchange their version number between friends in party/raid/guild. If
  someone has a newer version than yours, a message asks you to run the updater.

## Compatibility and addon audit (2026-11-10)

Checked in the WoW Forever addon folder (client build **1.60.1.70862**, `Interface 16001`):

- **DBM 12.1.20** and **BigWigs v427.9** are the latest versions published on GitHub for both.
- **Neither ships boss modules for the classic dungeons on Forever.** DBM looks for a
  `DBM-Party-Vanilla` module that is not in the package; `BigWigs_Classic` (a separate repository) does not
  declare interface 16001 and only loads on `classic, standard`. So in Forever dungeons both only give
  **generic** cast warnings (DBM's "GenericTrash"). MVAT fills that gap with the
  enemy cast panel.
- MVAT follows the same rule as DBM for casts from other enemies: only enemies **in combat** (with
  a new attempt after 0.05 s) and at most 1 warning per second for a normal mob.
- **EllesmereUI** (instead of ElvUI) uses the native `ACTIONBUTTONn`/`MULTIACTIONBARxBUTTONn` commands;
  the key shown on the icon is still right. `ForeverDungeonJournal` has boss names, levels and loot,
  but **not** their abilities.

## Options window

Type **`/mvat`** (or `/tutor`) to open the options window, or use **Esc → Options → AddOns → MVAT**.
The look follows Leatrix: dark panel with parchment, two columns, a tooltip when you hover each
option, and a footer with buttons. Drag the panel to move it (the position is remembered); **Esc** closes it.

- **General:** addon on, show only in combat, show the reason, only abilities on your bars, lock position.
- **Panels:** DISPEL (party debuffs) and boss and elite casts.
- **Paladin:** a button that switches the seal (automatic or fixed; only the seals you have).
- **Size:** sliders for the icon/panel size (50% to 300%), the enemy count for area mode and the **text under the icon** (8 to 32, separate from the icon).
- **Footer:** Restore defaults, Test icon and Close.
- **Minimap button:** turns the MVAT icon on the minimap edge on or off (click opens the options, right-click turns the addon on or off, drag to move it around the minimap; works with a square minimap).

### Moving the icon and panels

Click **Move icon and panels** (or untick "Lock icon position"). The window closes and you get:

- the **main icon** (drag with the left button);
- a **blue rectangle for each warning panel**: *cast warning* (interrupt/defense), *enemy casts*, *DISPEL*, *your debuff you can't remove* and *boss warning*. Each one is dragged and saved **separately**;
- a **bar at the top of the screen** with a **Lock positions** button to finish.

"Restore defaults" puts everything back in its original place.

The commands below still work as shortcuts.

## Tutor mode: roles, combos and help in combat

Made for players who are learning: the addon says **what to use now**, **what comes next** and **why**.

### Role (damage / tank / healer)

For **Priest, Paladin, Shaman, Druid and Warrior** the addon only shows what fits your role. The
role is detected from your **talent points** (Feral Druid: Bear = tank, Cat = damage) or chosen in the
window (`/mvat` → "Your class" → *Role*) or with `/mvat papel auto|dano|tank|cura`.

| Role | What shows up |
|---|---|
| **Healer** | cooldown heals and HoTs, **keeping the HoT on your friendly target** (Renew, Rejuvenation, Lifebloom, Riptide), party dispels, buffs, group help when the boss casts. No damage abilities. |
| **Tank** | tank stance/form/seal, threat, taunt (Growl/Righteous Defense/Taunt), big defensives (Templar's Bulwark, Shield Wall, Barkskin…). |
| **Damage** | rotation and combos. No heals on allies. |

Mage, Rogue, Hunter and Warlock are damage only and have no role choice.

**Decides by target (grinding and groups):** a healer in normal form (Druid, Priest, Shaman, Holy
Paladin) who targets an **enemy** gets the full **damage rotation**; targeting an **ally** gives the
**healing** (HoT on the target, direct heal, dispel). It works even when the client does not let the addon
read talents (`/mvat debug` tells you).

### Class options (window `/mvat` → "Your class")

Paladin: role, seal and aura · Priest, Druid, Warrior: role · Shaman: role and shield (Lightning/Water) ·
Mage: armor and main spell · Warlock: utility curse · Hunter: aspect · Rogue: opener.

### NEXT (next steps)

Next to the icon, up to 2 small **NEXT** icons show the next abilities that are also available
now. That is the combo in order (use A, then B). Turn it off with "Show next steps".

### Your debuff you can't remove (why nothing is suggested)

When you have a **Magic, Curse, Disease or Poison** debuff that your class **cannot remove**, the addon has
nothing to suggest, so it **warns and explains**: it shows the debuff icon and name and a line such as
**"Magic: only with Cleanse (level 42, you are 32)"**. In combat the game hides the debuff type; the
addon uses the game's own color curve (`GetAuraDispelTypeColor`, the same technique as EllesmereUI)
only to **show** the right type. Debuffs without a type (bleeds, stuns) do not show up. Levels at which
each class learns to remove them (Forever trainer data):

| Class | Poison | Disease | Magic | Curse |
|---|---|---|---|---|
| Paladin | Purify (8) | Purify (8) | **Cleanse (42)** | can't remove |
| Priest | can't remove | Cure Disease (14) | Dispel Magic (18) | can't remove |
| Druid | Abolish Poison (26) | can't remove | can't remove | Remove Curse (24) |
| Shaman | Cure Poison (16) | Cure Disease (22) | can't remove (Purge is offensive) | can't remove |
| Mage | can't remove | can't remove | can't remove | Remove Lesser Curse (18) |
| Warrior, Rogue, Hunter, Warlock | can't remove player debuffs | | | |

### Dispel on the main icon

The DISPEL panel shows who in your group has a debuff; on top of that the **main icon** suggests
**"Dispel <name>"** with your dispel ability (works in combat, through the native filter
`RAID_PLAYER_DISPELLABLE`; the game hides the debuff type in combat, so the addon suggests your
dispel ability available for that target).

### Boss cast: what to do

When a boss/elite casts, the panel shows what the game allows (name, icon, cast target) and **one
tip per role**:

- **Damage:** "Interrupt if you can. On you? use your defensive." (interrupt and defensive icons)
- **Tank:** a **tank** defensive instead of the personal one.
- **Healer:** a **GROUP** icon (group heal: Prayer of Healing, Chain Heal, Wild Growth, Holy Shock…)
  that shows when the cast is **not** on you, and your personal defensive when it is. It also works with the
  boss not targeted (the "other enemy casts" line reads `boss1-5` and the nameplates).

> Game limit: Forever hides group health and the spell name/type in combat. The addon
> **shows** that data (icon alpha) but cannot decide based on it. That is why healing in
> combat is driven by cooldowns and the HoT on your target, not by "who has the least health".

### Sources used to build the rules

WoW Forever guides and notes (Sep–Nov 2026): Warcraft Tavern (classes and each class page,
updated Nov 3), Games.gg (new abilities by class), notes from Forever's own addons
(WhatsTraining, TalentsForeverBook, ForeverAuras). New talent abilities (Riptide, Wild
Growth, Templar's Bulwark, bear Mangle, Lifebloom) are only recognized when the Classic/TBC ID
matches the Forever one; `/mvat spells` lists what is in your spellbook without a rule so it can be added.

## Chat commands (`/mvat` or `/tutor`)

| Command | Effect |
|---|---|
| `/mvat` | Opens/closes the options window (also: `/mvat opcoes`, `config`, `menu`) |
| `/mvat unlock` | Unlocks: drag the icon with the left button |
| `/mvat lock` | Locks and saves the position |
| `/mvat scale 1.5` | Icon size (0.5 to 3) |
| `/mvat aoe 3` | How many enemies turn on area/farm mode (2 to 10) |
| `/mvat combat` | Toggles "show only in combat" |
| `/mvat text` | Toggles the explanation text under the icon |
| `/mvat barra` | Toggles "only suggest abilities on your bars" (default: on) |
| `/mvat selo <name>` | Paladin: fixes a seal (`retidao`, `furia`, `cruzado`, `comando`, `luz`, `sabedoria`, `justica`) or goes back to `auto` |
| `/mvat papel <auto\|dano\|tank\|cura>` | Picks your role (Priest, Paladin, Shaman, Druid, Warrior) |
| `/mvat spells` | Lists the abilities in your spellbook the addon doesn't know yet |
| `/mvat limpar` | Toggles the DISPEL panel (party debuffs you can remove) |
| `/mvat casts` | Toggles the panel of casts from other enemies (boss, elites) |
| `/mvat test` | Shows a test icon for 5 seconds |
| `/mvat reset` | Restores the default position and options |
| `/mvat on` / `/mvat off` | Turns the addon on / off |
| `/mvat debug` | Shows class, number of rules and recognized abilities |
| `/mvat diag` | Shows what the game hid in the last fight (health, resource, auras) and the last error caught |

## Reading the HUD

- **Colored border + label on top**: category (red = emergency, orange = interrupt,
  purple = dispel, green = heal, gold = combo, blue = area, gray = damage, cyan = buff).
- **Big text in the icon corner**: your key binding (e.g. `E`, `Shift+2`, `F1`).
  If it is empty, the ability is not on any bar with a binding.
- **Text below**: the reason for the suggestion and the ability name.

## WoW Forever: secret values

Forever uses the modern WoW engine, which hides several pieces of information from addons during combat
("secret values": health, resources, auras, cooldowns…) and forbids the combat log. MVAT:

- **does not use** the combat log (avoids the "only available to the Blizzard UI" warning);
- checks every value before using it: anything secret is treated as "unknown" and the rule that
  depended on it simply doesn't fire — no Lua errors;
- "missing buff/DoT" rules only show up when the addon is **sure** it is missing;
- in combat, the main source is **Blizzard's own proc glow**
  (`SPELL_ACTIVATION_OVERLAY_GLOW_SHOW`): when an ability lights up (Overpower, Execute,
  Revenge, talent procs), MVAT shows its icon with your key;
- when the target starts a cast, the interrupt warning shows up even if the spell name is hidden.

So in combat, suggestions can be much less frequent than outside it. Use `/mvat diag`
after a fight to see what the game allowed.

### Only what is on your bars

MVAT reads your action bars (including ElvUI/EllesmereUI, which use the same slots) and **only suggests
abilities you can press**. With empty bars the filter is ignored. `/mvat barra` toggles it.
Abilities of other levels only show up once you learn them (the spellbook is read again).

### Paladin (Forever rules)

Forever has a different Paladin from Classic Era, and MVAT follows the change notes of Forever's own addons
(TalentsForeverBook / WhatsTraining):

- **Seal chosen by context**, among the ones you have **and that are on your bars**, with the reason on screen:
  shield equipped or Righteous Fury active → **Seal of Fury** ("the tank seal": Holy damage + absorb);
  slow or two-handed weapon → **Command** (from level 30); low mana → **Wisdom**; otherwise
  **Righteousness**. Crusader only shows up if it is the only one left; Justice only with `/mvat selo justica`.
- **Before the fight**, if the active seal is not the one the context asks for, it suggests switching.
- **Judgement no longer consumes the seal** (10 s cooldown, 10 m range; judging Fury taunts the target): MVAT
  no longer asks you to reapply the seal after Judgement.
- **Holy Strike** (10 s cooldown), Exorcism on undead/demons, Consecration with several enemies,
  Righteous Fury with a shield, Devotion (tank) or Retribution (damage) aura and blessings.
- The seal state is tracked through your own casts and the real duration seen on auras, because in
  combat Forever hides auras.

### Other classes (Forever abilities and rules)

The IDs and the new abilities come from Forever's own trainer list (WhatsTraining/Camelot) and the change
notes (TalentsForeverBook). Each class uses what exists in Forever:

| Class | Forever abilities used |
|---|---|
| Warrior | Charge (opener), Victory Rush, Mighty Strike (15 s), Bloodrage at the start of the fight, Recklessness on elites, Thunder Clap |
| Rogue | Stealth opener (Ambush with a dagger; otherwise Cheap Shot/Garrote), Backstab with a dagger, Rupture on elites |
| Mage | Arcane Blast (Arcane spec), Ice Lance after Frost Nova, Blast Wave |
| Priest | Penance, Prayer of Mending, Shadow Word: Death (only at high health), Holy Nova |
| Hunter | Aimed/Multi-Shot (shared cooldown), Counterattack |
| Warlock | Bane of Agony separate from the Curse, Drain Life, Conflagrate, Soul Fire on elites |
| Shaman | Fire Nova (now a 10 s spell), Chain Lightning |
| Druid | Lacerate (bear), Pounce/Ravage (cat while Prowling) |

In combat Forever hides **target auras, Rage/Energy and combo points**. To keep suggesting:

- **DoTs** (Rend, Corruption, Immolate, Moonfire...) are tracked by the **time since your last cast**
  (reset when you change targets); when auras are readable, the real aura wins.
- **Combo points** are counted from your casts (each builder adds, each finisher resets).
- **Unknown Rage/Energy**: the addon assumes you have the resource (the game refuses if you don't).
- **Healing in combat** is limited: ally health is secret, so "low health" heals only show up out
  of combat; Prayer of Mending and the like show up by cooldown.

### Cast panel (what the enemy is casting)

The game doesn't let an addon **read** the enemy spell name in combat, but it lets it **show** it
(`SetText`/`SetTexture` accept secret values) and control an icon's transparency with a
secret boolean (`SetAlphaFromBoolean`). It is the same technique as EllesmereUI's cast bar. When the
target casts, a panel shows up above the main icon:

- **ENEMY**: icon and name of what it is casting (shown, never compared);
- **INTERRUPT**: your interrupt + key, only if you have it and it is off cooldown (`isActive`);
  the icon disappears by itself if the cast is **not** interruptible;
- **DEFENSE**: your defensive + key, only shows up if the cast is **on you** and **not** interruptible.

So the addon does **not** know *which* spell it is, and it doesn't pick the ability by its name. It picks
by *type* (interruptible, on you).

### Combos from your last ability

Your own casts stay readable (`UNIT_SPELLCAST_SUCCEEDED` for the player), so "used A →
use B" works without auras: Presence of Mind → Pyroblast, Seal → Judgement, Corruption → Immolate →
Shadow Bolt, Mark → Sting → Arcane Shot, Inner Focus → big heal and so on. See `SEQUENCES` in
`MVAT.lua`.

### Boss warning

If the client sends `ENCOUNTER_WARNING` (the system DBM/BigWigs use in Midnight), MVAT shows
the warning text, icon and severity. `/mvat diag` tells you whether that event exists in your client.

### Casts from other enemies (boss, elites, whoever targets you)

The main cast panel looks at your **target**. Like DBM does on Forever, MVAT also listens to casts
from any enemy (nameplates and `boss1-5`) and shows, above the main panel, the spell name and icon
(secret values: display only) and the **cast target**. Elites and bosses always show; a normal mob only
shows when the cast is **on you**. If the cast on you is not interruptible, your defensive icon
shows. The panel disappears when the cast ends or is interrupted. `/mvat casts` toggles it.

### DISPEL: party debuffs you can remove

A panel to the left of the main icon, with you and your party/raid (up to 4 lines): who is affected, the
debuff name and icon and **your dispel ability (or abilities) with the key**. It works in combat
with the native filter `HARMFUL|RAID_PLAYER_DISPELLABLE` (the same one ElvUI and EllesmereUI use): the game
says "you can remove this debuff" without revealing its type. When the type is hidden and your class
removes more than one type, the panel shows one ability per type (at most 2). Players out of
dispel range (`UnitInRange`) are ignored. Classes without a dispel (Warrior, Rogue, Hunter,
Warlock) don't show the panel. `/mvat limpar` toggles it.

| Class | Removes |
|---|---|
| Paladin | Poison, Disease, Magic (Purify / Cleanse) |
| Priest | Magic (Dispel), Disease (Abolish/Cure Disease) |
| Mage | Curse (Remove Lesser Curse) |
| Shaman | Poison, Disease (Cure Poison / Disease) |
| Druid | Curse, Poison (Remove Curse, Abolish/Cure Poison) |

## Known limitations

- The DISPEL panel depends on the client accepting the `RAID_PLAYER_DISPELLABLE` filter; `/mvat diag` shows
  how many reads and how many removable debuffs were seen, and the last error.
- **Pet** abilities (Felhunter's Spell Lock, Intimidation) are not suggested.
- The addon doesn't know whether you are **behind** the target; Backstab/Shred only show up through procs.
- Heals name the ally in the text — the heal target is still your choice.
- On clients where the enemy cast API is limited, the addon uses the combat log as a fallback.

## Structure

```
MVAT/
  MVAT.toc   – metadata and SavedVariables
  MVAT.lua   – API compatibility, spellbook, key bindings, context, class rules, engine and HUD
```

To adjust priorities, edit the `CLASS_RULES.<CLASS>` tables in `MVAT.lua`: rules are
checked from top to bottom and the first valid one is shown.

## License

MIT, see [LICENSE](LICENSE).
