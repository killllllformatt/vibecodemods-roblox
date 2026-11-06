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
- Silent Aim: sends your shots to the visible target nearest your crosshair, with an FOV slider and circle. Shots are aimed from your head, like the game's own. The Status tab shows what the last shot did: who it picked, or why it didn't redirect.
- Anti Funky Stim: when a hider stims you, you keep walking, skip the dance and get your shotgun back right away. The server still won't take shots until the 5-second stim ends.
- Anti Scary Serum: when a hider uses the Scary Serum on you, your controls stay normal and the fake footsteps and coughs don't play.

**Hider**
- Always Sneak: stays in sneak during rounds at normal walking speed. You still make some noise, but much less than walking.
- Anti Screen Shake: removes shake from the blind man, gunshots, the megaphone, grabs and firecrackers. Firecracker blur, tint and deafness still play.
- Anti Hearing Aids: when the blind man uses Hearing Aids, the heart minigame never shows up, you don't get frozen, and he never gets your heartbeat.
- Auto Grab Escape: breaks free of grabs without mashing, about 2.5 seconds in.
- Auto Phone Popup: completes the phone popup for you. **Untested in a real round**, so it may be ignored.

**Misc**
- Player Outlines: draws players and bots through walls. Red is the blind man or infected, white is a hider. Takes over from the game's own blind-man outline, which only shows him when he's in plain view, and from the red flash on the blind man at round start.
- Anti Push: ignores the fling and ragdoll when someone pushes you, as either role.
- Anti Fall Ragdoll: no ragdoll from falling or long jumps, as either role.
- Anti AFK: blocks Roblox's idle kick and turns the game's AFK mode back off when the server switches it on, so you keep getting put in rounds. As the blind man it also steps you a few studs after 12 seconds standing still, because the server ends the round if the blind man doesn't move for 25 seconds.
- Staff Alert: warns you when a listed owner, admin or mod is in the server.
- Unload Hub: removes the menu and turns everything off.

**Status**
- Shows your role, the blind man, hiders alive, the mode, shells, coins and staff in the server, plus whether each feature is working.

## Executor support

See While Blind's hide hook, No Recoil, Silent Aim and the Phone popup's clean finish need `getgc`, `hookfunction` and `islclosure`. Anti Push and the grab part of Anti Screen Shake need `getconnections` and `hookfunction`. Anti Scary Serum needs `getgc`, `hookfunction` and `debug.getconstants`. Anti Hearing Aids needs `getgc` and `hookfunction`; Anti Fall Ragdoll needs `getconnections` and `hookfunction`. Anti AFK uses `getconnections`. Silent Aim also needs `debug.getupvalue` and `debug.setupvalue`. Tested on Madium only.

## Notes

- Silent Aim's newest change, ignoring the invisible Halloween web sheets when checking line of sight, hasn't been tested live. It's also unknown whether real pellets pass through those webs.
- The game has a votekick and player reports, so use an alt.
