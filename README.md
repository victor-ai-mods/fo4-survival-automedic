# Survival AutoMedic

A Fallout 4 mod for Survival mode. One press of the AutoMedic item — or nothing at all, if the
automatic mode is on — and the mod closes every need you have at once: health, radiation,
crippled limbs, hunger, thirst, diseases and addictions. It reads your state, picks a set of
items from your inventory and takes them in one go, then shows a single summary.

Written for the author's own Survival playthrough; the code is public domain, take what you like.

> **Status:** in testing, not released on Nexus Mods yet.
>
> Full documentation is in Russian: [`README.ru.md`](README.ru.md) describes how the mod actually
> works, function by function, and [`PLAN.md`](PLAN.md) lists what is left before release.

## What it does

- **Health.** Picks the set with the *least overheal*: with 80 HP missing, 40 + 50 beats a single
  110. Healing already in progress is counted, so a fight does not eat your whole stock of
  stimpaks (a stimpak heals over 50 seconds in Survival).
- **Radiation** is handled before health, because radiation lowers your maximum health.
- **Hunger and thirst** are closed by a loop: eat the cheapest thing, wait for the stage to
  change, repeat. No sustenance tables are needed, so it works both with vanilla rules and with
  Survival Configuration Menu.
- **Crippled limbs:** one stimpak heals them all. Off in power armor by default, where crippling
  does not hinder you.
- **Diseases and addictions** are detected from the live effect snapshot, not from `HasSpell`
  (which never sees a real addiction).
- **Prevention, independent of the automatic mode:** herbal remedies before sleep and after
  risky food, Rad-X when radiation rises fast for long enough.
- **Automatic mode** (off by default) with its own health and radiation thresholds: a cheap
  check every few seconds, a full check only when a threshold is actually crossed.

It never treats companions and never touches items from other mods, quest items, or anything on
your exclusion list.

## Requirements

- Fallout 4 with Survival mode
- [F4SE](https://f4se.silverlock.org/)
- [Mod Configuration Menu](https://www.nexusmods.com/fallout4/mods/21497)
- [Garden of Eden Papyrus Script Extender](https://www.nexusmods.com/fallout4/mods/74160)

**No DLC required.** Items from DLC you own are supported; items from DLC you do not own are
skipped silently. One plugin, one master (`Fallout4.esm`).

## Settings

Everything is in MCM, on eight pages: what to treat, automatic mode, health, hunger and thirst,
radiation, prevention, items, diagnostics. Thresholds, reserves ("never spend my last two
stimpaks"), a food reserve, a cap on how much radiation may be eaten, disease-risk limits,
per-item exclusion lists, and a diagnostic log with three levels of detail.

Settings are read at the start of every cycle, so changes apply immediately.

English and Russian are included. A new language is one file in
`Interface\Translations\` (UTF-16 LE with BOM, TAB-separated); nothing needs recompiling.

## Building from source

The build needs an installed copy of Fallout 4: the item table is generated offline from the
game's own records, because Papyrus cannot inspect `ALCH` items at runtime.

```
python tools/parse_consumables.py   # game data -> data/consumables.json
python tools/gen_esp.py             # the plugin
python tools/gen_psc.py             # the generated item table script
python tools/gen_mcm.py             # MCM config, translations, settings script
"<game>\Papyrus Compiler\PapyrusCompiler.exe" build/compile.ppj
python tools/plan_sim.py            # offline planner tests
python tools/deploy.py              # install into the game (with the game closed)
```

Set `FO4_PATH` if your game is not in `D:\Games\Fallout 4`. In `build/compile.ppj`, `Release`
and `Final` must stay `false`: a release build silently strips every `Debug` call, including
notifications. See [`build/f4se_stubs/README.md`](build/f4se_stubs/README.md) for the one file
you have to provide yourself.

Not in this repository, because it is either the game's content or regenerated on every build:
`data/consumables.json`, `data/mgef_index.json`, the generated `.psc` files, the plugin, the
compiled scripts and the MCM output.

## Tools

`tools/` is a small offline toolkit that may be useful on its own: an ESM/ESP reader, a BA2
reader, a `.STRINGS` reader, a condition (`CTDA`) parser and evaluator, an ESP writer with VMAD
support, a `.pex` disassembler, and a Python mirror of the planner used for testing without the
game. See [`tools/README.md`](tools/README.md) (Russian).

## License

[The Unlicense](LICENSE) — public domain. Do whatever you want with this code; no attribution
required.
