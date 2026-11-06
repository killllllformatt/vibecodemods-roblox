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

-- Fall ragdoll, read from PlayerScripts.ChuteRagdoll 2026-11-05: entirely client-decided. Its
-- Humanoid.StateChanged handler starts a timer on Freefall; a Heartbeat loop ragdolls you (state
-- Physics + ChuteRagdoll:FireServer(true)) after 0.2 s of free fall as a hider, 0.4 s as the blind
-- man, and keeps you down 2 s (+2 s bonus for hiders). Hooking the StateChanged closure and passing
-- Freefall through as Landed keeps the timer nil, so the Heartbeat never fires. The closure is new for
-- every character, so it is re-found each spawn. ForcerRagdoll (the script's BindableEvent for
-- ragdolls from other causes) and the recovery path are untouched.
-- Kept in S so a hub reload doesn't hook the same closure twice.
local hookedFall = S.hookedFallSet or setmetatable({}, { __mode = "k" })
S.hookedFallSet = hookedFall

local function hookFallRagdoll()
	if not (getconnections and hookfunction) then
		return false
	end
	local ch = localPlayer.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false
	end
	if hookedFall[hum] then
		return true
	end
	local chute = localPlayer:WaitForChild("PlayerScripts"):FindFirstChild("ChuteRagdoll")
	if not chute then
		return false
	end
	for _, conn in ipairs(getconnections(hum.StateChanged)) do
		local fn = conn.Function
		local ok, env = pcall(getfenv, fn or 0)
		if fn and ok and env and env.script == chute then
			local landed = Enum.HumanoidStateType.Landed
			local freefall = Enum.HumanoidStateType.Freefall
			local old
			old = hookfunction(fn, function(oldState, newState, ...)
				if S.antiFall and newState == freefall then
					S.fallBlocked = (S.fallBlocked or 0) + 1
					return old(oldState, landed, ...)
				end
				return old(oldState, newState, ...)
			end)
			hookedFall[hum] = true
			S.hookedFall = true
			return true
		end
	end
	return false
end

-- Scary Serum, measured 2026-11-05: the server only sets player attr FauxBruitsJusqua (now + 10 s).
-- The rest runs in our own PlayerScripts.FauxBruits: an anonymous BindToRenderStep
-- ("ScarySerumTouches", Input+1) re-routes MoveDirection through a random axis swap/flip with
-- Humanoid:Move, and unBruit() plays fake footsteps/coughs (Part "FauxBruit" in the Camera) every
-- 1.2-2.2 s. The render function has no name, so it's found by its constants. Hooks persist across
-- reloads; S.antiSerum is read at call time.
-- Hearing Aids heart minigame (hider side), read from PlayerScripts.AppareilAuditif 2026-11-05: when
-- the blind man uses Hearing Aids, every hider gets a 7 s "stay calm" heart line (keep it inside
-- +-0.45; 2 strikes of >0.12 s out on PC, or the gyro/shake variant going 0.75 s without input).
-- Every failure path calls local finir(true), which is the ONLY place that sends
-- AppareilAuditif:FireServer("rate") (= the blind man gets your heart position). Passing sends
-- nothing. The hook turns finir(true) into finir(false): "YOU STAYED CALM", nothing sent.
-- Practice mode (player attr TestCoeurJusqua) runs the same game and never sends "rate".
local function hookHeart()
	if S.hookedHeart then
		return true
	end
	if not CAN_HOOK then
		return false, "executor has no getgc/hookfunction"
	end
	local target = localPlayer:WaitForChild("PlayerScripts"):FindFirstChild("AppareilAuditif")
	if not target then
		return false, "AppareilAuditif script not found"
	end
	local finir
	for i, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) and debug.info(f, "n") == "finir" then
			local ok, env = pcall(getfenv, f)
			if ok and env and rawget(env, "script") == target then
				finir = f
				break
			end
		end
		if i % GC_YIELD_EVERY == 0 then
			task.wait()
		end
	end
	if not finir then
		return false, "finir not found"
	end
	local old
	old = hookfunction(finir, function(failed, ...)
		if S.autoHeart and failed then
			S.heartSaves = (S.heartSaves or 0) + 1
			return old(false, ...)
		end
		return old(failed, ...)
	end)
	S.hookedHeart = true
	return true
end

local function hookScarySerum()
	if S.hookedSerum then
		return true
	end
	if not CAN_HOOK or not debug.getconstants then
		return false, "executor has no getgc/hookfunction/getconstants"
	end
	local target = localPlayer:WaitForChild("PlayerScripts"):FindFirstChild("FauxBruits")
	if not target then
		return false, "FauxBruits script not found"
	end
	local scramble, noise
	for i, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) then
			local ok, env = pcall(getfenv, f)
			if ok and env and rawget(env, "script") == target then
				if debug.info(f, "n") == "unBruit" then
					noise = f
				else
					local okc, consts = pcall(debug.getconstants, f)
					if okc then
						local set = {}
						for _, c in ipairs(consts) do
							if type(c) == "string" then
								set[c] = true
							end
						end
						if set.FauxBruitsJusqua and set.MoveDirection and set.CurrentCamera then
							scramble = f
						end
					end
				end
			end
		end
		if i % GC_YIELD_EVERY == 0 then
			task.wait()
		end
	end
	if not scramble then
		return false, "scramble function not found"
	end
	local oldScramble
	oldScramble = hookfunction(scramble, function(...)
		if S.antiSerum then
			if (localPlayer:GetAttribute("FauxBruitsJusqua") or 0) > workspace:GetServerTimeNow() then
				S.serumFrames = (S.serumFrames or 0) + 1
			end
			return
		end
		return oldScramble(...)
	end)
	if noise then
		local oldNoise
		oldNoise = hookfunction(noise, function(...)
			if S.antiSerum then
				S.serumNoises = (S.serumNoises or 0) + 1
				return
			end
			return oldNoise(...)
		end)
	end
	S.hookedSerum = true
	return true
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

-- The game's own blind-man ESP (PlayerScripts.ContourBlindMan): 6 outline-only Highlights with
-- DepthMode Occluded in Camera.ContoursBlindMan, re-adorned every 0.3 s. Roblox draws one Highlight
-- per adornee, so theirs can win over ours and the blind man stops showing through walls. While our
-- outlines are on, the game's Highlights are moved out of the DataModel. That script only writes
-- Adornee/Enabled on them (it re-parents the folder, not the Highlights), so it keeps them up to date
-- and they reappear correctly when they are put back.
local gameContours = {}

local function suppressGameContours()
	local folder = workspace.CurrentCamera and workspace.CurrentCamera:FindFirstChild("ContoursBlindMan")
	if not folder then
		return
	end
	for _, h in ipairs(folder:GetChildren()) do
		if h:IsA("Highlight") then
			gameContours[h] = folder
			h.Parent = nil
		end
	end
end

local function restoreGameContours()
	for h, folder in pairs(gameContours) do
		if folder.Parent then
			pcall(function()
				h.Parent = folder
			end)
		end
		gameContours[h] = nil
	end
end

-- HUDPartie also drops a "RepereBlindMan" Highlight (AlwaysOnTop, red fill) straight into the blind
-- man's model the moment Etat becomes EnJeu, for 3 s (Debris). Same one-Highlight-per-adornee rule,
-- so for hiders it replaced ours right at round start. While our outlines are on it is destroyed as it
-- appears (its own fade checks .Parent, Debris on a destroyed instance is a no-op) and our Highlight
-- for that model is re-adorned so Roblox picks it up again.
local repereKilled = 0

local function killRepere(h)
	if not outlinesOn or not h:IsA("Highlight") or h.Name ~= "RepereBlindMan" then
		return
	end
	local model = h.Adornee or h.Parent
	pcall(function()
		h:Destroy()
	end)
	repereKilled += 1
	S.repereKilled = repereKilled
	local ours = outlines[model]
	if ours then
		ours.Adornee = nil
		ours.Adornee = model
	end
end

track(workspace.DescendantAdded:Connect(function(d)
	if d.ClassName == "Highlight" and d.Name == "RepereBlindMan" then
		-- Name/Adornee are set before Parent in HUDPartie, but defer anyway in case that changes.
		task.defer(killRepere, d)
	end
end))

local function sweepRepere()
	for _, p in ipairs(Players:GetPlayers()) do
		local h = p.Character and p.Character:FindFirstChild("RepereBlindMan")
		if h then
			killRepere(h)
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	if bots then
		for _, b in ipairs(bots:GetChildren()) do
			local h = b:FindFirstChild("RepereBlindMan")
			if h then
				killRepere(h)
			end
		end
	end
end

local function clearOutlines()
	for model, h in pairs(outlines) do
		h:Destroy()
		outlines[model] = nil
	end
	restoreGameContours()
end

local function inRoundState()
	local etat = ReplicatedStorage:GetAttribute("Etat")
	return etat == "EnJeu" or etat == "Intro"
end

-- Solo servers fill with bots in workspace.Bots. A bot's id is its FauxJoueur attr and the game
-- names a bot blind man as AveugleUserId = -id; the server also sets EstBlindMan on the model.
local function isBlindBot(bot)
	if bot:GetAttribute("EstBlindMan") == true then
		return true
	end
	local id = bot:GetAttribute("FauxJoueur")
	if type(id) ~= "number" then
		return false
	end
	return ReplicatedStorage:GetAttribute("AveugleUserId") == -id
		or ReplicatedStorage:GetAttribute("AveugleUserId2") == -id
end

local function refreshOutlines()
	if not outlinesOn then
		return
	end
	suppressGameContours()
	sweepRepere()
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
	if bots and inRoundState() then
		for _, b in ipairs(bots:GetChildren()) do
			if b:IsA("Model") and alive(b) then
				if isBlindBot(b) then
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
-- Anti AFK
--------------------------------------------------------------------------------

-- Two separate things:
-- 1. Roblox's own 20-minute idle kick (a C-side Player.Idled connection). Disabled via
--    getconnections, with a VirtualUser click on Idled as a fallback.
-- 2. The game's "AFK MODE" (player attr AFK, AFKDepuis): the server turns it on by itself (no client
--    script sends it) and an AFK player is not put in rounds. The settings menu turns it off with
--    ReplicatedStorage.AFK:FireServer(false); we send the same thing when the server flips it on.
local antiAfkOn = false
local afkStats = { reverted = 0, idleKicks = 0 }
local afkRemote = ReplicatedStorage:FindFirstChild("AFK")
local disabledIdled = {}
local onIdled

local function setIdleKickBlocked(block)
	if not getconnections then
		return
	end
	if block then
		for _, c in ipairs(getconnections(localPlayer.Idled)) do
			if not disabledIdled[c] and c.Function ~= onIdled then
				local ok = pcall(function()
					c:Disable()
				end)
				if ok then
					disabledIdled[c] = true
				end
			end
		end
	else
		for c in pairs(disabledIdled) do
			pcall(function()
				c:Enable()
			end)
		end
		disabledIdled = {}
	end
end

function onIdled()
	if not antiAfkOn then
		return
	end
	afkStats.idleKicks += 1
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
end
track(localPlayer.Idled:Connect(onIdled))

local lastAfkSend = 0
local function checkAfkMode()
	if not antiAfkOn or not afkRemote then
		return
	end
	if localPlayer:GetAttribute("AFK") == true and os.clock() - lastAfkSend >= 2 then
		lastAfkSend = os.clock()
		afkStats.reverted += 1
		afkRemote:FireServer(false)
		print("[BBD] Anti AFK: server turned AFK mode on, sent AFK(false)")
	end
end

track(localPlayer:GetAttributeChangedSignal("AFK"):Connect(function()
	pcall(checkAfkMode)
end))

-- 3. Blind-man AFK, captured 2026-11-05: standing still for 25 s as the blind man in EnJeu makes the
--    server set char attr BlindAFK, RS BlindAFK=userId, player AFK=true, Notification "You didn't move
--    for 25s as the blind man", and end the round ("THE BLIND MAN WENT AFK — HIDERS WIN") in the same
--    step, so reverting AFK afterwards is too late. The check is on position, so once the HRP has
--    stayed within BLIND_AFK_RADIUS for BLIND_AFK_AFTER seconds we walk it a short step out and back.
--    The server's own distance threshold is unknown; the step is several studs to be safe.
local BLIND_AFK_AFTER = 12
local BLIND_AFK_RADIUS = 2
local BLIND_AFK_STEP = 0.35 -- seconds per leg at blind walk speed 12 = about 4 studs
local blindAnchor, blindAnchorAt = nil, 0
local nudging = false
local nudgeDirs = { Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0) }
local nudgeIdx = 1
afkStats.blindNudges = 0

local function doNudge(hum, hrp)
	nudging = true
	afkStats.blindNudges += 1
	local cam = workspace.CurrentCamera
	local base = nudgeDirs[nudgeIdx]
	nudgeIdx = nudgeIdx % #nudgeDirs + 1
	local dir = base
	if cam then
		local look = cam.CFrame:VectorToWorldSpace(base)
		dir = Vector3.new(look.X, 0, look.Z)
		dir = dir.Magnitude > 0.01 and dir.Unit or base
	end
	-- Must run on RenderStepped: the game's control script re-writes Move every render frame, so a
	-- Move from a task.wait() loop is wiped before physics (measured: 0 studs vs 6.7 studs in 0.4 s).
	local rs = game:GetService("RunService")
	local function leg(d)
		local t = os.clock()
		while os.clock() - t < BLIND_AFK_STEP and hum.Parent do
			hum:Move(d, false)
			rs.RenderStepped:Wait()
		end
	end
	-- One leg only: end up about 4 studs away and stay there (directions cycle, so repeated nudges
	-- walk a small square instead of drifting). Out-and-back could net zero if the server compares
	-- against an older sample.
	leg(dir)
	hum:Move(Vector3.zero, false)
	print(string.format("[BBD] Anti AFK: blind man idle %ds, nudged", BLIND_AFK_AFTER))
	nudging = false
end

local function checkBlindAfk()
	if not antiAfkOn or nudging then
		return
	end
	local etat = ReplicatedStorage:GetAttribute("Etat")
	local ch = localPlayer.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	-- Only the named blind man (not amBlind(): in Anarchy everyone is blind and hiders stand still on
	-- purpose; the server message says "as the blind man").
	local uid = localPlayer.UserId
	local isBlindMan = ReplicatedStorage:GetAttribute("AveugleUserId") == uid
		or ReplicatedStorage:GetAttribute("AveugleUserId2") == uid
	if etat ~= "EnJeu" or not isBlindMan or not hrp or not hum or hum.Health <= 0 then
		blindAnchor = nil
		return
	end
	local p = hrp.Position
	local flat = Vector3.new(p.X, 0, p.Z)
	local now = os.clock()
	if not blindAnchor or (flat - blindAnchor).Magnitude > BLIND_AFK_RADIUS then
		blindAnchor, blindAnchorAt = flat, now
		return
	end
	if now - blindAnchorAt >= BLIND_AFK_AFTER then
		-- Retry every 2 s if the nudge was blocked (wall) and the anchor didn't move.
		blindAnchorAt = now - BLIND_AFK_AFTER + 2
		task.spawn(doNudge, hum, hrp)
	end
end

--------------------------------------------------------------------------------
-- Anti Stim (blind man)
--------------------------------------------------------------------------------

-- Funky Stim, measured 2026-11-05: in one server step the victim gets player+character attr
-- DanseForcee=true, a random player attr Emote, WalkSpeed 0, and the held tool moved to the Backpack.
-- Everything clears exactly 5 s later. The dance itself is played by the victim's own Emotes script
-- (Action-priority track on the character's Animator + a "SonEmote" Sound in SoundService), so it
-- can be stopped here. WalkSpeed is written locally (movement is client-owned; Always Sneak showed
-- a local WalkSpeed holds). Whether the server accepts shots while DanseForcee is on is untested.
local SoundService = game:GetService("SoundService")
local antiStimOn = false
local stimStats = { blocked = 0, last = "none yet" }
local emoteAnimIds = {}
pcall(function()
	for _, data in pairs(require(ReplicatedStorage:WaitForChild("EmotesData", 5))) do
		if type(data) == "table" and data.animation then
			emoteAnimIds[tostring(data.animation)] = true
		end
	end
end)

local STIM_EQUIP_RETRY = 0.4
-- How long after a tool leaves the hand it still counts as "what you were holding".
local STIM_TOOL_MEMORY = 0.5

local stimActive = false
local stimPreSpeed = 12
local stimLastTool, stimLastToolAt = nil, 0
local stimLastEquip = 0
local stimWantTool = nil

local function stopEmote(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			local id = track.Animation and string.match(track.Animation.AnimationId, "%d+")
			if id and emoteAnimIds[id] then
				track:Stop(0)
			end
		end
	end
	for _, s in ipairs(SoundService:GetChildren()) do
		if s.Name == "SonEmote" and s:IsA("Sound") and s.IsPlaying then
			s:Stop()
		end
	end
end

track(RunService.Heartbeat:Connect(function()
	if not antiStimOn then
		stimActive = false
		return
	end
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local forced = localPlayer:GetAttribute("DanseForcee") == true
		or character:GetAttribute("DanseForcee") == true
	if not forced then
		if stimActive then
			stimActive = false
			stimStats.last = string.format("ended %s", os.date("%H:%M:%S"))
		end
		if humanoid.WalkSpeed > 0 then
			stimPreSpeed = humanoid.WalkSpeed
		end
		local held = character:FindFirstChildOfClass("Tool")
		if held then
			stimLastTool, stimLastToolAt = held.Name, os.clock()
		end
		return
	end
	if not amBlind() then
		return
	end
	if not stimActive then
		stimActive = true
		stimStats.blocked += 1
		stimWantTool = (stimLastTool and os.clock() - stimLastToolAt <= STIM_TOOL_MEMORY) and stimLastTool or nil
		stimStats.last = string.format("blocked %s, holding %s", os.date("%H:%M:%S"), tostring(stimWantTool))
		print("[BBD] Anti Stim: Funky Stim blocked, restoring speed " .. stimPreSpeed .. " and " .. tostring(stimWantTool))
	end
	if humanoid.WalkSpeed < stimPreSpeed then
		humanoid.WalkSpeed = stimPreSpeed
	end
	stopEmote(humanoid)
	local wantTool = stimWantTool
	if wantTool and not character:FindFirstChild(wantTool) and os.clock() - stimLastEquip >= STIM_EQUIP_RETRY then
		local backpack = localPlayer:FindFirstChildOfClass("Backpack")
		local tool = backpack and backpack:FindFirstChild(wantTool)
		if tool then
			stimLastEquip = os.clock()
			humanoid:EquipTool(tool)
		end
	end
end))

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

Tabs.Blind:AddToggle("AntiStim", {
	Title = "Anti Funky Stim",
	Description = "When a hider stims you: keep walking, skip the dance, shotgun back in hand",
	Default = pref("AntiStim", true),
}):OnChanged(function(v)
	antiStimOn = v
end)

Tabs.Blind:AddToggle("AntiSerum", {
	Title = "Anti Scary Serum",
	Description = "When a hider uses the Scary Serum: normal controls, no fake footsteps or coughs",
	Default = pref("AntiSerum", true),
}):OnChanged(function(v)
	S.antiSerum = v
end)

Tabs.Hider:AddToggle("AntiPush", {
	Title = "Anti Push",
	Description = "Ignores the fling and ragdoll when someone pushes you",
	Default = pref("AntiPush", false),
}):OnChanged(function(v)
	S.antiPush = v
end)

Tabs.Hider:AddToggle("AutoHeart", {
	Title = "Auto Calm Heart",
	Description = "Hearing Aids minigame always passes, so the blind man never gets your heartbeat",
	Default = pref("AutoHeart", true),
}):OnChanged(function(v)
	S.autoHeart = v
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

Tabs.Misc:AddToggle("AntiFall", {
	Title = "Anti Fall Ragdoll",
	Description = "No ragdoll from falling or long jumps (both roles). Pushes still work as usual unless Anti Push is on",
	Default = pref("AntiFall", true),
}):OnChanged(function(v)
	S.antiFall = v
	if v then
		pcall(hookFallRagdoll)
	end
end)

Tabs.Misc:AddToggle("AntiAfk", {
	Title = "Anti AFK",
	Description = "Blocks the idle kick, turns the game's AFK mode back off, and steps you a few studs if you stand still 12 s as the blind man (the server ends the round at 25 s)",
	Default = pref("AntiAfk", true),
}):OnChanged(function(v)
	antiAfkOn = v
	setIdleKickBlocked(v)
	if v then
		pcall(checkAfkMode)
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
		"Anti Serum: " .. (not S.antiSerum and "off" or (S.hookedSerum and (tostring(S.serumFrames or 0) .. " scrambled frames, " .. tostring(S.serumNoises or 0) .. " fake noises blocked") or "not hooked")),
		"Anti Stim: " .. (antiStimOn and (stimStats.blocked .. " blocked, " .. stimStats.last) or "off"),
		"Auto Calm Heart: " .. (S.autoHeart and ((S.hookedHeart and "hooked, " or "NOT hooked, ") .. (S.heartSaves or 0) .. " fails turned into passes") or "off"),
		"Anti Fall Ragdoll: " .. (S.antiFall and ((S.hookedFall and "hooked, " or "not hooked yet, ") .. (S.fallBlocked or 0) .. " falls ignored") or "off"),
		"Anti AFK: " .. (antiAfkOn and (afkStats.reverted .. " AFK resets, " .. afkStats.idleKicks .. " idle kicks blocked, " .. afkStats.blindNudges .. " blind nudges") or "off"),
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
		pcall(checkAfkMode)
		pcall(checkBlindAfk)
		if S.antiFall then
			pcall(hookFallRagdoll)
		end
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
	S.antiSerum = false
	S.alwaysSneak = false
	antiAfkOn = false
	antiStimOn = false
	setIdleKickBlocked(false)
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
	local serumOk, serumResult, serumWhy = pcall(hookScarySerum)
	if not serumOk or not serumResult then
		notify("Anti Scary Serum", "Hook failed: " .. tostring(serumWhy or serumResult), 8)
	end
	local heartOk, heartResult, heartWhy = pcall(hookHeart)
	if not heartOk or not heartResult then
		notify("Auto Calm Heart", "Hook failed: " .. tostring(heartWhy or heartResult), 8)
	end
end)
notify("blind but dangerous", "Loaded. RightControl hides the menu.", 5)
