# Inert XDM sample pack example

**Live packs do NOT go here.** XDM loads central packs from either
**`mod_overrides/<songname>/`** or **`mods/saves/xdm_packs/`** alongside 
the other mods' configs and saves, so that packs survive updating or 
reinstalling XDM. This folder only ships sample content for testing 
and demonstration.

A pack is a folder containing an `xdm.json` (or `xdm.xml`): extra-dynamic
layers for a song you don't own (someone else's BeardLib music mod, or a
vanilla track) with the audio files sitting beside the definition. Nothing
outside your pack folder ever needs editing. See `SCHEMA.md` in the mod root
for every field.

## The example pack

To try it, copy `example/` to `mods/saves/xdm_packs/example/`. It targets
vanilla heist track `track_02 (Full Force Forward)` with obvious test tones so each trigger is
unmistakable: bass joins in control and stays (sticky), a pulse joins in
assault, a pad plays with drama, brass while a turret/captain lives, a
shimmer while you're being noticed in stealth, a pulse during endless
assault, and an alarm replaces the music during Point of no Return
(cancelling drama/boss/endless).

Set `target` to whichever song you'll actually play- for the vanilla
playlist pick the track in the music options; for a BeardLib song use its
music id. Easiest way to find any id: enable Debug logging in
Options > Mod Options > BLT Mods > Extra Dynamic Music, start the heist, and read
`main play; track=<id>` out of the date-named log in `mods/logs/`
(e.g. `2026_07_20_log.txt`). Delete the copied folder
when you're done as it's supposed to be a demo, not actual music.
