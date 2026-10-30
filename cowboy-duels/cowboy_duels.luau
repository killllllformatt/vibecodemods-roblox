--[[
	Cowboy DUELS — silent aim + ESP (Fluent UI)

	Silent aim: hooks each revolver's own `tryFireAtAim` closure (found via getgc,
	bound by getfenv(f).script == tool.Client) and swaps the aim point for the best
	visible enemy part. The real fire pipeline builds the packet; handmade
	FireRequest packets get rejected server-side, so we never send our own.

	ESP: our own Highlight + Billboard per enemy. While it is on, the game's red
	enemy highlights (DuelEnemyHighlight) are disabled in place; the player's
	`EnemyRedHighlight` setting is never touched. Turning our ESP off or
	unloading re-enables exactly the ones we disabled.

	Re-executing unloads the previous instance first.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local G = getgenv()
if G.CowboyDuelsMod and G.CowboyDuelsMod.Unload then
	pcall(G.CowboyDuelsMod.Unload)
end

-- Hooks survive re-execution (a closure can only be hooked once cleanly), so the
-- hook registry and live config live in getgenv and every wrapper reads them.
G.__CD_HOOKED = G.__CD_HOOKED or setmetatable({}, { __mode = "k" })
G.__CD_SA = G.__CD_SA or {}
local Hooked = G.__CD_HOOKED
local SA = G.__CD_SA
SA.Enabled = false
SA.FOV = 180
SA.UseFOV = true
SA.Part = "Head"
SA.Knife = true
SA.Lasso = true
SA.Lock = nil
SA.Pick = nil

local Mod = {}
G.CowboyDuelsMod = Mod

local connections = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

local function log(...)
	print("[CowboyDuels]", ...)
end

-- Notifications raised before the UI exists are queued and shown once it loads.
local pendingNotes = {}
local function notify(title, content, duration)
	log(title .. ": " .. content)
	if Mod.Fluent then
		Mod.Fluent:Notify({ Title = title, Content = content, Duration = duration or 6 })
	else
		table.insert(pendingNotes, { title, content, duration })
	end
end

--------------------------------------------------------------------------------
-- Executor capabilities / platform
--------------------------------------------------------------------------------
-- Silent aim needs to find the game's own fire/aim closures (getgc, islclosure)
-- and replace them (hookfunction). Without those it can't work at all; the
-- aimbot, ESP and auto-escape don't need them.

local CAPS = { missingSA = {} }
for name, fn in pairs({ getgc = getgc, hookfunction = hookfunction, islclosure = islclosure }) do
	if type(fn) ~= "function" then
		table.insert(CAPS.missingSA, name)
	end
end
table.sort(CAPS.missingSA)
CAPS.silentAim = #CAPS.missingSA == 0
CAPS.mouseMove = type(mousemoverel) == "function"

-- Phones/tablets: no keyboard or mouse. The game aims touch shots from screen
-- center (ControllerAim.GetViewportPosition), so that is our FOV center too.
-- getgenv().CD_FORCE_TOUCH = true forces the mobile layout for testing on PC.
local IS_TOUCH = G.CD_FORCE_TOUCH == true
	or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled)

--------------------------------------------------------------------------------
-- Duel / enemy logic (mirrors DuelEnemyHighlightClient.isEnemy)
--------------------------------------------------------------------------------

local function attr(player, character, name)
	if player then
		local v = player:GetAttribute(name)
		if v ~= nil then
			return v
		end
	end
	return character and character:GetAttribute(name)
end

-- "enemy" / "ally" for a live combatant in our duel, nil for everyone else
-- (us, lobby players, other duels, dead spectators, map vote).
local function duelRelation(character)
	if not character or character == LocalPlayer.Character then
		return nil
	end
	if not character:IsDescendantOf(workspace) then
		return nil
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return nil
	end
	local mySession = LocalPlayer:GetAttribute("DuelSessionId")
	local myTeam = LocalPlayer:GetAttribute("DuelTeam")
	if mySession == nil or myTeam == nil then
		return nil
	end
	if LocalPlayer:GetAttribute("DuelInGame") ~= true or LocalPlayer:GetAttribute("DuelMapVoting") == true then
		return nil
	end
	local plr = Players:GetPlayerFromCharacter(character)
	if plr == LocalPlayer then
		return nil
	end
	if attr(plr, character, "DuelSessionId") ~= mySession then
		return nil
	end
	local team = attr(plr, character, "DuelTeam")
	if team == nil then
		return nil
	end
	if attr(plr, character, "DuelDeadSpectating") == true or attr(plr, character, "DuelMapVoting") == true then
		return nil
	end
	-- Team ids have shown up as both numbers and strings; compare loosely.
	return tostring(team) == tostring(myTeam) and "ally" or "enemy"
end

local function isEnemy(character)
	return duelRelation(character) == "enemy"
end

local function isTeammate(character)
	return duelRelation(character) == "ally"
end

-- Combatants come from player characters; bots/AI rigs in tutorial matches
-- carry the duel attributes on the model itself, so the arena folder is
-- scanned too.
local function getCombatants(pred)
	local list, seen = {}, {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		if ch and not seen[ch] and pred(ch) then
			seen[ch] = true
			table.insert(list, ch)
		end
	end
	local session = LocalPlayer:GetAttribute("DuelSessionId")
	local games = session and workspace:FindFirstChild("ActiveGames")
	if games then
		for _, arena in ipairs(games:GetChildren()) do
			if arena.Name:match("^Game_" .. tostring(session) .. "_") then
				for _, m in ipairs(arena:GetChildren()) do
					if m:IsA("Model") and not seen[m] and m:FindFirstChildOfClass("Humanoid") and pred(m) then
						seen[m] = true
						table.insert(list, m)
					end
				end
			end
		end
	end
	return list
end

local function getEnemies()
	return getCombatants(isEnemy)
end

local function getTeammates()
	return getCombatants(isTeammate)
end

--------------------------------------------------------------------------------
-- Silent aim
--------------------------------------------------------------------------------

local RevolverHitbox
pcall(function()
	RevolverHitbox = require(ReplicatedStorage.Shared.Module.RevolverHitbox)
end)

local PART_ORDER = {
	Head = { "Head", "UpperTorso", "Torso", "HumanoidRootPart" },
	Torso = { "UpperTorso", "Torso", "HumanoidRootPart", "Head" },
}

-- Per weapon: `fns` are debug names of local functions in the tool's
-- LocalScript `script`; `marker` is a child that identifies the tool.
-- mode "arg": the function takes the aim point as its first argument.
-- mode "return": the function computes and returns the aim point.
local WEAPONS = {
	revolver = { fns = { "tryFireAtAim" }, mode = "arg", script = "Client", marker = "FireRequest" },
	-- Knife throws are a 96.48 studs/s projectile with a 150 stud cap
	-- (ActivatedScript.predictThrow / KnifeThrowLocal). Melee sends no aim
	-- data at all, so only throws can be redirected.
	knife = {
		fns = { "doThrow" },
		mode = "arg",
		script = "ActivatedScript",
		marker = "Throw",
		speed = 96.48,
		range = 150,
	},
	-- The lasso cast reads its aim after the wind-up from getAimPosition, or
	-- getCharacterForwardAimPosition for forward throws; both normal and
	-- offhand ("QuickLasso") throws go through them. LassoConfig.ThrowFeel:
	-- Speed 85, MaxLength 40.
	lasso = {
		-- On touch the cast pre-computes its aim with getAimPositionFromScreen
		-- (from the last tap) and skips getAimPosition, so that is hooked too.
		fns = { "getAimPosition", "getCharacterForwardAimPosition", "getAimPositionFromScreen" },
		mode = "return",
		script = "LassoClient",
		marker = "CastLasso",
		speed = 85,
		range = 40,
		part = "HumanoidRootPart",
	},
}

local function weaponKind(tool)
	if not tool:IsA("Tool") then
		return nil
	end
	for kind, w in pairs(WEAPONS) do
		if tool:FindFirstChild(w.marker) and tool:FindFirstChild(w.script) then
			return kind
		end
	end
	return nil
end

local function equippedTool(kind)
	local ch = LocalPlayer.Character
	if not ch then
		return nil
	end
	for _, t in ipairs(ch:GetChildren()) do
		if weaponKind(t) == kind then
			return t
		end
	end
	return nil
end

local function exclusions(target, tool)
	local ch = LocalPlayer.Character
	local list
	if RevolverHitbox and RevolverHitbox.getRaycastExclusions then
		local ok, res = pcall(RevolverHitbox.getRaycastExclusions, ch, tool)
		if ok and type(res) == "table" then
			list = table.clone(res)
		end
	end
	list = list or { ch, tool }
	table.insert(list, target)
	return list
end

-- Clear line from the head (server's origin for both weapons) and, for the
-- revolver, from the muzzle as well.
local function visible(target, point, kind)
	local ch = LocalPlayer.Character
	local head = ch and ch:FindFirstChild("Head")
	if not head then
		return false
	end
	local tool = equippedTool(kind)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclusions(target, tool)
	params.IgnoreWater = true
	local origins = { head.Position }
	local handle = kind == "revolver" and tool and tool:FindFirstChild("Handle")
	if handle then
		table.insert(origins, handle.Position)
	end
	for _, o in ipairs(origins) do
		local dir = point - o
		if dir.Magnitude > 0.05 and workspace:Raycast(o, dir, params) then
			return false
		end
	end
	return true
end

local function aimCenter()
	if IS_TOUCH then
		-- GetMouseLocation on touch is just the last finger position.
		return workspace.CurrentCamera.ViewportSize * 0.5
	end
	return UserInputService:GetMouseLocation()
end

-- Where a projectile fired from `origin` meets `part` if the target keeps its
-- current velocity. Vertical velocity is dropped while grounded so a running
-- target's bob doesn't throw the lead off.
local function leadPoint(part, enemy, origin, speed)
	local root = enemy:FindFirstChild("HumanoidRootPart") or part
	local vel = root.AssemblyLinearVelocity
	local hum = enemy:FindFirstChildOfClass("Humanoid")
	if hum and hum.FloorMaterial ~= Enum.Material.Air then
		vel = Vector3.new(vel.X, 0, vel.Z)
	end
	local p = part.Position
	for _ = 1, 3 do
		local t = (p - origin).Magnitude / speed
		p = part.Position + vel * t
	end
	return p
end

local function partOrder(kind)
	local w = WEAPONS[kind]
	-- The lasso wants the body, not the head: it catches whoever the rope reaches.
	return w.part and { w.part, "UpperTorso", "Torso" } or PART_ORDER[SA.Part] or PART_ORDER.Head
end

-- Best point to send at `enemy` for weapon `kind`: the first part in priority
-- order that is visible (and, for projectiles, whose lead point is visible and
-- in range). Returns point, part.
local function aimPointFor(enemy, kind)
	local w = WEAPONS[kind]
	local ch = LocalPlayer.Character
	local head = ch and ch:FindFirstChild("Head")
	if not head then
		return nil
	end
	for _, name in ipairs(partOrder(kind)) do
		local part = enemy:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local point = part.Position
			if w.speed then
				point = leadPoint(part, enemy, head.Position, w.speed)
			end
			local inRange = not w.range or (point - head.Position).Magnitude <= w.range
			-- The lead point can sit inside a wall the body isn't behind, so
			-- check both the body and the lead.
			if
				inRange
				and visible(enemy, part.Position, kind)
				and (point == part.Position or visible(enemy, point, kind))
			then
				return point, part
			end
		end
	end
	return nil
end

-- How good a candidate is: pixels from the cursor (FOV mode) or studs from us.
-- nil = outside the FOV / off screen.
local function targetScore(enemy, kind, fov)
	local ref
	for _, name in ipairs(partOrder(kind)) do
		ref = enemy:FindFirstChild(name)
		if ref and ref:IsA("BasePart") then
			break
		end
		ref = nil
	end
	if not ref then
		return nil
	end
	if fov then
		local sp, onScreen = workspace.CurrentCamera:WorldToViewportPoint(ref.Position)
		if not onScreen then
			return nil
		end
		local d = (Vector2.new(sp.X, sp.Y) - aimCenter()).Magnitude
		return d <= fov and d or nil
	end
	local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	return myRoot and (ref.Position - myRoot.Position).Magnitude or 0
end

local function bestTarget(kind, fov)
	local candidates = {}
	for _, enemy in ipairs(getEnemies()) do
		local score = targetScore(enemy, kind, fov)
		if score then
			table.insert(candidates, { enemy = enemy, score = score })
		end
	end
	table.sort(candidates, function(a, b)
		return a.score < b.score
	end)
	-- Visibility raycasts are the expensive part; stop at the first hit.
	for _, c in ipairs(candidates) do
		local point = aimPointFor(c.enemy, kind)
		if point then
			return point, c.enemy
		end
	end
	return nil
end

local function pickTarget(kind)
	kind = kind or "revolver" -- hooks installed by older runs call Pick()
	-- An aimbot lock wins over the FOV pick so both always shoot the same
	-- person, as long as that person is still a valid, hittable enemy.
	local lock = SA.Lock
	if lock and isEnemy(lock) then
		local point = aimPointFor(lock, kind)
		if point then
			return point, lock
		end
	end
	return bestTarget(kind, SA.UseFOV and SA.FOV or nil)
end
SA.Pick = pickTarget

local function hookClosure(f, kind)
	if Hooked[f] then
		return false
	end
	local mode = WEAPONS[kind].mode
	local function pick()
		local cfg = getgenv().__CD_SA
		if not (cfg and cfg.Enabled and cfg.Pick) then
			return nil
		end
		if (kind == "knife" and not cfg.Knife) or (kind == "lasso" and not cfg.Lasso) then
			return nil
		end
		local ok, pos = pcall(cfg.Pick, kind)
		return ok and typeof(pos) == "Vector3" and pos or nil
	end
	local old
	local ok, err = pcall(function()
		if mode == "return" then
			old = hookfunction(f, function(...)
				return pick() or old(...)
			end)
		else
			old = hookfunction(f, function(aimPos, ...)
				return old(pick() or aimPos, ...)
			end)
		end
	end)
	if not ok or type(old) ~= "function" then
		-- hookfunction exists but can't hook Luau closures on this executor.
		if CAPS.silentAim then
			CAPS.silentAim = false
			SA.Enabled = false
			if Mod.Fluent and Mod.Fluent.Options.SAEnabled then
				Mod.Fluent.Options.SAEnabled:SetValue(false)
			end
			notify(
				"Silent aim unavailable",
				"Your executor's hookfunction failed (" .. tostring(err) .. "). Aimbot, ESP and auto-escape still work.",
				10
			)
		end
		return false
	end
	Hooked[f] = kind
	return true
end

-- getgc is heavy in this game (~35k modules), so only scan when a weapon shows
-- up whose fire closure we haven't hooked yet.
local toolHooked = setmetatable({}, { __mode = "k" })

local function closureFor(f, w, src)
	local ok, name = pcall(debug.info, f, "n")
	if ok and table.find(w.fns, name) then
		local okEnv, env = pcall(getfenv, f)
		return okEnv and env and rawget(env, "script") == src
	end
	return false
end

local function scanForTool(tool, kind)
	local w = WEAPONS[kind]
	local src = tool:FindFirstChild(w.script)
	if not src then
		return 0
	end
	local n = 0
	for _, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) and not Hooked[f] and closureFor(f, w, src) then
			if hookClosure(f, kind) then
				n += 1
			end
		end
	end
	return n
end

local function alreadyHooked(tool, kind)
	local src = tool:FindFirstChild(WEAPONS[kind].script)
	for f in pairs(Hooked) do
		local okEnv, env = pcall(getfenv, f)
		if okEnv and env and rawget(env, "script") == src then
			return true
		end
	end
	return false
end

local function watchTool(tool)
	if not CAPS.silentAim then
		return -- nothing to hook with; the UI tells the user why
	end
	local kind = weaponKind(tool)
	if not kind or toolHooked[tool] then
		return
	end
	toolHooked[tool] = "pending"
	task.spawn(function()
		-- The LocalScript needs a moment to run after the tool lands in Backpack.
		for _ = 1, 12 do
			if not tool.Parent then
				break
			end
			local ok, n = pcall(scanForTool, tool, kind)
			if ok and n > 0 then
				toolHooked[tool] = true
				log("hooked", kind, tool.Name)
				return
			end
			-- Already hooked by a previous execution of this script.
			if ok and alreadyHooked(tool, kind) then
				toolHooked[tool] = true
				return
			end
			task.wait(0.5)
		end
		toolHooked[tool] = nil
		log("could not find", table.concat(WEAPONS[kind].fns, "/"), "for", tool:GetFullName())
	end)
end

local function watchContainer(container)
	for _, t in ipairs(container:GetChildren()) do
		watchTool(t)
	end
	bind(container.ChildAdded, watchTool)
end

watchContainer(LocalPlayer:WaitForChild("Backpack"))
if LocalPlayer.Character then
	watchContainer(LocalPlayer.Character)
end
bind(LocalPlayer.CharacterAdded, watchContainer)
-- Backpack is replaced on respawn.
bind(LocalPlayer.ChildAdded, function(c)
	if c:IsA("Backpack") then
		watchContainer(c)
	end
end)

--------------------------------------------------------------------------------
-- Lasso auto-escape
--------------------------------------------------------------------------------
-- When caught, the server stamps LassoCaptureId on the victim's character and
-- LassoEscapeClient sends LassoRemote:FireServer("EscapeTap", tostring(id)) per
-- EscapeLasso key press, stopping its own count at 10.

local LassoRemote = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"):WaitForChild("LassoRemote")

local Escape = { Enabled = false, Taps = 10, Interval = 0.05, running = nil }

local function captureId()
	local ch = LocalPlayer.Character
	local id = ch and ch:GetAttribute("LassoCaptureId")
	return id ~= nil and tostring(id) or nil
end

local function runEscape()
	local id = captureId()
	if not (Escape.Enabled and id) or Escape.running == id then
		return
	end
	Escape.running = id
	task.spawn(function()
		-- Keep tapping until the capture clears, in case the server wants more
		-- than the client's 10 or drops taps sent too fast.
		local sent = 0
		local deadline = os.clock() + 6
		while Escape.Enabled and captureId() == id and os.clock() < deadline do
			LassoRemote:FireServer("EscapeTap", id)
			sent += 1
			task.wait(Escape.Interval)
		end
		Escape.lastResult = { id = id, taps = sent, escaped = captureId() ~= id }
		if Escape.running == id then
			Escape.running = nil
		end
	end)
end

local escapeCharConn
local function bindEscapeCharacter(ch)
	if escapeCharConn then
		escapeCharConn:Disconnect()
	end
	escapeCharConn = bind(ch:GetAttributeChangedSignal("LassoCaptureId"), runEscape)
	runEscape()
end
if LocalPlayer.Character then
	bindEscapeCharacter(LocalPlayer.Character)
end
bind(LocalPlayer.CharacterAdded, bindEscapeCharacter)
-- The attribute can land before or after the server's "Start" event.
bind(LassoRemote.OnClientEvent, function(action, _, victim)
	if action == "Start" and victim == LocalPlayer then
		task.defer(runEscape)
	end
end)

--------------------------------------------------------------------------------
-- FOV circle
--------------------------------------------------------------------------------

local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
local fovGui = Instance.new("ScreenGui")
fovGui.Name = "CD_FOV"
fovGui.IgnoreGuiInset = true
fovGui.ResetOnSpawn = false
fovGui.DisplayOrder = 999
fovGui.Parent = guiParent

local fovCircle = Instance.new("Frame")
fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
fovCircle.BackgroundTransparency = 1
fovCircle.Visible = false
fovCircle.Parent = fovGui
Instance.new("UICorner", fovCircle).CornerRadius = UDim.new(1, 0)
local fovStroke = Instance.new("UIStroke", fovCircle)
fovStroke.Color = Color3.fromRGB(255, 255, 255)
fovStroke.Transparency = 0.35
fovStroke.Thickness = 1.5

local showFOV = true
local function inDuel()
	return LocalPlayer:GetAttribute("DuelInGame") == true
end

--------------------------------------------------------------------------------
-- Aimbot
--------------------------------------------------------------------------------
-- Replaces Exunys' Universal Aimbot V3 (Downloads\Aimbot.lua): same idea (hold a
-- key, camera locks onto the FOV target) but on our targeting, so it shares the
-- enemy check, wall check, body part order and projectile lead with silent aim.
-- While locked, `SA.Lock` makes silent aim shoot the same person.

local Aim = {
	Enabled = false,
	Mode = "Camera", -- "Camera": rotate the camera; "Mouse": mousemoverel the cursor
	Smooth = 0.5, -- 0 = snap; per-frame decay at 60 fps, frame-rate independent
	Always = IS_TOUCH, -- no key to hold on a phone: aim whenever combat is live
	UseFOV = true,
	Sticky = true,
	HiddenGrace = 0.3, -- seconds a locked target may stay unhittable before release
	keyHeld = function()
		return false
	end,
	locked = nil,
	hiddenAt = nil,
}

local function equippedKind()
	local ch = LocalPlayer.Character
	if ch then
		for _, t in ipairs(ch:GetChildren()) do
			local k = weaponKind(t)
			if k then
				return k
			end
		end
	end
	return "revolver"
end

local function releaseLock()
	Aim.locked = nil
	Aim.hiddenAt = nil
	SA.Lock = nil
end

-- Every reason not to touch the camera: typing, not in a live duel, dead or
-- spectating, kill cam / spawn camera (non-Custom or not following us).
local function canAim()
	if not (Aim.Enabled and (Aim.Always or Aim.keyHeld())) then
		return false
	end
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	if not inDuel() or LocalPlayer:GetAttribute("DuelMapVoting") == true then
		return false
	end
	if LocalPlayer:GetAttribute("DuelDeadSpectating") == true or LocalPlayer:GetAttribute("DuelSpectating") == true then
		return false
	end
	local ch = LocalPlayer.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return false
	end
	local cam = workspace.CurrentCamera
	return cam ~= nil and cam.CameraType == Enum.CameraType.Custom and cam.CameraSubject == hum
end

local function aimStep(dt)
	if not canAim() then
		if Aim.locked then
			releaseLock()
		end
		return
	end

	local kind = equippedKind()
	local lock = Aim.locked
	if lock and (not Aim.Sticky or not isEnemy(lock)) then
		lock = nil -- died, left, round over, or re-pick every frame when not sticky
	end

	local point
	if lock then
		point = aimPointFor(lock, kind)
		if point then
			Aim.hiddenAt = nil
		else
			-- Behind a wall or out of range: hold briefly so peeking past a
			-- pillar doesn't drop the lock, then let go.
			Aim.hiddenAt = Aim.hiddenAt or os.clock()
			if os.clock() - Aim.hiddenAt > Aim.HiddenGrace then
				lock = nil
			end
		end
	end
	if not lock then
		Aim.hiddenAt = nil
		point, lock = bestTarget(kind, Aim.UseFOV and SA.FOV or nil)
	end

	Aim.locked = lock
	SA.Lock = lock
	if not point then
		return
	end

	local alpha = Aim.Smooth <= 0 and 1 or 1 - Aim.Smooth ^ (dt * 60)
	local cam = workspace.CurrentCamera
	if Aim.Mode == "Mouse" and mousemoverel then
		local sp, onScreen = cam:WorldToViewportPoint(point)
		if onScreen then
			local m = UserInputService:GetMouseLocation()
			mousemoverel((sp.X - m.X) * alpha, (sp.Y - m.Y) * alpha)
		end
	else
		-- Runs right after the camera scripts (Camera+1), so they don't
		-- overwrite it this frame; PlayerModule reads the new look vector
		-- back next frame, so the rotation sticks instead of snapping back.
		local cf = cam.CFrame
		cam.CFrame = cf:Lerp(CFrame.lookAt(cf.Position, point), alpha)
	end
end

local AIM_STEP = "CD_Aimbot"
RunService:BindToRenderStep(AIM_STEP, Enum.RenderPriority.Camera.Value + 1, function(dt)
	local ok, err = pcall(aimStep, dt)
	if not ok then
		releaseLock()
		log("aimbot error:", err)
	end
end)

bind(RunService.RenderStepped, function()
	local saOn = SA.Enabled and SA.UseFOV
	local aimOn = Aim.Enabled and Aim.UseFOV
	local on = (saOn or aimOn) and showFOV and inDuel()
	fovCircle.Visible = on
	if on then
		local m = aimCenter()
		fovCircle.Position = UDim2.fromOffset(m.X, m.Y)
		fovCircle.Size = UDim2.fromOffset(SA.FOV * 2, SA.FOV * 2)
		fovStroke.Color = Aim.locked and Color3.fromRGB(255, 120, 120) or Color3.fromRGB(255, 255, 255)
	end
end)

--------------------------------------------------------------------------------
-- ESP
--------------------------------------------------------------------------------

local ESP = {
	Enabled = false,
	Highlight = true,
	Labels = true,
	Color = Color3.fromRGB(255, 170, 40),
	Teammates = true,
	TeamColor = Color3.fromRGB(80, 230, 120),
}

local espFolder = Instance.new("Folder")
espFolder.Name = "CD_ESP"
espFolder.Parent = guiParent

local espObjects = {} -- [model] = { hl, bb, label }

local function removeEsp(model)
	local o = espObjects[model]
	if o then
		o.hl:Destroy()
		o.bb:Destroy()
		espObjects[model] = nil
	end
end

local function clearEsp()
	for m in pairs(espObjects) do
		removeEsp(m)
	end
end

local function makeEsp(model)
	local hl = Instance.new("Highlight")
	hl.Name = "CD_ESP_HL"
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillTransparency = 0.65
	hl.OutlineTransparency = 0
	hl.Adornee = model
	hl.Parent = espFolder

	local bb = Instance.new("BillboardGui")
	bb.Name = "CD_ESP_BB"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(200, 34)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
	bb.LightInfluence = 0
	bb.Adornee = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
	bb.Parent = espFolder

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextStrokeTransparency = 0.4
	label.RichText = false
	label.Parent = bb

	local o = { hl = hl, bb = bb, label = label }
	espObjects[model] = o
	return o
end

-- Game highlight suppression. The game draws its own:
--   DuelEnemyHighlight (red, DuelEnemyHighlightClient, gated by the player's
--     server-owned `EnemyRedHighlight` setting, which we never touch)
--   DuelAllyHighlight  (blue, TeamHighlightClient, always on)
-- Both are muted by making them fully transparent rather than Enabled=false:
-- TeamHighlightClient re-sets Enabled=true on every refresh (attribute
-- changes, respawns, a 0.25 s bot loop), but only sets transparency when it
-- creates the highlight. Original transparencies are restored on release.
-- Enemy ones are muted whenever our ESP is on; ally ones only while our ESP
-- is actually drawing teammates, so allies are never left unmarked.
local GameESP = { names = {}, muted = setmetatable({}, { __mode = "k" }) }

local GAME_HIGHLIGHTS = { DuelEnemyHighlight = true, DuelAllyHighlight = true }

local function muteGameHighlight(h)
	if GameESP.muted[h] then
		return
	end
	GameESP.muted[h] = { h.FillTransparency, h.OutlineTransparency }
	h.FillTransparency = 1
	h.OutlineTransparency = 1
end

local function unmuteGameHighlight(h)
	local saved = GameESP.muted[h]
	if saved then
		GameESP.muted[h] = nil
		if h.Parent then
			h.FillTransparency, h.OutlineTransparency = saved[1], saved[2]
		end
	end
end

local function sweepGameHighlights()
	local function check(inst)
		if inst and GameESP.names[inst.Name] and inst:IsA("Highlight") then
			muteGameHighlight(inst)
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		if ch then
			for name in pairs(GameESP.names) do
				check(ch:FindFirstChild(name))
			end
		end
	end
	local games = workspace:FindFirstChild("ActiveGames")
	if games then
		for _, d in ipairs(games:GetDescendants()) do
			check(d)
		end
	end
end

-- Recompute which game highlights to hide from the current ESP settings.
local function refreshGameSuppression()
	local names = {}
	if ESP.Enabled then
		names.DuelEnemyHighlight = true
		if ESP.Teammates then
			names.DuelAllyHighlight = true
		end
	end
	GameESP.names = names
	for h in pairs(GameESP.muted) do
		if not names[h.Name] then
			unmuteGameHighlight(h)
		end
	end
	if next(names) then
		sweepGameHighlights()
	end
end

bind(workspace.DescendantAdded, function(inst)
	if GAME_HIGHLIGHTS[inst.Name] and GameESP.names[inst.Name] then
		-- The game sets its transparencies right after parenting; wait for that.
		task.defer(function()
			if inst.Parent and inst:IsA("Highlight") and GameESP.names[inst.Name] then
				muteGameHighlight(inst)
			end
		end)
	end
end)

local espAccum = 0
bind(RunService.Heartbeat, function(dt)
	if not ESP.Enabled then
		return
	end
	espAccum += dt
	if espAccum < 0.1 then
		return
	end
	espAccum = 0

	-- Belt and braces in case an add event was missed (streaming, reparent).
	sweepGameHighlights()

	local alive = {}
	local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	local function draw(model, color)
		alive[model] = true
		local o = espObjects[model] or makeEsp(model)
		if not o.bb.Adornee or not o.bb.Adornee:IsDescendantOf(model) then
			o.bb.Adornee = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
		end
		o.hl.Enabled = ESP.Highlight
		o.hl.FillColor = color
		o.hl.OutlineColor = color
		o.bb.Enabled = ESP.Labels
		if ESP.Labels then
			local hum = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			local dist = (myRoot and root) and math.floor((root.Position - myRoot.Position).Magnitude) or 0
			local plr = Players:GetPlayerFromCharacter(model)
			o.label.Text = string.format(
				"%s  [%d HP]  %dm",
				plr and plr.DisplayName or model.Name,
				hum and math.floor(hum.Health) or 0,
				dist
			)
			o.label.TextColor3 = color
		end
	end
	for _, enemy in ipairs(getEnemies()) do
		draw(enemy, ESP.Color)
	end
	if ESP.Teammates then
		for _, mate in ipairs(getTeammates()) do
			draw(mate, ESP.TeamColor)
		end
	end
	-- Round over, died, left, map vote, respawned into a new model, or
	-- teammates turned off…
	for model in pairs(espObjects) do
		if not alive[model] then
			removeEsp(model)
		end
	end
end)

local function setEsp(on)
	ESP.Enabled = on
	refreshGameSuppression()
	if not on then
		clearEsp()
	end
end

local function setTeammateEsp(on)
	ESP.Teammates = on
	refreshGameSuppression() -- hand allies back to the game's blue highlight when off
end

--------------------------------------------------------------------------------
-- Coin ESP
--------------------------------------------------------------------------------
-- Event coins are client-local: EventCoinClient clones them into
-- Workspace.LocalEventCoins as EventCoin_<id> each round and destroys them on
-- collect / round clear. The folder itself is recreated per round, so it is
-- looked up every tick instead of cached.

local CoinESP = {
	Enabled = false,
	Color = Color3.fromRGB(255, 215, 0),
}

local coinObjects = {} -- [coinModel] = { bb, label }

local function removeCoinEsp(coin)
	local o = coinObjects[coin]
	if o then
		o.bb:Destroy()
		coinObjects[coin] = nil
	end
end

local function clearCoinEsp()
	for coin in pairs(coinObjects) do
		removeCoinEsp(coin)
	end
end

local function makeCoinEsp(coin)
	local bb = Instance.new("BillboardGui")
	bb.Name = "CD_COIN_BB"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(80, 30)
	bb.LightInfluence = 0
	bb.Adornee = coin.PrimaryPart or coin:FindFirstChildWhichIsA("BasePart", true)
	bb.Parent = espFolder

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.TextStrokeTransparency = 0.3
	label.Parent = bb

	local o = { bb = bb, label = label }
	coinObjects[coin] = o
	return o
end

local coinAccum = 0
bind(RunService.Heartbeat, function(dt)
	if not CoinESP.Enabled then
		return
	end
	coinAccum += dt
	if coinAccum < 0.1 then
		return
	end
	coinAccum = 0

	local alive = {}
	local folder = workspace:FindFirstChild("LocalEventCoins")
	local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	if folder then
		for _, coin in ipairs(folder:GetChildren()) do
			-- Skip coins mid-collect; they vanish as soon as the server confirms.
			if coin:IsA("Model") and coin:GetAttribute("Collecting") ~= true then
				local part = coin.PrimaryPart or coin:FindFirstChildWhichIsA("BasePart", true)
				if part then
					alive[coin] = true
					local o = coinObjects[coin] or makeCoinEsp(coin)
					o.bb.Adornee = part
					local dist = myRoot and math.floor((part.Position - myRoot.Position).Magnitude) or 0
					o.label.Text = string.format("● Coin\n%dm", dist)
					o.label.TextColor3 = CoinESP.Color
				end
			end
		end
	end
	for coin in pairs(coinObjects) do
		if not alive[coin] then
			removeCoinEsp(coin)
		end
	end
end)

local function setCoinEsp(on)
	CoinESP.Enabled = on
	if not on then
		clearCoinEsp()
	end
end

--------------------------------------------------------------------------------
-- UI (Fluent)
--------------------------------------------------------------------------------

local Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()

local Window = Fluent:CreateWindow({
	Title = "Cowboy DUELS",
	SubTitle = "vibecodemods",
	TabWidth = IS_TOUCH and 110 or 140,
	-- Phones in landscape are often ~360 px tall once the topbar is gone.
	Size = IS_TOUCH and UDim2.fromOffset(440, 290) or UDim2.fromOffset(520, 380),
	Acrylic = false,
	Theme = "Dark",
	MinimizeKey = Enum.KeyCode.RightControl,
})
Mod.Fluent = Fluent

local Tabs = {
	Aim = Window:AddTab({ Title = "Silent Aim", Icon = "crosshair" }),
	Aimbot = Window:AddTab({ Title = "Aimbot", Icon = "target" }),
	Esp = Window:AddTab({ Title = "ESP", Icon = "eye" }),
	Lasso = Window:AddTab({ Title = "Lasso", Icon = "link" }),
	Misc = Window:AddTab({ Title = "Settings", Icon = "settings" }),
}

Tabs.Aim:AddToggle("SAEnabled", {
	Title = "Silent aim",
	Description = not CAPS.silentAim and "Not supported by your executor" or nil,
	Default = false,
}):OnChanged(function(v)
	if v and not CAPS.silentAim then
		SA.Enabled = false
		notify(
			"Silent aim unavailable",
			"Your executor doesn't support silent aim (missing: " .. table.concat(CAPS.missingSA, ", ") .. ").",
			8
		)
		task.defer(function()
			Fluent.Options.SAEnabled:SetValue(false)
		end)
		return
	end
	SA.Enabled = v
end)

Tabs.Aim:AddToggle("SAKnife", {
	Title = "Knife throws",
	Description = "Leads moving targets; 150 stud cap. Melee has no aim to redirect",
	Default = true,
}):OnChanged(function(v)
	SA.Knife = v
end)

Tabs.Aim:AddToggle("SALasso", {
	Title = "Lasso throws",
	Description = "Body target, 40 stud cap, leads moving targets",
	Default = true,
}):OnChanged(function(v)
	SA.Lasso = v
end)

Tabs.Aim:AddDropdown("SAPart", {
	Title = "Target part",
	Values = { "Head", "Torso" },
	Default = 1,
	Multi = false,
}):OnChanged(function(v)
	SA.Part = v
end)

Tabs.Aim:AddToggle("SAUseFOV", {
	Title = "Use FOV",
	Description = "Off = closest visible enemy anywhere",
	Default = true,
}):OnChanged(function(v)
	SA.UseFOV = v
end)

Tabs.Aim:AddSlider("SAFOV", {
	Title = "FOV radius",
	Default = 180,
	Min = 30,
	Max = 800,
	Rounding = 0,
	Callback = function(v)
		SA.FOV = v
	end,
})

Tabs.Aim:AddToggle("SAShowFOV", { Title = "Show FOV circle", Default = true }):OnChanged(function(v)
	showFOV = v
end)

Tabs.Aimbot:AddToggle("AimEnabled", {
	Title = "Aimbot",
	Description = "Locks the camera on; silent aim follows the lock",
	Default = false,
}):OnChanged(function(v)
	Aim.Enabled = v
	if not v then
		releaseLock()
	end
end)

Tabs.Aimbot:AddDropdown("AimActivation", {
	Title = "Activation",
	Description = "Always on = locks whenever a round is live (default on mobile)",
	Values = { "Hold key", "Always on" },
	Default = IS_TOUCH and 2 or 1,
	Multi = false,
}):OnChanged(function(v)
	Aim.Always = v == "Always on"
	if not Aim.Always then
		releaseLock()
	end
end)

local aimKey = Tabs.Aimbot:AddKeybind("AimKey", {
	Title = "Aim key",
	Description = "Right-click the bind to switch Hold / Toggle",
	Mode = "Hold",
	Default = "MB2",
})
Aim.keyHeld = function()
	local ok, state = pcall(aimKey.GetState, aimKey)
	return ok and state == true
end

Tabs.Aimbot:AddDropdown("AimMode", {
	Title = "Mode",
	Description = "First person: rotates the view. Third person: moves the cursor",
	Values = { "First person", "Third person" },
	Default = 1,
	Multi = false,
}):OnChanged(function(v)
	if v == "Third person" and (IS_TOUCH or not CAPS.mouseMove) then
		notify(
			"Third person unavailable",
			IS_TOUCH and "There's no cursor to move on mobile; using first person."
				or "Your executor doesn't support mousemoverel; using first person.",
			6
		)
		Aim.Mode = "Camera"
		task.defer(function()
			Fluent.Options.AimMode:SetValue("First person")
		end)
		return
	end
	Aim.Mode = v == "Third person" and "Mouse" or "Camera"
end)

Tabs.Aimbot:AddSlider("AimSmooth", {
	Title = "Smoothness",
	Description = "0 = instant snap",
	Default = 50,
	Min = 0,
	Max = 95,
	Rounding = 0,
	Callback = function(v)
		Aim.Smooth = v / 100
	end,
})

Tabs.Aimbot:AddToggle("AimUseFOV", {
	Title = "Use FOV",
	Description = "Shares the silent aim radius. Off = nearest visible enemy anywhere",
	Default = true,
}):OnChanged(function(v)
	Aim.UseFOV = v
end)

Tabs.Aimbot:AddToggle("AimSticky", {
	Title = "Sticky lock",
	Description = "Stay on one target until it dies or hides; off = re-pick every frame",
	Default = true,
}):OnChanged(function(v)
	Aim.Sticky = v
end)

Tabs.Esp:AddToggle("ESPEnabled", {
	Title = "ESP",
	Description = "Turns the game's red highlight off while on",
	Default = false,
}):OnChanged(function(v)
	setEsp(v)
end)

Tabs.Esp:AddToggle("ESPHighlight", { Title = "Highlight (through walls)", Default = true }):OnChanged(function(v)
	ESP.Highlight = v
end)

Tabs.Esp:AddToggle("ESPLabels", { Title = "Name / HP / distance", Default = true }):OnChanged(function(v)
	ESP.Labels = v
end)

Tabs.Esp:AddColorpicker("ESPColor", { Title = "Enemy color", Default = ESP.Color }):OnChanged(function()
	ESP.Color = Fluent.Options.ESPColor.Value
end)

Tabs.Esp:AddToggle("ESPTeammates", {
	Title = "Show teammates",
	Description = "Off = the game's own blue ally highlight comes back",
	Default = true,
}):OnChanged(function(v)
	setTeammateEsp(v)
end)

Tabs.Esp:AddColorpicker("ESPTeamColor", { Title = "Teammate color", Default = ESP.TeamColor }):OnChanged(function()
	ESP.TeamColor = Fluent.Options.ESPTeamColor.Value
end)

Tabs.Esp:AddToggle("CoinESPEnabled", { Title = "Coin ESP", Default = false }):OnChanged(function(v)
	setCoinEsp(v)
end)

Tabs.Esp:AddColorpicker("CoinESPColor", { Title = "Coin color", Default = CoinESP.Color }):OnChanged(function()
	CoinESP.Color = Fluent.Options.CoinESPColor.Value
end)

Tabs.Lasso:AddToggle("AutoEscape", {
	Title = "Auto-escape lasso",
	Description = "Sends escape taps the moment you're caught",
	Default = false,
}):OnChanged(function(v)
	Escape.Enabled = v
	if v then
		runEscape() -- turned on while already caught
	end
end)

Tabs.Lasso:AddSlider("EscapeInterval", {
	Title = "Tap interval (ms)",
	Default = 50,
	Min = 0,
	Max = 200,
	Rounding = 0,
	Callback = function(v)
		Escape.Interval = v / 1000
	end,
})

Tabs.Misc:AddButton({
	Title = "Unload",
	Description = "Remove hooks' effect, ESP, UI; restore the game's highlight",
	Callback = function()
		Mod.Unload()
	end,
})

Window:SelectTab(1)

-- Phones have no RightCtrl: a small draggable button shows/hides the menu.
local menuButtonGui
if IS_TOUCH then
	menuButtonGui = Instance.new("ScreenGui")
	menuButtonGui.Name = "CD_MenuButton"
	menuButtonGui.ResetOnSpawn = false
	menuButtonGui.DisplayOrder = 1000
	menuButtonGui.Parent = guiParent

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(48, 48)
	btn.Position = UDim2.new(0, 12, 0.5, -24)
	btn.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
	btn.BackgroundTransparency = 0.15
	btn.Text = "CD"
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 16
	btn.AutoButtonColor = true
	btn.Parent = menuButtonGui
	Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)
	local stroke = Instance.new("UIStroke", btn)
	stroke.Color = Color3.fromRGB(255, 170, 40)
	stroke.Thickness = 1.5

	-- Drag with a finger; a short tap (< 8 px of travel) toggles the menu.
	local dragStart, startPos, moved
	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragStart, startPos, moved = input.Position, btn.Position, false
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragStart and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
			local delta = input.Position - dragStart
			if delta.Magnitude > 8 then
				moved = true
			end
			if moved then
				btn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
			end
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		if dragStart and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1) then
			if not moved then
				pcall(Window.Minimize, Window)
			end
			dragStart = nil
		end
	end)
end

Mod.Fluent = Fluent
Mod.Debug = {
	CAPS = CAPS,
	IS_TOUCH = IS_TOUCH,
	SA = SA,
	ESP = ESP,
	GameESP = GameESP,
	espObjects = espObjects,
	getEnemies = getEnemies,
	getTeammates = getTeammates,
	duelRelation = duelRelation,
	coinObjects = coinObjects,
	Escape = Escape,
	Aim = Aim,
	bestTarget = bestTarget,
	aimPointFor = aimPointFor,
}

--------------------------------------------------------------------------------
-- Unload
--------------------------------------------------------------------------------

function Mod.Unload()
	if Mod.unloaded then
		return
	end
	Mod.unloaded = true
	-- Hooks stay installed (closures die with the tool); with Enabled=false and
	-- Pick=nil they pass the original aim straight through.
	SA.Enabled = false
	SA.Pick = nil
	Aim.Enabled = false
	pcall(RunService.UnbindFromRenderStep, RunService, AIM_STEP)
	releaseLock()
	Escape.Enabled = false
	setEsp(false)
	setCoinEsp(false)
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	pcall(function()
		espFolder:Destroy()
	end)
	pcall(function()
		fovGui:Destroy()
	end)
	pcall(function()
		Fluent:Destroy()
	end)
	if menuButtonGui then
		menuButtonGui:Destroy()
	end
	if G.CowboyDuelsMod == Mod then
		G.CowboyDuelsMod = nil
	end
	log("unloaded")
end

Fluent:Notify({
	Title = "Cowboy DUELS",
	Content = IS_TOUCH and "Loaded. Tap the CD button to show/hide the menu." or "Loaded. RightCtrl hides the menu.",
	Duration = 4,
})
if not CAPS.silentAim then
	notify(
		"Silent aim unavailable",
		"Your executor doesn't support silent aim (missing: "
			.. table.concat(CAPS.missingSA, ", ")
			.. "). Aimbot, ESP and auto-escape still work.",
		10
	)
end
for _, n in ipairs(pendingNotes) do
	Fluent:Notify({ Title = n[1], Content = n[2], Duration = n[3] or 6 })
end
table.clear(pendingNotes)
log("loaded")
