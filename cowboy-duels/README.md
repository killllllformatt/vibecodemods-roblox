# Cowboy DUELS

Script for [Cowboy DUELS](https://www.roblox.com/games/131103239963274), with a Fluent menu.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/killllllformatt/vibecodemods-roblox/main/cowboy-duels/cowboy_duels.luau"))()
```

To open or close the menu, press **RightCtrl** on PC, or tap the **CD** button on mobile. Running the script again unloads the old copy first.

## Features

**Silent aim**
- Works with the revolver, knife throws and lasso throws. It changes the aim point inside the game's own fire functions, so the shots are the game's real shots.
- Targets the closest visible enemy inside the FOV circle, or the closest visible enemy anywhere.
- Target part: Head or Torso.
- Knife and lasso throws aim ahead of moving targets. The knife reaches 150 studs and the lasso 40.

**Aimbot**
- Locks your camera onto a target while you hold the aim key (RMB by default), or keeps it on all the time with "Always on".
- First person mode rotates the camera. Third person mode moves the cursor.
- Smoothing setting.
- Sticky lock that briefly holds a target when it goes behind cover.
- Uses the same target as silent aim.

**ESP**
- Enemies and teammates in separate colors, drawn through walls, with name, HP and distance.
- Hides the game's own red and blue highlights while it's on, and gives them back when it's off.
- Coin ESP for the event coins.

**Lasso**
- Auto-escape: when you're lassoed, it sends the escape taps for you.

## Executor support

Silent aim needs `getgc`, `hookfunction` and `islclosure`. If your executor is missing any of these, the script tells you which ones on load. The aimbot, ESP and auto-escape still work. Third person aimbot needs `mousemoverel`.

On mobile, the FOV circle centers on the game's crosshair, the aimbot defaults to Always on, and a draggable **CD** button opens the menu.

## Notes

- The server enforces the revolver's 2 s cooldown, so rapid fire isn't possible.
- Knife stabs can't be silent-aimed, because the game doesn't send any aim data for them.
- The game's description says exploiting gets a permanent ban. Use an alt.
