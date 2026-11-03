--[[
	blind but dangerous hub (Fluent UI). RightControl minimizes, F6 toggles See While Blind.
	Safe to re-execute: the previous copy cleans itself up first.

	Client-only: See While Blind, Player Outlines, No Recoil, Anti Push, Anti Screen Shake,
	Staff Alert.
	Sends remotes: Auto Grab Escape (Porter "liberer"), Auto Phone (Telephone via the
	game's own terminer), Always Sneak (Discret). Silent Aim redirects the game's own shot.
]]

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local BIND_NAME = "__BBD_SIGHT"
local SHAKE_BIND_SAVE = "__BBD_SHAKE_SAVE"
local SHAKE_BIND_RESTORE = "__BBD_SHAKE_RESTORE"
local BLIND_SKY_NAME = "CielNoir" -- created by VisionAveugle.lumiereNoire, destroyed by restaurer
local SEE_KEY = Enum.KeyCode.F6
local ESCAPE_RETRIES = 3
local ESCAPE_WAIT = 3.5
local ESCAPE_POLL = 0.05
local PHONE_DELAY = 0.8
local OUTLINE_REFRESH = 0.25
local STATUS_REFRESH = 1
local RECOIL_SCAN_TRIES = 5
local RECOIL_SCAN_SETTLE = 0.3
local RECOIL_POLL = 0.5
local GC_YIELD_EVERY = 4000
local AIM_FOV_DEFAULT = 200
local FOV_CIRCLE_THICKNESS = 1.5
local FOV_CIRCLE_TRANSPARENCY = 0.2
local FOV_PREVIEW_SECONDS = 3
local SHOTGUN_COOLDOWN = 1
local OWNER_GUN_COOLDOWN = 0.1
local SNEAK_SPEED = 2
local HIDER_SPEED = 8
local SNEAK_RESEND = 0.25

local LIGHT_PROPS = {
	Ambient = Color3.fromRGB(190, 190, 190),
	OutdoorAmbient = Color3.fromRGB(190, 190, 190),
	Brightness = 2,
	ClockTime = 14,
	EnvironmentDiffuseScale = 1,
	EnvironmentSpecularScale = 1,
	ExposureCompensation = 0,
	GlobalShadows = false,
	FogStart = 0,
	FogEnd = 100000,
}
-- VisionAveugle does not save or restore these, so we must put them back ourselves.
local PROPS_GAME_WONT_RESTORE = { "GlobalShadows", "FogStart", "FogEnd" }

local localPlayer = Players.LocalPlayer
local genv = getgenv()

if genv.__BBD_HUB and genv.__BBD_HUB.cleanup then
	pcall(genv.__BBD_HUB.cleanup)
end

-- Older standalone builds: remove their render bind, input and listener-only logger.
pcall(function()
	RunService:UnbindFromRenderStep(BIND_NAME)
end)
if genv.__BBD_W then
	genv.__BBD_W.stop = true
	for _, c in ipairs(genv.__BBD_W.conns or {}) do
		pcall(function()
			c:Disconnect()
		end)
	end
	genv.__BBD_W = nil
end

-- S outlives re-execution: installed hook wrappers read their flags from this table.
local S = genv.__BBD_SIGHT or {}
genv.__BBD_SIGHT = S
if S.inputConn then
	S.inputConn:Disconnect()
	S.inputConn = nil
end
S.hookedRecoil = S.hookedRecoil or {} -- strong keys: keeps hooked closures from being collected
S.hookedTirer = S.hookedTirer or {}
S.calls = S.calls or 0
S.enabled = false
S.disabled = true
S.noRecoil = false
S.active = false
S.frames = 0

local Hub = { conns = {}, stopped = false }
genv.__BBD_HUB = Hub

local stats = {
	escapeSent = 0,
	escapeWorked = 0,
	escapeLast = "none yet",
	phoneDone = 0,
	phoneLast = "none yet",
	recoilSkipped = 0,
	recoilLast = "not scanned",
}
Hub.stats = stats

local Fluent
local restoreShake

local function notify(title, content, duration)
	print("[BBD] " .. title .. ": " .. content)
	if Fluent then
		Fluent:Notify({ Title = title, Content = content, Duration = duration or 5 })
	end
end

local function track(conn)
	Hub.conns[#Hub.conns + 1] = conn
	return conn
end

-- Same rule as the game's estChercheurEnJeu: the named blind men, everyone still in the round
-- during free-for-all (Anarchy), and infected players.
local function amBlind()
	local id = localPlayer.UserId
	if ReplicatedStorage:GetAttribute("AveugleUserId") == id or ReplicatedStorage:GetAttribute("AveugleUserId2") == id then
		return true
	end
	if localPlayer:GetAttribute("EnManche") ~= true then
		return false
	end
	return ReplicatedStorage:GetAttribute("ModeManche") == "Anarchy" or localPlayer:GetAttribute("Infecte") == true
end

local function isBlindPlayer(player)
	return ReplicatedStorage:GetAttribute("AveugleUserId") == player.UserId
		or ReplicatedStorage:GetAttribute("AveugleUserId2") == player.UserId
end

local function alive(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- A reload keeps the player's toggles, so nothing is briefly off mid-round.
local function pref(key, default)
	if S.prefs and S.prefs[key] ~= nil then
		return S.prefs[key]
	end
	return default
end

--------------------------------------------------------------------------------
-- Closure scanning and hooks
--------------------------------------------------------------------------------

local CAN_HOOK = getgc ~= nil and hookfunction ~= nil and islclosure ~= nil

local function findClosures(wanted)
	local found = {}
	if not CAN_HOOK then
		return found
	end
	for i, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) then
			local name = debug.info(f, "n")
			local expected = name and wanted[name]
			if expected then
				local ok, env = pcall(getfenv, f)
				if ok and env and env.script == expected then
					found[name] = f
				end
			end
		end
		if i % GC_YIELD_EVERY == 0 then
			task.wait()
		end
	end
	return found
end

local function scanPlayerScripts()
	local scripts = localPlayer:WaitForChild("PlayerScripts")
	local wanted = {}
	local vision = scripts:FindFirstChild("VisionAveugle")
	local phone = scripts:FindFirstChild("PopupTelephone")
	if vision and not S.hooked then
		wanted.cacherJoueurs = vision
	end
	if phone then
		wanted.terminer = phone
	end
	local found = findClosures(wanted)
	if found.cacherJoueurs then
		local old
		old = hookfunction(found.cacherJoueurs, function(amount, ...)
			S.calls += 1
			if S.disabled then
				return old(amount, ...)
			end
			return old(0, ...)
		end)
		S.hooked = true
	end
	Hub.terminer = found.terminer
end

-- The holder's shake while the victim mashes ignores the game's setting. SECOUSSE_DEBAT is a
-- script global with no debug name, so it's read from the script's environment.
local function hookGrabShake()
	if S.debatFn then
		return true
	end
	if not (getconnections and hookfunction) then
		return false
	end
	local controls = localPlayer:WaitForChild("PlayerScripts"):FindFirstChild("ControlesJoueur")
	for _, conn in ipairs(getconnections(ReplicatedStorage:WaitForChild("Projection").OnClientEvent)) do
		local fn = conn.Function
		local ok, env = pcall(getfenv, fn or 0)
		if fn and ok and env and env.script == controls then
			local target = rawget(env, "SECOUSSE_DEBAT")
			if type(target) == "function" then
				local old
				old = hookfunction(target, function(...)
					if S.antiShake then
						S.debatBlocked = (S.debatBlocked or 0) + 1
						return
					end
					return old(...)
				end)
				S.debatFn = target
				return true
			end
		end
	end
	return false
end

-- Pushes reach us as Projection(velocity, duration); kills send no duration. The client
-- applies the fling and asks for its own ragdoll, so skipping the handler skips both.
local function hookProjection()
	if S.hookedProjection then
		return true
	end
	if not (getconnections and hookfunction) then
		return false
	end
	local scripts = localPlayer:WaitForChild("PlayerScripts")
	local controls = scripts:FindFirstChild("ControlesJoueur")
	for _, conn in ipairs(getconnections(ReplicatedStorage:WaitForChild("Projection").OnClientEvent)) do
		local fn = conn.Function
		if fn then
			local ok, env = pcall(getfenv, fn)
			if ok and env and env.script == controls then
				local old
				old = hookfunction(fn, function(velocity, duration, ...)
					if S.antiPush and typeof(duration) == "number" and duration > 0 then
						S.pushBlocked = (S.pushBlocked or 0) + 1
						return
					end
					return old(velocity, duration, ...)
				end)
				S.hookedProjection = true
				return true
			end
		end
	end
	return false
end

local recoilScanRunning = false
local recoilTries = setmetatable({}, { __mode = "k" })

local function currentShotgun()
	local character = localPlayer.Character
	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	return (character and character:FindFirstChild("FusilAPompe"))
		or (backpack and backpack:FindFirstChild("FusilAPompe"))
end

-- Runs the game's tirer steps with a chosen direction and never touches the camera. Works on
-- tirer's own upvalues: 1 tool, 2 last-shot clock, 3 player, 4 VRUtil, 5 TirFusil, 6 petitRecul,
-- 7 recul. Returns false to let the real tirer run if any of them don't look right, or in VR.
local function fireSilent(tirer, aimPoint)
	if not (debug.getupvalue and debug.setupvalue) then
		return false
	end
	local tool = debug.getupvalue(tirer, 1)
	local lastShot = debug.getupvalue(tirer, 2)
	local vrUtil = debug.getupvalue(tirer, 4)
	local remote = debug.getupvalue(tirer, 5)
	local smallRecoil = debug.getupvalue(tirer, 6)
	local recoil = debug.getupvalue(tirer, 7)
	if typeof(tool) ~= "Instance" or type(lastShot) ~= "number" or type(vrUtil) ~= "table"
		or typeof(remote) ~= "Instance" or not remote:IsA("RemoteEvent") or remote.Name ~= "TirFusil"
		or type(smallRecoil) ~= "function" or type(recoil) ~= "function" then
		stats.recoilLast = "silent aim: unexpected upvalues, using normal shots"
		return false
	end
	if vrUtil.actif() then
		return false
	end
	local isOwnerGun = tool:GetAttribute("OwnerGun") == true
	local cooldown = isOwnerGun and OWNER_GUN_COOLDOWN or SHOTGUN_COOLDOWN
	local shells = localPlayer:GetAttribute("Cartouches") or 0
	if os.clock() - lastShot < cooldown or (not isOwnerGun and shells <= 0) then
		return true -- same as tirer's own early return: no shot, and no normal shot either
	end
	debug.setupvalue(tirer, 2, os.clock())
	localPlayer:SetAttribute("PretA_FusilAPompe", os.clock() + cooldown)
	local lastShell = not isOwnerGun and shells <= 1
	localPlayer:SetAttribute("TirViewmodel", (lastShell and "dernier:" or "tir:") .. os.clock())
	remote:FireServer((aimPoint - workspace.CurrentCamera.CFrame.Position).Unit, nil)
	S.silentShots = (S.silentShots or 0) + 1
	if isOwnerGun then
		smallRecoil()
	else
		recoil(nil)
	end
	return true
end

local function hookRecoil(clientScript)
	local found = findClosures({ recul = clientScript, tirer = clientScript })
	if not found.recul or not found.tirer then
		return false
	end
	if not S.hookedRecoil[found.recul] then
		local old
		old = hookfunction(found.recul, function(...)
			if S.noRecoil then
				S.recoilSkipped = (S.recoilSkipped or 0) + 1
				return
			end
			return old(...)
		end)
		S.hookedRecoil[found.recul] = true
	end
	if not S.hookedTirer[found.tirer] then
		local old
		old = hookfunction(found.tirer, function(...)
			local aimPoint = S.silentAim and S.pickTarget and S.pickTarget()
			if not aimPoint or not fireSilent(old, aimPoint) then
				return old(...)
			end
		end)
		S.hookedTirer[found.tirer] = true
	end
	return true
end

local function isValidAimTarget(model, isInfected, isBlind)
	if not model or isBlind or not alive(model) then
		return false
	end
	if localPlayer:GetAttribute("Infecte") == true and isInfected then
		return false
	end
	return true
end

local function aimPartOf(model)
	return model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso") or model:FindFirstChild("HumanoidRootPart")
end

-- The target nearest the crosshair inside the FOV, with a clear line from the camera.
function S.pickTarget()
	local camera = workspace.CurrentCamera
	local center = camera.ViewportSize / 2
	local candidates = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= localPlayer and p:GetAttribute("EnManche") == true then
			local c = p.Character
			if isValidAimTarget(c, p:GetAttribute("Infecte") == true, isBlindPlayer(p)) then
				candidates[#candidates + 1] = c
			end
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	if bots then
		for _, b in ipairs(bots:GetChildren()) do
			if b:IsA("Model") and isValidAimTarget(b, b:GetAttribute("Infecte") == true, b:GetAttribute("EstBlindMan") == true) then
				candidates[#candidates + 1] = b
			end
		end
	end
	local best, bestDist = nil, S.aimFov or AIM_FOV_DEFAULT
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Halloween web sheets are invisible, non-collidable and queryable, up to about 37 studs across.
	params.RespectCanCollide = true
	for _, model in ipairs(candidates) do
		local part = aimPartOf(model)
		if part then
			local screen, onScreen = camera:WorldToViewportPoint(part.Position)
			if onScreen then
				local dist = (Vector2.new(screen.X, screen.Y) - center).Magnitude
				if dist < bestDist then
					params.FilterDescendantsInstances = { localPlayer.Character, camera, model }
					local origin = camera.CFrame.Position
					if not workspace:Raycast(origin, part.Position - origin, params) then
						best, bestDist = part.Position, dist
					end
				end
			end
		end
	end
	return best
end

-- Polled from the background loop: a tool can arrive before its script replicates, and each
-- round brings a new shotgun with a new closure. Tries are capped per script to limit getgc scans.
local function scanRecoil()
	if recoilScanRunning or not CAN_HOOK then
		return
	end
	local tool = currentShotgun()
	local clientScript = tool and tool:FindFirstChild("ClientFusil")
	if not clientScript or Hub.recoilScript == clientScript then
		return
	end
	local tries = (recoilTries[clientScript] or 0) + 1
	if tries > RECOIL_SCAN_TRIES then
		return
	end
	recoilTries[clientScript] = tries
	recoilScanRunning = true
	task.spawn(function()
		task.wait(RECOIL_SCAN_SETTLE)
		local ok, result = pcall(hookRecoil, clientScript)
		if not ok then
			stats.recoilLast = "error: " .. tostring(result)
		elseif result then
			Hub.recoilScript = clientScript
			stats.recoilLast = "hooked this shotgun"
		else
			stats.recoilLast = "not found, try " .. tries
		end
		recoilScanRunning = false
	end)
end

--------------------------------------------------------------------------------
-- See While Blind
--------------------------------------------------------------------------------

local capturedLight = nil
local capturedAtmos = {}
local partsCache = {}
local lastRebuild = 0

-- Waiting for the game's black sky means its sauver() has already saved the real lighting,
-- so restaurer() still puts the true values back after the round.
local function seeShouldRun()
	-- S.active keeps it on through the end screen, where AveugleUserId clears before the game
	-- removes the darkness.
	return S.enabled and (amBlind() or S.active) and Lighting:FindFirstChild(BLIND_SKY_NAME) ~= nil
end

local function rebuildParts()
	table.clear(partsCache)
	local function addFrom(model)
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") or d:IsA("Decal") then
				partsCache[#partsCache + 1] = d
			end
		end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= localPlayer and p.Character then
			addFrom(p.Character)
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	if bots then
		addFrom(bots)
	end
end

local function seeActivate()
	capturedLight = {}
	for k in pairs(LIGHT_PROPS) do
		capturedLight[k] = Lighting[k]
	end
	table.clear(capturedAtmos)
	S.active = true
	lastRebuild = 0
end

-- roundEnded: the game already restored its own values, so only touch what it ignores.
local function seeDeactivate(roundEnded)
	S.active = false
	if not capturedLight then
		return
	end
	if roundEnded then
		for _, k in ipairs(PROPS_GAME_WONT_RESTORE) do
			pcall(function()
				Lighting[k] = capturedLight[k]
			end)
		end
	else
		for k, v in pairs(capturedLight) do
			pcall(function()
				Lighting[k] = v
			end)
		end
		for atmos in pairs(capturedAtmos) do
			pcall(function()
				atmos.Parent = Lighting
			end)
		end
	end
	capturedLight = nil
	table.clear(capturedAtmos)
end

RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Last.Value + 1, function()
	S.frames += 1
	local want = seeShouldRun()
	if want and not S.active then
		seeActivate()
	elseif not want and S.active then
		seeDeactivate(Lighting:FindFirstChild(BLIND_SKY_NAME) == nil)
	end
	if not S.active then
		return
	end
	for k, v in pairs(LIGHT_PROPS) do
		if Lighting[k] ~= v then
			Lighting[k] = v
		end
	end
	-- Unparent instead of zeroing Density: VisionAveugle checks it every 0.25 s and tweens it back
	-- to 1 over 0.4 s, which fought our per-frame write and made the darkness pulse.
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("Atmosphere") then
			capturedAtmos[child] = true
			child.Parent = nil
		end
	end
	-- The cacherJoueurs hook does the real work; this covers a failed hook.
	if os.clock() - lastRebuild > 1 then
		lastRebuild = os.clock()
		rebuildParts()
	end
	for i = 1, #partsCache do
		local d = partsCache[i]
		if d.Parent and d.LocalTransparencyModifier ~= 0 then
			d.LocalTransparencyModifier = 0
		end
	end
end)

--------------------------------------------------------------------------------
-- Player Outlines
--------------------------------------------------------------------------------

local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
-- Kept outside workspace so VisionAveugle's assombrir() can't switch these off.
local outlineFolder = Instance.new("Folder")
outlineFolder.Name = "BBD_Outlines"
outlineFolder.Parent = guiParent

local outlines = {}
local outlinesOn = false

local COLOR_BLIND = Color3.fromRGB(255, 50, 50)
local COLOR_INFECTED = COLOR_BLIND
local COLOR_HIDER = Color3.fromRGB(255, 255, 255)

local function clearOutlines()
	for model, h in pairs(outlines) do
		h:Destroy()
		outlines[model] = nil
	end
end

local function refreshOutlines()
	if not outlinesOn then
		return
	end
	local want = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local c = p.Character
		if p ~= localPlayer and c and p:GetAttribute("EnManche") == true and alive(c) then
			if isBlindPlayer(p) then
				want[c] = COLOR_BLIND
			elseif p:GetAttribute("Infecte") == true then
				want[c] = COLOR_INFECTED
			else
				want[c] = COLOR_HIDER
			end
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	if bots then
		for _, b in ipairs(bots:GetChildren()) do
			if b:IsA("Model") and alive(b) then
				if b:GetAttribute("EstBlindMan") == true then
					want[b] = COLOR_BLIND
				elseif b:GetAttribute("Infecte") == true then
					want[b] = COLOR_INFECTED
				else
					want[b] = COLOR_HIDER
				end
			end
		end
	end
	for model, h in pairs(outlines) do
		if not want[model] then
			h:Destroy()
			outlines[model] = nil
		end
	end
	for model, color in pairs(want) do
		local h = outlines[model]
		if not h then
			h = Instance.new("Highlight")
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.FillTransparency = 0.8
			h.OutlineTransparency = 0
			h.Adornee = model
			h.Parent = outlineFolder
			outlines[model] = h
		end
		h.FillColor = color
		h.OutlineColor = color
	end
end

--------------------------------------------------------------------------------
-- Silent Aim FOV circle
--------------------------------------------------------------------------------

-- IgnoreGuiInset lines the centre up with camera.ViewportSize / 2, which pickTarget measures from.
local fovGui = Instance.new("ScreenGui")
fovGui.Name = "BBD_FOV"
fovGui.IgnoreGuiInset = true
fovGui.ResetOnSpawn = false
fovGui.DisplayOrder = 50
fovGui.Enabled = false
fovGui.Parent = guiParent

local fovCircle = Instance.new("Frame")
fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
fovCircle.Position = UDim2.fromScale(0.5, 0.5)
fovCircle.BackgroundTransparency = 1
fovCircle.Parent = fovGui

local fovCorner = Instance.new("UICorner")
fovCorner.CornerRadius = UDim.new(0.5, 0)
fovCorner.Parent = fovCircle

local fovStroke = Instance.new("UIStroke")
fovStroke.Color = Color3.new(1, 1, 1)
fovStroke.Thickness = FOV_CIRCLE_THICKNESS
fovStroke.Transparency = FOV_CIRCLE_TRANSPARENCY
fovStroke.Parent = fovCircle

local fovPreviewUntil = 0

local function refreshFovCircle()
	local radius = S.aimFov or AIM_FOV_DEFAULT
	fovCircle.Size = UDim2.fromOffset(radius * 2, radius * 2)
	-- Shows while the shotgun is equipped, and briefly after moving the slider to size it anywhere.
	local character = localPlayer.Character
	local shotgunEquipped = character ~= nil and character:FindFirstChild("FusilAPompe") ~= nil
	fovGui.Enabled = S.silentAim == true and (shotgunEquipped or os.clock() < fovPreviewUntil)
end

--------------------------------------------------------------------------------
-- Anti Screen Shake
--------------------------------------------------------------------------------

-- ControlesJoueur's SecoussesCaches skips all its shake when this attribute is false. It's the
-- game's own setting, written locally only, so the saved value on the server is untouched.
local SHAKE_ATTRIBUTE = "Reglage_ScreenShake"

function restoreShake()
	if S.shakeSaved ~= nil then
		localPlayer:SetAttribute(SHAKE_ATTRIBUTE, S.shakeSaved)
		S.shakeSaved = nil
	end
end

local function refreshShake()
	if S.antiShake and localPlayer:GetAttribute(SHAKE_ATTRIBUTE) ~= false then
		S.shakeSaved = localPlayer:GetAttribute(SHAKE_ATTRIBUTE)
		localPlayer:SetAttribute(SHAKE_ATTRIBUTE, false)
	end
end

-- The firecracker wobble (NauseePetard, Camera + 2) ignores that setting, so while stunned the
-- camera is saved before it runs and put back after. Its blur, tint and deafness still play.
local camBeforeWobble = nil

RunService:BindToRenderStep(SHAKE_BIND_SAVE, Enum.RenderPriority.Camera.Value + 1, function()
	camBeforeWobble = nil
	if S.antiShake and (localPlayer:GetAttribute("EtourdiJusqua") or 0) > workspace:GetServerTimeNow() then
		camBeforeWobble = workspace.CurrentCamera.CFrame
	end
end)

RunService:BindToRenderStep(SHAKE_BIND_RESTORE, Enum.RenderPriority.Camera.Value + 3, function()
	if camBeforeWobble then
		workspace.CurrentCamera.CFrame = camBeforeWobble
	end
end)

--------------------------------------------------------------------------------
-- Always Sneak
--------------------------------------------------------------------------------

-- Discret(true) makes the server set the Discret attribute and drop WalkSpeed to 2. The character
-- moves on this client, so putting the local WalkSpeed back keeps normal speed.
local Discret = ReplicatedStorage:WaitForChild("Discret")
local lastSneakSend = 0

local function sneakAllowed()
	if amBlind() or localPlayer:GetAttribute("EnManche") ~= true then
		return false
	end
	if localPlayer:GetAttribute("Infecte") == true then
		return false
	end
	local character = localPlayer.Character
	return character ~= nil and alive(character)
end

local function refreshSneak()
	local allowed = S.alwaysSneak and sneakAllowed()
	if allowed and localPlayer:GetAttribute("Discret") ~= true and os.clock() - lastSneakSend >= SNEAK_RESEND then
		lastSneakSend = os.clock()
		Discret:FireServer(true)
	end
	if allowed then
		local humanoid = localPlayer.Character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.WalkSpeed == SNEAK_SPEED then
			humanoid.WalkSpeed = HIDER_SPEED
		end
	end
end

--------------------------------------------------------------------------------
-- Auto Grab Escape
--------------------------------------------------------------------------------

local escapeOn = false
local Porter = ReplicatedStorage:WaitForChild("Porter")

-- The server frees the victim a couple of seconds after accepting, so each send gets a long wait.
local function tryEscape(character)
	local grabbedAt = os.clock()
	for attempt = 1, ESCAPE_RETRIES do
		if Hub.stopped or not escapeOn or character:GetAttribute("Porte") ~= true then
			return
		end
		Porter:FireServer("liberer", nil)
		stats.escapeSent += 1
		stats.escapeLast = "sent, attempt " .. attempt
		local deadline = os.clock() + ESCAPE_WAIT
		while os.clock() < deadline do
			task.wait(ESCAPE_POLL)
			if Hub.stopped then
				return
			end
			if character:GetAttribute("Porte") ~= true then
				local held = os.clock() - grabbedAt
				stats.escapeWorked += 1
				stats.escapeLast = string.format("freed after %.2fs, %d send(s)", held, attempt)
				return
			end
		end
	end
	stats.escapeLast = "still held after " .. ESCAPE_RETRIES .. " sends"
	notify("Grab escape", "Server ignored it. Mash Q + E to get out.")
end

local function watchCharacter(character)
	track(character:GetAttributeChangedSignal("Porte"):Connect(function()
		if escapeOn and character:GetAttribute("Porte") == true then
			task.spawn(tryEscape, character)
		end
	end))
end

if localPlayer.Character then
	watchCharacter(localPlayer.Character)
end
track(localPlayer.CharacterAdded:Connect(watchCharacter))

--------------------------------------------------------------------------------
-- Auto Phone
--------------------------------------------------------------------------------

local phoneOn = false
local Telephone = ReplicatedStorage:WaitForChild("Telephone")

track(Telephone.OnClientEvent:Connect(function(kind, id)
	if kind ~= "popup" or not phoneOn then
		return
	end
	task.delay(PHONE_DELAY, function()
		if Hub.stopped then
			return
		end
		if Hub.terminer then
			-- The game's own finish path: sends "reussi" and tears the popup down properly.
			local ok = pcall(Hub.terminer, true, "SUCCESS")
			stats.phoneLast = ok and "finished via game code" or "game code errored"
		else
			Telephone:FireServer("reussi", id)
			stats.phoneLast = "sent directly, popup may stay open"
		end
		stats.phoneDone += 1
	end)
end))

--------------------------------------------------------------------------------
-- Staff Alert
--------------------------------------------------------------------------------

local staffOn = false
local staffModule = nil
pcall(function()
	staffModule = require(ReplicatedStorage:WaitForChild("Staff"))
end)

local function staffRole(player)
	if not staffModule then
		return nil
	end
	local id = player.UserId
	if staffModule.estOwner(id) then
		return "Owner"
	elseif staffModule.estAdmin(id) then
		return "Admin"
	elseif staffModule.estMod(id) then
		return "Mod"
	end
	return nil
end

local function alertIfStaff(player)
	local role = staffRole(player)
	if role and staffOn then
		notify("Staff in server", role .. ": " .. player.Name, 10)
	end
end

track(Players.PlayerAdded:Connect(alertIfStaff))

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
Hub.Fluent = Fluent

local Window = Fluent:CreateWindow({
	Title = "blind but dangerous",
	SubTitle = "vibecodemods",
	TabWidth = 140,
	Size = UDim2.fromOffset(520, 400),
	Acrylic = false,
	Theme = "Dark",
	MinimizeKey = Enum.KeyCode.RightControl,
})

local Tabs = {
	Blind = Window:AddTab({ Title = "Blind Man", Icon = "eye" }),
	Hider = Window:AddTab({ Title = "Hider", Icon = "shield" }),
	Misc = Window:AddTab({ Title = "Misc", Icon = "settings" }),
	Status = Window:AddTab({ Title = "Status", Icon = "activity" }),
}

Tabs.Blind:AddToggle("See", {
	Title = "See While Blind",
	Description = "Normal bright view during your blind rounds. Press F6 to toggle",
	Default = pref("See", true),
}):OnChanged(function(v)
	S.enabled = v
	S.disabled = not v
end)

Tabs.Blind:AddToggle("NoRecoil", {
	Title = "No Shotgun Recoil",
	Description = "Skips the knockback and camera flip when you fire",
	Default = pref("NoRecoil", false),
}):OnChanged(function(v)
	S.noRecoil = v
end)

Tabs.Blind:AddToggle("SilentAim", {
	Title = "Silent Aim",
	Description = "Shots go to the visible target nearest your crosshair",
	Default = pref("SilentAim", false),
}):OnChanged(function(v)
	S.silentAim = v
end)

Tabs.Blind:AddSlider("AimFov", {
	Title = "Silent Aim FOV",
	Description = "Pixels from your crosshair a target can be",
	Default = pref("AimFov", AIM_FOV_DEFAULT),
	Min = 30,
	Max = 1500,
	Rounding = 0,
}):OnChanged(function(v)
	S.aimFov = v
	fovPreviewUntil = os.clock() + FOV_PREVIEW_SECONDS
end)

Tabs.Hider:AddToggle("AntiPush", {
	Title = "Anti Push",
	Description = "Ignores the fling and ragdoll when someone pushes you",
	Default = pref("AntiPush", false),
}):OnChanged(function(v)
	S.antiPush = v
end)

Tabs.Hider:AddToggle("AlwaysSneak", {
	Title = "Always Sneak",
	Description = "Stays in sneak during rounds at normal walking speed",
	Default = pref("AlwaysSneak", false),
}):OnChanged(function(v)
	local wasOn = S.alwaysSneak
	S.alwaysSneak = v
	if wasOn and not v and localPlayer:GetAttribute("Discret") == true then
		Discret:FireServer(false)
	end
end)

Tabs.Hider:AddToggle("AntiShake", {
	Title = "Anti Screen Shake",
	Description = "All camera shake: blind man, gunshots, megaphone, grabs, firecrackers",
	Default = pref("AntiShake", false),
}):OnChanged(function(v)
	S.antiShake = v
	if not v then
		restoreShake()
	end
end)

Tabs.Hider:AddToggle("Escape", {
	Title = "Auto Grab Escape",
	Description = "Breaks free of grabs without mashing, about 2.5 seconds in",
	Default = pref("Escape", false),
}):OnChanged(function(v)
	escapeOn = v
	local character = localPlayer.Character
	if v and character and character:GetAttribute("Porte") == true then
		task.spawn(tryEscape, character)
	end
end)

Tabs.Hider:AddToggle("Phone", {
	Title = "Auto Phone Popup",
	Description = "Completes the phone popup for you. Untested, may be ignored",
	Default = pref("Phone", false),
}):OnChanged(function(v)
	phoneOn = v
end)

Tabs.Misc:AddToggle("Outlines", {
	Title = "Player Outlines",
	Description = "Through walls. Red = blind man or infected, white = hider",
	Default = pref("Outlines", false),
}):OnChanged(function(v)
	outlinesOn = v
	if not v then
		clearOutlines()
	end
end)

Tabs.Misc:AddToggle("Staff", {
	Title = "Staff Alert",
	Description = "Warns you when a listed owner, admin or mod is in the server",
	Default = pref("Staff", true),
}):OnChanged(function(v)
	staffOn = v
	if v then
		for _, p in ipairs(Players:GetPlayers()) do
			alertIfStaff(p)
		end
	end
end)

Tabs.Misc:AddButton({
	Title = "Unload Hub",
	Description = "Removes the menu and turns everything off",
	Callback = function()
		Hub.cleanup()
	end,
})

local statusParagraph = Tabs.Status:AddParagraph({ Title = "Round", Content = "Loading..." })
local featureParagraph = Tabs.Status:AddParagraph({ Title = "Features", Content = "Loading..." })

local function roundText()
	local aveugleId = ReplicatedStorage:GetAttribute("AveugleUserId") or 0
	local blindPlayer = aveugleId ~= 0 and Players:GetPlayerByUserId(aveugleId) or nil
	local hiders, staffNames = 0, {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p:GetAttribute("EnManche") == true and not isBlindPlayer(p) and p.Character and alive(p.Character) then
			hiders += 1
		end
		if staffRole(p) then
			staffNames[#staffNames + 1] = p.Name
		end
	end
	local role = "In lobby"
	if amBlind() then
		role = "Blind man"
	elseif localPlayer:GetAttribute("EnManche") == true then
		role = "Hider"
	end
	return table.concat({
		"You: " .. role,
		"Blind man: " .. (blindPlayer and blindPlayer.Name or "none"),
		"Hiders alive: " .. hiders,
		"Mode: " .. tostring(ReplicatedStorage:GetAttribute("ModeManche") or "normal"),
		"Shells: " .. tostring(localPlayer:GetAttribute("Cartouches") or "-"),
		"Coins: " .. tostring(localPlayer:GetAttribute("Pieces") or "-"),
		"Staff here: " .. (#staffNames > 0 and table.concat(staffNames, ", ") or "none"),
	}, "\n")
end

local function featureText()
	return table.concat({
		"See While Blind: " .. (S.active and "working now" or (S.enabled and "waiting for a blind round" or "off")),
		"Hide hook: " .. (S.hooked and ("installed, " .. S.calls .. " calls") or "not installed, may flicker"),
		"Shotgun: " .. stats.recoilLast .. ", " .. tostring(S.recoilSkipped or 0) .. " recoils skipped, "
			.. tostring(S.silentShots or 0) .. " silent shots",
		"Anti Push: " .. (S.hookedProjection and (tostring(S.pushBlocked or 0) .. " blocked") or "not hooked"),
		"Escape: " .. stats.escapeLast .. " (" .. stats.escapeWorked .. "/" .. stats.escapeSent .. " sends worked)",
		"Phone: " .. stats.phoneLast .. " (" .. stats.phoneDone .. " done)",
	}, "\n")
end

Window:SelectTab(1)

--------------------------------------------------------------------------------
-- Background loops and input
--------------------------------------------------------------------------------

track(UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == SEE_KEY then
		Fluent.Options.See:SetValue(not Fluent.Options.See.Value)
	end
end))

task.spawn(function()
	local lastOutline, lastStatus, lastRecoil = 0, 0, 0
	while not Hub.stopped do
		local now = os.clock()
		if now - lastRecoil >= RECOIL_POLL then
			lastRecoil = now
			scanRecoil()
		end
		if now - lastOutline >= OUTLINE_REFRESH then
			lastOutline = now
			pcall(refreshOutlines)
		end
		pcall(refreshFovCircle)
		pcall(refreshShake)
		pcall(refreshSneak)
		if now - lastStatus >= STATUS_REFRESH then
			lastStatus = now
			pcall(function()
				statusParagraph:SetDesc(roundText())
				featureParagraph:SetDesc(featureText())
			end)
		end
		task.wait(0.05)
	end
end)

function Hub.cleanup()
	if Hub.stopped then
		return
	end
	Hub.stopped = true
	if Fluent and Fluent.Options then
		S.prefs = {}
		for key, option in pairs(Fluent.Options) do
			S.prefs[key] = option.Value
		end
	end
	S.enabled = false
	S.disabled = true
	S.noRecoil = false
	S.silentAim = false
	S.antiPush = false
	S.antiShake = false
	S.alwaysSneak = false
	restoreShake()
	if S.active then
		seeDeactivate(Lighting:FindFirstChild(BLIND_SKY_NAME) == nil)
	end
	for _, bind in ipairs({ BIND_NAME, SHAKE_BIND_SAVE, SHAKE_BIND_RESTORE }) do
		pcall(function()
			RunService:UnbindFromRenderStep(bind)
		end)
	end
	for _, c in ipairs(Hub.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	clearOutlines()
	outlineFolder:Destroy()
	fovGui:Destroy()
	pcall(function()
		Fluent:Destroy()
	end)
	if genv.__BBD_HUB == Hub then
		genv.__BBD_HUB = nil
	end
end

task.spawn(scanPlayerScripts)
task.spawn(function()
	local ok, result = pcall(hookProjection)
	if not ok or not result then
		notify("Anti Push", "Hook failed: " .. tostring(result), 8)
	end
	local shakeOk, shakeResult = pcall(hookGrabShake)
	if not shakeOk or not shakeResult then
		notify("Anti Shake", "Grab shake hook failed: " .. tostring(shakeResult), 8)
	end
end)
notify("blind but dangerous", "Loaded. RightControl hides the menu.", 5)
