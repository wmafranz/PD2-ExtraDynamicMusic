# Extra Dynamic Music definition file schema (v1)

A definition file tells Extra Dynamic Music (XDM) what extra audio to weave into
one song. It can be put in either of two places (both are checked, sidecar wins
on conflict):

1. Sidecar: `xdm.json` (or `xdm.xml`, BeardLib required for XML) inside a
   BeardLib music mod's folder, next to its `main.xml`. For music authors who
   ship XDM support with their song.
2. Central pack: `mods/saves/xdm_packs/<your song's name>/xdm.json`. For
   adding onto another person's music mod (or a Beardlibified vanilla track) without 
   touching it. One pack folder can hold the definition plus its ogg files. Located in
   `mods/saves/` (like other mods' configs) means your packs survive XDM
   updates and reinstalls. Mostly for convenience when creating packs locally.

Audio file paths inside a definition are relative to the definition file's
own folder.

## Top-level fields

```json
{
    "target": "my_music_id",
    "layers": [ ... ]
}
```

- `target` (string, required in packs; optional in sidecars where it defaults
  to the music mod's id): the track this definition applies to. For BeardLib music 
  this is the music id from its `main.xml`. For vanilla songs it is the vanilla 
  track name (e.g. `"track_02"`, the same names used in `tweak_data.music.track_list`,
  this one specifically is Full Force Forward). A pack may also use 
  `"targets": ["id_a", "id_b"]` to apply to several songs.
- `layers` (array, required): the dynamic content, one entry per extra audio layer.
- `replaces` (string, optional, repack sidecars): the vanilla track id this
  BeardLib song is an upgraded version of (`"track_04" for example would be Razormind`). 
  When the player picks that vanilla song, the repack plays instead, and the repack's
  own jukebox entry is hidden: one entry, vanilla name, dynamic playback.
  Toggleable game-wide via Mod Options ("Upgraded vanilla songs").

## Layer entry example

```json
{
    "on":        "drama",
    "file":      "drama_strings.ogg",
    "mode":      "overlay",
    "sync":      "layer",
    "volume":    1.0,
    "fade_in":   1.5,
    "fade_out":  3.0,
    "phases":    ["control", "anticipation", "assault"],
    "sticky":    false,
    "priority":  null,
    "cancels":   [],
    "follow_intensity": true,
    "loop":      true,
    "params":    {}
}
```

Field by field:

- `on` (required): what activates this layer. Either a condition id:
  `disoriented`, `ponr`, `drama`, `boss`, `spotted`, `endless`: or a phase
  trigger written `phase:<name>`: `phase:setup`, `phase:control`,
  `phase:anticipation`, `phase:assault`. Phase triggers are how you build the
  "song gains bass in control, drums in assault" vertical stack.
- `file`: ogg to play, relative to this definition file.
- `mode`: `"overlay"` (default; plays on top of the main track) or
  `"replace"` (the main track is faded down while this layer is active, and
  faded back when it ends).
- `sync`: `"layer"` (default) or `"start"`.
  - `layer`: the sound is started together with the main track at volume 0
    and faded up when its trigger activates. Stays sample-locked to the music
    forever- this is what makes replaces and stacked phases seamless. Loop
    length should match the main track's loop.
  - `start`: the sound starts **from its own beginning at the moment the
    trigger fires** (right for stingers, Point of no Return, disoriented).
  - Either way, layers hold silent while a BeardLib song's `start_*` intro
    segment is playing and begin with the first proper loop, so a heist that
    opens straight into an assault (Hoxton Breakout style) can't stack
    layers over the intro.
- `volume`: 0.0-1.0 target volume when fully active. Default 1.
- `fade_in` / `fade_out`: seconds. Defaults 1.5 / 2.5.
- `phases`: optional list of music phases the layer is allowed to be audible
  in. Omit for all phases.
- `sticky`: phase triggers only. `true` keeps the layer audible in every
  phase *after* its trigger phase too (bass that arrives in control and stays
  through assault). Default `false` (exact phase only).
- `priority`: number; higher wins. When two `replace` layers are active at
  once only the highest actually plays; the rest wait silently. Defaults per
  condition: disoriented 90, ponr 80, spotted 70, endless 60, boss 50,
  drama 40, phase triggers 10.
- `cancels`: list of condition ids / phase triggers whose layers are forced
  silent while this layer is active. Works on overlays as well as replaces.
- `follow_intensity`: if the condition reports a strength (spotted's detection
  meter, drama's level), scale volume with it instead of snapping to full.
  Default `true` for `spotted` and `drama`, `false` otherwise.
- `loop`: default `true`. Set `false` for one-shot stingers (`sync:"start"`).
- `params`: per-condition tuning overrides, e.g. for `drama`:
  `{"threshold_on": 0.75, "threshold_off": 0.45}`; for `spotted`:
  `{"linger": 4.0}`; for `disoriented`: `{"min_duration": 1.5}`; for `boss`:
  `{"extra_tweak_names": ["my_custom_boss"], "turret_max_distance": 4000,
  "proximity_range": 3000, "proximity_min": 0.63}`.
  Boss notes: turrets stop counting when destroyed, deactivated (folded up),
  or beyond `turret_max_distance` centimeters (default 40 m); An abandoned
  turret no longer holds the music. With `follow_intensity: true` on the
  boss layer, its volume swells with proximity to the nearest boss: full at
  point blank, easing to `proximity_min` (0.63 ≈ -4 dB) at
  `proximity_range` centimeters and beyond.

## Minimal examples

Central pack stacking a vanilla stealth song (no vanilla files edited anywhere):

```json
{
    "target": "track_02",
    "layers": [
        { "on": "phase:control", "file": "bass.ogg",  "sticky": true },
        { "on": "phase:assault", "file": "drums.ogg" },
        { "on": "boss", "file": "boss_brass.ogg", "priority": 55 }
    ]
}
```

## XML equivalent (BeardLib installed only)

```xml
<xdm target="my_music_id">
    <layer on="drama" file="drama_strings.ogg" mode="overlay" sync="layer" volume="0.9"/>
    <layer on="ponr" file="ponr.ogg" mode="replace" sync="start" cancels="drama boss"/>
</xdm>
```

Attributes map 1:1 to the JSON fields; space-separate list values
(`cancels="drama boss"`, `phases="control assault"`).
