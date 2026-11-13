# blind but dangerous

Script for [blind but dangerous](https://www.roblox.com/games/112270456220062), with a Fluent menu.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/killllllformatt/vibecodemods-roblox/main/blind-but-dangerous/bbd_hub.luau"))()
```

Press **RightCtrl** to open or close the menu. Running the script again unloads the old copy first and keeps your toggles.

## Features

The menu is split into sections inside each tab, most-used first.

**Blind Man**
- *Vision*
  - See While Blind: a normal, bright view during your blind rounds, including free-for-all and infected rounds. **F6** toggles it.
- *Shotgun*
  - No Shotgun Recoil: skips the knockback and camera flip when you fire.
  - Silent Aim: sends your shots to the visible target nearest your crosshair, with an FOV slider and circle. Shots are aimed from your head, like the game's own. The Status tab shows what the last shot did: who it picked, or why it didn't redirect.
- *Gadget Counters*
  - Anti Funky Stim: when a hider stims you, you keep walking, skip the dance and get your shotgun back right away. The server still won't take shots until the 5-second stim ends.
  - Anti Scary Serum: when a hider uses the Scary Serum on you, your controls stay normal and the fake footsteps and coughs don't play.

**Hider**
- *Stealth & Escape*
  - Always Sneak: stays in sneak during rounds at normal walking speed. You still make some noise, but much less than walking.
  - Auto Grab Escape: breaks free of grabs without mashing, about 2.5 seconds in.
- *Gadget Counters*
  - Anti Hearing Aids: when the blind man uses Hearing Aids, the heart minigame never shows up, you don't get frozen, and he never gets your heartbeat.
  - Anti Blackout: when the blind man uses Night Vision, you skip the 15-second power outage (dark, black fog, lights off) and the forced first person that comes with it.
  - Auto Hang Up: when someone calls you with the Phone, it hangs up for you, so your phone rings for under a second instead of 10 and doesn't give away where you are.
  - Auto Phone Popup: closes the blind man's Phone popup ads for you. **Untested in a real round**, so it may be ignored.
- *Injections*
  - Auto Inject: uses your Funky Stim or Scary Serum on the blind man as soon as he's within range and it's off cooldown, then puts your previous item back. Keeps going every cooldown while it's on.
  - Teleport to Inject: no range limit. Teleports you behind the blind man for the injection (the server only accepts about 11 studs). Only acts when you have a serum or stim ready.
  - Teleport Back After: returns you to where you were afterwards (on by default).
- *Bear Traps*
  - Trap ESP: shows the blind man's bear traps through walls. Orange is armed, red has caught someone.
  - Auto Disarm: disarms armed traps within 7 studs of you. Traps snap shut at about 3 studs, so walk past them, not over them.
  - Auto Break Free: starts breaking free the moment you're caught and keeps holding. Out in about 4 seconds.
  - Auto Help Teammates: helps free a caught teammate within 6 studs.
  - Teleport to Help: Auto Help teleports you to a caught teammate from anywhere and keeps you there until they're free (off by default). Return After Helping takes you back afterwards.

**Misc**
- *Visuals*
  - Player Outlines: draws players and bots through walls. Red is the blind man or infected, white is a hider. Takes over from the game's own blind-man outline, which only shows him when he's in plain view, and from the red flash on the blind man at round start.
  - Anti Screen Shake: removes shake from the blind man, gunshots, the megaphone, grabs and firecrackers. Firecracker blur, tint and deafness still play.
- *Movement*
  - No Slowdown: during rounds, if anything drops your speed below normal for your role, it gets put back. Covers Hearing Aids, the Witch Brew, the Funky Stim, the bear-trap limp and anything new. It can't pull you out of a bear trap; the server holds you in place.
  - Jump: lets you jump again (the game turns jumping off). Keep Anti Fall Ragdoll on, or landings ragdoll you.
  - Anti Push: ignores the fling and ragdoll when someone pushes you, as either role.
  - Anti Fall Ragdoll: no ragdoll from falling or long jumps, as either role.
- *Safety*
  - Staff Alert: warns you when a listed owner, admin or mod is in the server.
  - Anti AFK: blocks Roblox's idle kick and turns the game's AFK mode back off when the server switches it on, so you keep getting put in rounds. As the blind man it also steps you a few studs after 12 seconds standing still, because the server ends the round if the blind man doesn't move for 25 seconds.
- *Hub*
  - Unload Hub: removes the menu and turns everything off.

**Status**
- Shows your role, the blind man, hiders alive, the mode, shells, coins and staff in the server, plus whether each feature is working.

## Executor support

See While Blind's hide hook, No Recoil, Silent Aim and the Phone popup's clean finish need `getgc`, `hookfunction` and `islclosure`. Anti Push and the grab part of Anti Screen Shake need `getconnections` and `hookfunction`. Anti Scary Serum needs `getgc`, `hookfunction` and `debug.getconstants`. Anti Hearing Aids and Anti Blackout need `getgc` and `hookfunction`; Anti Fall Ragdoll needs `getconnections` and `hookfunction`. Anti AFK uses `getconnections`. Silent Aim also needs `debug.getupvalue` and `debug.setupvalue`. Tested on Madium only.

## Notes

- Silent Aim's newest change, ignoring the invisible Halloween web sheets when checking line of sight, hasn't been tested live. It's also unknown whether real pellets pass through those webs.
- The game has a votekick and player reports, so use an alt.
