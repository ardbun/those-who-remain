local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
	MaxVisible = 5,
	MaxDistance = 75,
	RenderInterval = 0.04,
	ScanInterval = 0.5,
	TextSize = 18,
	StaffCheckInterval = 1,
	StaffGroupId = 2838077,
	MinStaffRank = 250,
	RankTTL = 300,
	RankRefreshInterval = 5,
	RankRetryInterval = 60,
	RefreshAllOnStart = true,
	TextYOffset = 15,
	CircleSegments = 16,
	CircleRadius = 1.8,
	CircleYOffset = 1.0,
	FadeDistance = 40,
	CircleThickness = 2,
	HeadSize = 5,
	ZombieUpdateInterval = 0.5,
}

local ITEM_META = {
	Medkit = { Color = Color3.fromRGB(180, 0, 0) },
	Bandages = { Color = Color3.fromRGB(222, 204, 168) },
	AmmoBoxes = { Color = Color3.fromRGB(0, 180, 0) },
}

local MaxDistanceSq = CONFIG.MaxDistance * CONFIG.MaxDistance
local TYPES = {
	bandages = "Bandages",
	medkit = "Medkit",
	ammo = "AmmoBoxes",
	ammoboxes = "AmmoBoxes",
}

local Segments = CONFIG.CircleSegments
local CircleOffsets = {}
for i = 1, Segments do
	local a = (i - 1) * (2 * math.pi / Segments)
	CircleOffsets[i] = Vector3.new(math.cos(a) * CONFIG.CircleRadius, 0, math.sin(a) * CONFIG.CircleRadius)
end
local CircleOffsetY = CONFIG.CircleYOffset
local FadeMul = (1 / 3.5714285714) / CONFIG.FadeDistance

local OldRunId = _G.TWR_Patched_RunId or 0
local MainRunId = OldRunId + 1
_G.TWR_Patched_RunId = MainRunId

if _G.TWR_Patched_RenderConn then
	pcall(function() _G.TWR_Patched_RenderConn:Disconnect() end)
end
_G.TWR_Patched_RenderConn = nil

if _G.TWR_Patched_Labels then
	for _, d in ipairs(_G.TWR_Patched_Labels) do
		pcall(function() d.Visible = false; d:Remove() end)
	end
end
_G.TWR_Patched_Labels = {}

if _G.TWR_Patched_Circles then
	for _, d in ipairs(_G.TWR_Patched_Circles) do
		pcall(function() d.Visible = false; d:Remove() end)
	end
end
_G.TWR_Patched_Circles = {}

local State = {
	Items = {},
	ItemsContainer = nil,
	InfectedContainer = nil,
	ZombieHeads = {},
	RankCache = {},
	LastStaffKey = nil,
	Pool = {},
	TopK = {},
}

local cachedChar, cachedHRP
local function getHRP()
	local char = LocalPlayer.Character
	if char ~= cachedChar then
		cachedChar = char
		cachedHRP = char and char:FindFirstChild("HumanoidRootPart")
	end
	return cachedHRP
end

local function getLocalPosition()
	local hrp = getHRP()
	return hrp and hrp.Position
end

local function getItemsContainer()
	local cont = State.ItemsContainer
	if cont and cont.Parent then return cont end
	local ignore = Workspace:FindFirstChild("Ignore")
	cont = ignore and ignore:FindFirstChild("Items")
	State.ItemsContainer = cont
	return cont
end

local function getInfectedContainer()
	local cont = State.InfectedContainer
	if cont and cont.Parent then return cont end
	local entities = Workspace:FindFirstChild("Entities")
	cont = entities and entities:FindFirstChild("Infected")
	State.InfectedContainer = cont
	return cont
end

local function getItemType(model)
	if not model then return nil end
	local lower = model.Name:lower()
	for key, itemType in pairs(TYPES) do
		if lower:find(key, 1, true) then return itemType end
	end
	for _, child in ipairs(model:GetChildren()) do
		local cl = child.Name:lower()
		for key, itemType in pairs(TYPES) do
			if cl:find(key, 1, true) then return itemType end
		end
	end
	return nil
end

local function loop(interval, func)
	task.spawn(function()
		while _G.TWR_Patched_RunId == MainRunId do
			task.wait(interval)
			if _G.TWR_Patched_RunId ~= MainRunId then break end
			pcall(func)
		end
	end)
end

local function newLine()
	local ok, l = pcall(function() return Drawing.new("Line") end)
	if not ok or not l then return nil end
	l.Visible = false
	l.From = Vector2.new(0, 0)
	l.To = Vector2.new(0, 0)
	l.Thickness = CONFIG.CircleThickness
	table.insert(_G.TWR_Patched_Circles, l)
	return l
end

local function newSlot()
	local ok, label = pcall(function() return Drawing.new("Text") end)
	local slot = { label = ok and label or nil }
	if slot.label then
		slot.label.Size = CONFIG.TextSize
		slot.label.Font = Drawing.Fonts.SystemBold
		slot.label.Center = true
		slot.label.Outline = true
		slot.label.Visible = false
		table.insert(_G.TWR_Patched_Labels, slot.label)
	end
	local circle = {}
	for _ = 1, Segments do
		local l = newLine()
		if l then circle[#circle + 1] = l end
	end
	slot.circle = circle
	slot.segCount = #circle
	slot.segVis = {}
	slot.from = {}
	slot.to = {}
	slot.transp = {}
	slot.pts = {}
	slot.ons = {}
	slot.visible = false
	slot.Part = nil
	slot.d2 = -1
	slot.alpha = 1
	slot.meters = -1
	slot.pos = nil
	slot.color = nil
	return slot
end

local POOL = CONFIG.MaxVisible
State.Pool = {}
for i = 1, POOL do State.Pool[i] = newSlot() end
State.TopK = {}
for i = 1, POOL do State.TopK[i] = { idx = 0, d2 = 0 } end

local function hideCircleSegments(slot)
	local segVis = slot.segVis
	local circle = slot.circle
	for j = 1, slot.segCount do
		if segVis[j] then
			segVis[j] = false
			circle[j].Visible = false
		end
	end
end

local function hideSlot(slot)
	if slot.visible then
		slot.visible = false
		if slot.label then slot.label.Visible = false end
	end
	hideCircleSegments(slot)
end

local function hideAllSlots()
	for i = 1, POOL do hideSlot(State.Pool[i]) end
end

local function scanItems()
	local cont = getItemsContainer()
	if not cont then
		State.Items = {}
		return
	end
	local out = {}
	for _, model in ipairs(cont:GetChildren()) do
		if model.ClassName == "Model" then
			local box = model:FindFirstChild("Box")
			if box then
				local itemType = getItemType(model)
				local meta = itemType and ITEM_META[itemType]
				if meta then
					local pos = box.Position
					out[#out + 1] = {
						Part = box,
						ItemType = itemType,
						Meta = meta,
						Pos = pos,
						CircleWorld = {},
						CircleScreen = {},
						CircleOn = {},
						ScreenPos = Vector2.new(0, 0),
						OnScreen = false,
						ProjEpoch = -1,
						CircleProjEpoch = -1,
					}
				end
			end
		end
	end
	for _, data in ipairs(out) do
		local pos = data.Pos
		local cy = pos.Y - CircleOffsetY
		local w = data.CircleWorld
		for j = 1, Segments do
			local off = CircleOffsets[j]
			w[j] = Vector3.new(pos.X + off.X, cy, pos.Z + off.Z)
		end
	end
	State.Items = out
end

local lastRender = 0
local projEpoch = 0
local lastCamCF, lastCharPos, lastViewport, lastFov

local function renderEsp()
	if _G.TWR_Patched_RunId ~= MainRunId then return end

	local now = tick()
	if now - lastRender < CONFIG.RenderInterval then return end
	lastRender = now

	local camera = Workspace.CurrentCamera
	if not camera then hideAllSlots() return end

	local charPos = getLocalPosition()
	if not charPos then hideAllSlots() return end

	local camCF = camera.CFrame
	local vp = camera.ViewportSize
	local fov = camera.FieldOfView
	local movedCam = (camCF ~= lastCamCF) or (vp ~= lastViewport) or (fov ~= lastFov)
	local movedChar = charPos ~= lastCharPos
	if (vp ~= lastViewport) or (fov ~= lastFov) then
		projEpoch = projEpoch + 1
	end
	lastCamCF, lastCharPos, lastViewport, lastFov = camCF, charPos, vp, fov

	local items = State.Items
	local cont = State.ItemsContainer

	for i = #items, 1, -1 do
		local data = items[i]
		local part = data and data.Part
		local model = part and part.Parent
		if not (model and model.Parent == cont) then
			table.remove(items, i)
		else
			local pos = part.Position
			if pos ~= data.Pos then
				data.Pos = pos
				local cy = pos.Y - CircleOffsetY
				local w = data.CircleWorld
				for j = 1, Segments do
					local off = CircleOffsets[j]
					w[j] = Vector3.new(pos.X + off.X, cy, pos.Z + off.Z)
				end
				data.ProjEpoch = -1
				data.CircleProjEpoch = -1
			end
		end
	end

	if #items == 0 then hideAllSlots() return end

	local cx, cy_, cz = charPos.X, charPos.Y, charPos.Z
	local topK = State.TopK
	local maxD2 = MaxDistanceSq
	local kCount = 0

	for i = 1, #items do
		local data = items[i]
		local p = data.Pos
		local dx, dy, dz = p.X - cx, p.Y - cy_, p.Z - cz
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 <= maxD2 then
			if kCount < POOL then
				kCount = kCount + 1
				local pos = kCount
				topK[pos].idx = i
				topK[pos].d2 = d2
				while pos > 1 and topK[pos].d2 < topK[pos - 1].d2 do
					topK[pos].idx, topK[pos - 1].idx = topK[pos - 1].idx, topK[pos].idx
					topK[pos].d2, topK[pos - 1].d2 = topK[pos - 1].d2, topK[pos].d2
					pos = pos - 1
				end
			elseif d2 < topK[POOL].d2 then
				topK[POOL].idx = i
				topK[POOL].d2 = d2
				local pos = POOL
				while pos > 1 and topK[pos].d2 < topK[pos - 1].d2 do
					topK[pos].idx, topK[pos - 1].idx = topK[pos - 1].idx, topK[pos].idx
					topK[pos].d2, topK[pos - 1].d2 = topK[pos - 1].d2, topK[pos].d2
					pos = pos - 1
				end
			end
		end
	end

	if kCount == 0 then hideAllSlots() return end

	local doProj = movedCam or movedChar

	for slotIdx = 1, POOL do
		local slot = State.Pool[slotIdx]
		if slotIdx <= kCount then
			local entry = topK[slotIdx]
			local data = items[entry.idx]
			local color = data.Meta.Color
			local partRef = data.Part
			local d2 = entry.d2

			local meters, alpha = slot.meters, slot.alpha
			if slot.Part ~= partRef or slot.d2 ~= d2 then
				slot.Part = partRef
				slot.d2 = d2
				local dist = math.sqrt(d2)
				meters = math.floor(dist)
				slot.meters = meters
				alpha = 1 - dist * FadeMul
				if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end
				slot.alpha = alpha
				if slot.label then slot.label.Text = meters .. "m" end
			end

			if slot.color ~= color then
				slot.color = color
				if slot.label then slot.label.Color = color end
			end

			if data.ProjEpoch ~= projEpoch or doProj then
				local sp, on = WorldToScreen(data.Pos)
				data.ScreenPos = sp
				data.OnScreen = on
				data.ProjEpoch = projEpoch
			end

			if not data.OnScreen then
				hideSlot(slot)
			else
				local sp = data.ScreenPos
				local cur = slot.pos
				local lx = sp.X
				local ly = sp.Y - CONFIG.TextYOffset
				if not cur or cur.X ~= lx or cur.Y ~= ly then
					slot.pos = Vector2.new(lx, ly)
					if slot.label then slot.label.Position = slot.pos end
				end
				if not slot.visible then
					slot.visible = true
					if slot.label then slot.label.Visible = true end
				end

				local segCount = slot.segCount
				if alpha <= 0 or segCount == 0 then
					hideCircleSegments(slot)
				else
					if data.CircleProjEpoch ~= projEpoch or doProj then
						local w = data.CircleWorld
						local cs = data.CircleScreen
						local co = data.CircleOn
						for j = 1, segCount do
							local sp2, on2 = WorldToScreen(w[j])
							cs[j] = sp2
							co[j] = on2
						end
						data.CircleProjEpoch = projEpoch
					end
					local cs = data.CircleScreen
					local co = data.CircleOn
					local circle = slot.circle
					local from, to, transp = slot.from, slot.to, slot.transp
					local segVis = slot.segVis
					for j = 1, segCount do
						local k = (j % segCount) + 1
						if co[j] and co[k] then
							local seg = circle[j]
							local a = cs[j]
							local b = cs[k]
							if from[j] ~= a then from[j] = a; seg.From = a end
							if to[j] ~= b then to[j] = b; seg.To = b end
							if transp[j] ~= alpha then transp[j] = alpha; seg.Transparency = alpha end
							if not segVis[j] then segVis[j] = true; seg.Visible = true end
						elseif segVis[j] then
							segVis[j] = false
							circle[j].Visible = false
						end
					end
				end
			end
		else
			hideSlot(slot)
		end
	end
end

local TargetHeadSize = Vector3.new(CONFIG.HeadSize, CONFIG.HeadSize, CONFIG.HeadSize)

local function updateZombieHeads()
	local cont = getInfectedContainer()
	if not cont then return end
	for _, zombie in ipairs(cont:GetChildren()) do
		local hum = zombie:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			local head = zombie:FindFirstChild("Head")
			if head and head.Size ~= TargetHeadSize then
				head.Size = TargetHeadSize
			end
		end
	end
end

local function getCachedRank(player)
	if player.UserId == LocalPlayer.UserId then return -1 end
	local entry = State.RankCache[player.UserId]
	if entry and (tick() - entry.t) < CONFIG.RankTTL then
		return entry.rank
	end
	return nil
end

local function getGroupRank(userId)
	local now = tick()
	local entry = State.RankCache[userId]
	if entry and (now - entry.t) < CONFIG.RankTTL then
		return entry.rank
	end
	local rank = 0
	local body = ""
	local ok = pcall(function()
		body = httpget("https://groups.roblox.com/v1/users/" .. userId .. "/groups/roles")
	end)
	if ok and body ~= "" then
		local ok2, data = pcall(function() return HttpService:JSONDecode(body) end)
		if ok2 and type(data) == "table" and type(data.data) == "table" then
			for _, g in ipairs(data.data) do
				if g and g.group and g.group.id == CONFIG.StaffGroupId then
					local role = g.role
					rank = (role and role.rank) or 0
					break
				end
			end
		end
	end
	local t = now
	if not ok or body == "" then
		t = now - (CONFIG.RankTTL - CONFIG.RankRetryInterval)
	end
	State.RankCache[userId] = { rank = rank, t = t }
	return rank
end

local function refreshAllRanks()
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId ~= LocalPlayer.UserId then
			pcall(function() getGroupRank(p.UserId) end)
			task.wait(0.15)
		end
	end
end

local function rankWorker()
	while _G.TWR_Patched_RunId == MainRunId do
		task.wait(CONFIG.RankRefreshInterval)
		if _G.TWR_Patched_RunId ~= MainRunId then break end
		local players = Players:GetPlayers()
		local picked
		for i = 1, #players do
			local p = players[i]
			if p and p.UserId ~= LocalPlayer.UserId then
				local entry = State.RankCache[p.UserId]
				if not entry or (tick() - entry.t) >= CONFIG.RankTTL then
					picked = p
					break
				end
			end
		end
		if picked then
			pcall(function() getGroupRank(picked.UserId) end)
		end
	end
end

local function updateStaffCheck()
	local players = Players:GetPlayers()
	local staff = {}
	for _, p in ipairs(players) do
		local rank = getCachedRank(p)
		if rank ~= nil and rank >= CONFIG.MinStaffRank then
			staff[#staff + 1] = p.Name
		end
	end
	table.sort(staff)
	local key = table.concat(staff, "|")
	if key ~= State.LastStaffKey then
		State.LastStaffKey = key
		if #staff > 0 then
			local msg = "[Staff Detector] CHECKING " .. #staff .. " PLAYER(S) | " .. table.concat(staff, ", ")
			print(msg)
			pcall(function() notify(msg, "Staff Detector", 5) end)
		end
	end
end

loop(CONFIG.ScanInterval, scanItems)
loop(CONFIG.ZombieUpdateInterval, updateZombieHeads)
loop(CONFIG.StaffCheckInterval, updateStaffCheck)

scanItems()
if CONFIG.RefreshAllOnStart then
	task.spawn(function()
		task.wait()
		pcall(refreshAllRanks)
	end)
end
if CONFIG.RankRefreshInterval > 0 then
	task.spawn(function()
		task.wait()
		pcall(rankWorker)
	end)
end

_G.TWR_Patched_RenderConn = RunService.RenderStepped:Connect(renderEsp)

if notify then pcall(function() notify("Loaded (patched)", "", 3) end) end

print("[TWR patched] RunId=" .. MainRunId .. " pool=" .. POOL)
