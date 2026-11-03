# blind but dangerous

Script for [blind but dangerous](https://www.roblox.com/games/112270456220062), with a Fluent menu.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/killllllformatt/vibecodemods-roblox/main/blind-but-dangerous/bbd_hub.luau"))()
```

Press **RightCtrl** to open or close the menu. Running the script again unloads the old copy first and keeps your toggles.

## Features

**Blind Man**
- See While Blind: a normal, bright view during your blind rounds, including free-for-all and infected rounds. **F6** toggles it.
- No Shotgun Recoil: skips the knockback and camera flip when you fire.
- Silent Aim: sends your shots to the visible target nearest your crosshair, with an FOV slider and circle.

**Hider**
- Anti Push: ignores the fling and ragdoll when someone pushes you.
- Always Sneak: stays in sneak during rounds at normal walking speed. You still make some noise, but much less than walking.
- Anti Screen Shake: removes shake from the blind man, gunshots, the megaphone, grabs and firecrackers. Firecracker blur, tint and deafness still play.
- Auto Grab Escape: breaks free of grabs without mashing, about 2.5 seconds in.
- Auto Phone Popup: completes the phone popup for you. **Untested in a real round**, so it may be ignored.

**Misc**
- Player Outlines: draws players through walls. Red is the blind man or infected, white is a hider. **Not yet tested in a real round.**
- Staff Alert: warns you when a listed owner, admin or mod is in the server.
- Unload Hub: removes the menu and turns everything off.

**Status**
- Shows your role, the blind man, hiders alive, the mode, shells, coins and staff in the server, plus whether each feature is working.

## Executor support

See While Blind's hide hook, No Recoil, Silent Aim and the Phone popup's clean finish need `getgc`, `hookfunction` and `islclosure`. Anti Push and the grab part of Anti Screen Shake need `getconnections` and `hookfunction`. Silent Aim also needs `debug.getupvalue` and `debug.setupvalue`. Tested on Madium only.

## Notes

- Silent Aim's newest change, ignoring the invisible Halloween web sheets when checking line of sight, hasn't been tested live. It's also unknown whether real pellets pass through those webs.
- The game has a votekick and player reports, so use an alt.
