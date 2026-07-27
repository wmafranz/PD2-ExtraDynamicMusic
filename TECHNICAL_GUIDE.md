# Extra Dynamic Music Technical Guide

Version 0.1.0 for PAYDAY 2 (x86) with SuperBLT. BeardLib optional but recommended

This guide explains how every part of the mod works semantically and logically.

## Table of contents

1. [What the mod does](Line_#24)
2. [How PAYDAY 2 plays music, what it means for this mod](Line_#38)
3. [Anatomy of the mod folder](Line_#70)
4. [Boot sequence: what loads, when, and why](Line_#100)
5. [core.lua: the coordinator](Line_#124)
6. [definitions.lua: reading song definitions](Line_#150)
7. [layers.lua: the mixer](Line_#177)
8. [The six conditions](Line_#218)
9. [Note on effects.lua](Line_#232)
10. [The hook files](Line_#243)
11. [Options menu and localization](Line_#253)
12. [Known limitations (v1)](Line_#260)

---

## 1. What the mod does

Extra Dynamic Music (XDM) is a loader: by itself it makes no sound. It reads
small definition files (see `SCHEMA.md`) that pair a song, be it BeardLib Music
Module song or a vanilla track, with extra audio layers, and it fades those
layers in and out in response to game situations: being tased or flashbanged
(disoriented), the escape countdown (ponr), the hidden vanilla "drama" meter's
current intensity (drama), turrets, captains, heist bosses (boss), stealth
detection (spotted), endless police assaults (endless), and plain music
phases (`phase:control`, `phase:assault`, etc). Each layer chooses whether it
plays on top of the song (overlay) or instead of it (replace, done by
fading the main track down, never by stopping it). Songs without a
definition are untouched, and music mods never need to know XDM exists.

## 2. PAYDAY 2 (music) and You

x86 PAYDAY 2 has two music engines in practice:

- **Vanilla songs** play inside Wwise, the game's built-in audio middleware.
  Lua can ask for things ("post an event", "set the volume") but cannot
  touch the audio data.
- **BeardLib custom songs** play through XAudio, SuperBLT's OpenAL-based
  audio system. Every sound is a buffer (a decoded ogg file) played by a
  source (a channel with its own volume). These can be controlled completely 
  by lua.

XDM's layers are always XAudio sources of our own, so they work over both
engines. The difference is only in how "replace" ducks the main track:

- BeardLib song: BeardLib's own `set_volume_multiplier(id, volume, fade)`,
  a ready-made fade system any mod may use without touching BeardLib's files.
- Vanilla song: we smoothly lower `MusicManager:set_volume(...)` toward 0
  and restore the player's real setting afterwards. Or bypass this entirely
  by turning the original music into a Beardlib song, and using the xdm.json/xml
  option to have it replace the original in the music menu along with all our
  remix materials as well.

**The seamlessness trick** OpenAL cannot jump into the middle of a file
("no seek"), so a replacement that starts when you get spotted would
restart from its beginning (ideal for stingers, wrong for a variant of the
same track). XDM therefore supports two sync modes per layer. `sync:"layer"`
sources are created at the same moment as the main track, at volume 0,
and merely faded up when needed. They stay sample-locked with the song
forever, which is how games typically do "vertical remixing". `sync:"start"`
sources begin fresh at trigger time. You pick per layer.

## 3. Anatomy of the mod folder

    ExtraDynamicMusic/
    ├── mod.txt                  SuperBLT manifest (the game files we hook)
    ├── SCHEMA.md                the definition-file format (author-facing)
    ├── TECHNICAL_GUIDE.md       this document
    ├── hooks/                   
    │   ├── menumanager.lua      boot + options menu
    │   ├── musicmanager.lua     phase tracking, main-track start/stop
    │   ├── playermovement.lua   local stealth suspicion + alarm
    │   ├── unitnetworkhandler.lua  client-side suspicion sync
    │   ├── playerdamage.lua     fire-on-player events
    │   ├── hudassaultcorner.lua endless-assault sync for clients
    │   ├── groupaistatebesiege.lua  captain-driven endless assault
    │   └── localizationmanager.lua  menu strings (must load this early)
    ├── lua/
    │   ├── core.lua             the singleton; owns everything below
    │   ├── definitions.lua      finds & parses xdm.json / xdm.xml
    │   ├── layers.lua           sources, fades, priorities, ducking
    │   ├── effects.lua          stock effects (needs extended DLL)
    │   └── conditions/          one file per condition
    ├── loc/english.txt          menu strings
    ├── native/XDM_NATIVE_PATCH.md   documentation of DLL additions
    └── pack_example/            inert sample pack; live packs go in
                                 mods/saves/xdm_packs/ (see section 6)

All DLL additions will be obsolete with the release of SBLT/Beardlib x64
(Diesel 3.0), as the update will replace (cringe) OpenALSoft with a newer 
(more based) Wwise.

## 4. Boot sequence

SuperBLT reads `mod.txt` and whenever the game loads one of the listed
`hook_id` files, runs our matching `script_path` right after it:

1. Game boots: `lib/managers/menumanager` loads > our
   `hooks/menumanager.lua` runs > it `dofile`s `lua/core.lua`.
2. `core.lua` creates the global `ExtraDynamicMusic` table (visible to every
   other file), loads the other lua modules, loads saved settings, and scans
   for definition files.
3. Every other hook file begins with the same two lines: "if the global
   doesn't exist yet, load core", so no matter which game file happens to
   load first, core is there before anything needs it.
4. `Hooks:Add("GameSetupUpdate", ...)` registers per-frame update, which
   only runs during actual gameplay.

A note on the recurring syntax: `Hooks:PostHook(Class, "method", "unique_id",
function(...) end)` is SuperBLT's way of communicating "after the game runs
`Class:method`, also run my function with the same arguments"*. It never
replaces game code, which is why mods stacked this way stay compatible.
`pcall(f)` ("protected call") runs `f` but catches any error inside it and
hands it back as a value instead of crashing the game. Every place XDM
touches game internals ends up going through it.

## 5. core.lua

- **The singleton.** `_G.ExtraDynamicMusic` (`_G` is Lua's table of all
  globals). Created once; the guard `if _G.ExtraDynamicMusic then return end`
  makes double-loading harmless.
- **Settings** exist in `XDM.settings` and persist as JSON in SuperBLT's save
  folder (`SavePath .. "xdm_settings.txt"`). `LoadSettings` deliberately
  copies only keys that already exist in the defaults table, so a stale or
  hand-edited settings file can never inject garbage fields.
- **Condition registry.** `RegisterCondition(cond)` files a condition object
  under its id. Each condition promises one function, `poll(self, t, dt)`,
  where `t` is the game clock in seconds and `dt` is the time since last frame;
  polling must set `self.active` (true/false) and `self.intensity` (0..1).
  Conditions may also offer `on_signal` (for events pushed by hooks: see
  `Signal`) and `configure` (per-song tuning from a definition's `params`).
- **Music state tracking.** Three entry points called by the musicmanager
  hook: `OnMusicEvent(event)` derives the phase from names like
  `music_heist_assault` (the phase is the final `_`-separated token);
  `OnMainPlay(is_custom, is_xaudio)` records what kind of engine is playing
  and tells Definitions/Layers a song (re)started; `OnMainStop()` tears the
  layers down.
- **The pump.** `Update(t, dt)` polls every enabled condition (each inside
  pcall; a broken condition mutes itself, never the game), then lets the
  mixer and effects run. A disabled mod still calls `PanicSilence` so
  switching XDM off mid-heist fades gracefully instead of cutting.

## 6. definitions.lua

Turns files on disk into clean internal "layer" tables.

- **Where it looks** (`ScanPacks`, once at boot): every folder under
  `mods/saves/xdm_packs/` (central packs; kept with other mods' configs so
  they survive XDM updates), then every folder under `mods/` and `Maps/`
  (sidecars), for a file named `xdm.json` or `xdm.xml`. Folder listing uses
  SuperBLT's `file.GetDirectories`; a missing `xdm_packs` folder simply
  yields nothing. The `packs/` folder inside the mod is NOT scanned, it
  only ships sample content to copy over.
- **Parsing.** JSON via SuperBLT's built-in `json.decode`; XML via BeardLib's
  `FileIO:ReadScriptData(path, "custom_xml")` when BeardLib is present
  (without BeardLib, XML files are skipped with a log message pointing at
  JSON).
- **Normalization** (`normalize_layer`): every field gets a default, 
  lists may be written `"a b"`, `"a,b"` or `["a","b"]` (`to_list`), unknown 
  triggers/phases/effects are rejected with a log line naming the file and 
  the reason rather than being silently ignored, and audio
  paths are checked to exist immediately, so a typo shows up at boot, not
  mid-heist.
- **Targets.** A definition registers under every id in `target`/`targets`.
  Sidecars may omit it; `infer_music_id` then reads the music mod's own
  `main.xml` looking for a `MusicModule` id. Central packs must name their
  target.
- `GetFor(track_id)` is the mixer requesting layers for the active song.

## 7. layers.lua

The mixer owns every sound XDM makes. Per song it builds one instance per
layer: `{ def, src, cur, target, started }`: The definition, the XAudio
source (if created yet), the current volume, the volume we're fading toward,
and whether the source exists.

Each frame, `Update` runs four passes:

1. **Which audio file wants to play?** Phase triggers compare the current phase index
   (setup 1/assault 4/etc); `sticky` means "my phase or any later one", which
   also makes the bass correctly stay when an assault relaxes back to
   control. Condition triggers just read `cond.active`. A layer's optional
   `phases` list can veto. While collecting, we also note the
   highest-priority active replace layer and build the cancel set
   (trigger ids silenced by an active layer's `cancels`, remembering the
   canceller's priority).
2. **Resolve targets.** A wanted layer loses if a higher-priority layer
   cancels its trigger, or if it's a replace layer that isn't the winner
   (only one replacement may sound at a time). Survivors get
   `target = volume`, scaled by `smoothstep(intensity)` when
   `follow_intensity` is on- smoothstep is a gentle S-curve that makes a
   half-full detection meter quieter than half volume, which simply sounds
   better. Then `sync:"start"` sources are created on rising edges and
   closed once faded out (finished one-shots close themselves), fades advance
   (`dt / fade_seconds` per frame, i.e, a linear fade taking exactly
   `fade_seconds`), and the volume lands on the source via `set_volume`,
   scaled by the user's master layer volume. XAudio itself multiplies in the
   game's music-volume setting, because our sources are typed as MUSIC.
3. **Duck.** If a replace layer won, the main track is sent toward silence:
   BeardLib multiplier or vanilla `set_volume` lerp as described in section #2-
   using the replace layer's own fade times; otherwise sent back to full.
4. **Stock effects.** The winning active layer with an `effect` (if any)
   nominates a preset for the main track; Effects applies it.

`OnMainPlay` (song started/rebuilt): closes old instances, builds new ones,
starts all `sync:"layer"` sources muted right now, and forwards each layer's
`params` to its condition's `configure`. `OnMainStop`: closes everything and
restores the duck. `PanicSilence`: the fast fade used when the master toggle
goes off mid-heist.

## 8. The six conditions

Each is a small file registering one object. All game reads are pcall-guarded
and each explains its exact signal at the top. In brief:

| id | signal | notes |
|---|---|---|
| `disoriented` | player state name `tased`/`arrested`; `environment_controller._current_flashbang > 0.15`; `damage_fire` events with a refreshed 3 s window | `min_duration` param (default 1 s) stops one-frame blips from clicking |
| `ponr` | `groupai state()._point_of_no_return_timer` is a number (plus Restoration's `_ponr_is_on`) | works on host and client; the timer is synced |
| `drama` | `state()._drama_data.amount`, 0..1 | hysteresis: on ≥ 0.75, off < 0.45 (`threshold_on`/`threshold_off` params); intensity ramps across the band |
| `boss` | scan of `managers.enemy:all_enemies()` tweak names + `state():turrets()` | 2 Hz scan; vanilla bosses + Winters + Restoration captains (Spring/Summers/Autumn/Hatman); extend via `extra_tweak_names` |
| `spotted` | `PlayerMovement:on_suspicion` (host) / `UnitNetworkHandler:suspicion_hud` (client): per-observer `false`/number/`true` | meter value = intensity; full spot latches until that observer is dead/tied/converted; `linger` param (4 s) of quiet tail; alarm clears all |
| `endless` | posthook on `GroupAIStateBesiege:set_assault_endless` (captain-driven endless the Restoration Mod case) + `_hunt_mode`/`get_hunt_mode()` poll (vanilla hunt missions) + HUD `sync_set_assault_mode == "endless"` (client) | |

## 9. effects.lua (unused for now)

Stock effects will let a definition alter the *existing* music instead of shipping
any file at all: `muffle` is a lowpass (flashbang feel), `tinny` (bandpass- like a phone
speaker), `warble` (pitch wobbling at 5.5 Hz), `underwater` (heavy lowpass +
slight pitch drop).

Because the stock XAudio API used by x86 PAYDAY 2 exposes no pitch or filters, these aren't included for
now, and will most likely come out some time after July supported by whatever audio control the 64-bit
backend ends up exposing to LUA. The forecast for now seems to say it's Wwise injection.

## 10. The hook files

Each is deliberately tiny: catch one game event, forward it.
`musicmanager.lua` is the only clever one: besides phase tracking and
BeardLib's `play`/`stop_custom`, it detects the vanilla case- music events
flowing while BeardLib has no custom track set, and synthesizes `OnMainPlay`
so vanilla songs get layers too. It also guards `MusicManager.play` behind an
existence check since that function only exists once BeardLib defined it.
The others map 1:1 to the signals in section 8's table.

## 11. Options menu and localization

Classic BLT `MenuHelper` (no BeardLib dependency): master toggle, layer
volume slider, stock-effects toggle, one toggle per condition, debug logging.
Strings live in `loc/english.txt`; the menu appears under Options > Mod
Options. Every change saves immediately.

## 12. Known limitations

- Layer loops run on their own loop lengths; match them to the song's loop
  or drift accumulates (schema note). BeardLib songs using multi-track
  playlists rebuild XDM layers at each internal switch, which is audible as a 
  fade re-entry, not a glitch.
- `sync:"layer"` over vanilla songs is locked to XDM's other layers but
  only approximately to Wwise itself (no sample clock is exposed).
- Stock effects cannot touch vanilla (Wwise) audio at all.
- Replace mode ducks rather than stops; with `follow_intensity` the main
  track always returns exactly where it was.
- Multiplayer: conditions are computed from what THIS player can see;
  clients rely on synced signals (suspicion HUD, assault mode, PonR timer),
  which is why those hooks exist.
