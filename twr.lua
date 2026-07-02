local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CONFIG = {
    MaxVisible = 5, MaxDistance = 70, UpdateInterval = 0.022, ScanInterval = 0.5,
    TextSize = 18, HeadSize = 5,

    StaffCheckInterval = 1,
    StaffGroupId = 2838077,
    MinStaffRank = 250,

    ZombieUpdateInterval = 0.5, TextYOffset = 15,
    CircleSegments = 16, CircleRadius = 1.8, CircleYOffset = 1.0, FadeDistance = 40,
    CacheClearInterval = 1800, CircleThickness = 2,
}

local ITEM_META = {
    Medkit = { Color = Color3.fromRGB(180, 0, 0) },
    Bandages = { Color = Color3.fromRGB(222, 204, 168) },
    AmmoBoxes = { Color = Color3.fromRGB(0, 180, 0) },
}

local MaxDistanceSq = CONFIG.MaxDistance * CONFIG.MaxDistance
local TYPES = { bandages = "Bandages", medkit = "Medkit", ammo = "AmmoBoxes", ammoboxes = "AmmoBoxes" }

local CircleOffsets, Segments = {}, CONFIG.CircleSegments
for i = 1, Segments do
    local a = (i - 1) * (2 * math.pi / Segments)
    CircleOffsets[i] = Vector3.new(math.cos(a) * CONFIG.CircleRadius, 0, math.sin(a) * CONFIG.CircleRadius)
end

local CircleOffset = Vector3.new(0, CONFIG.CircleYOffset, 0)
local TargetHeadSize = Vector3.new(CONFIG.HeadSize, CONFIG.HeadSize, CONFIG.HeadSize)
local FadeMul = (1 / 3.5714285714) / CONFIG.FadeDistance

local State = { RunId = ((_G.MatchaItemScript_RunId or 0) + 1), Items = {}, Labels = {}, LabelCache = {}, Circles = {}, CircleColors = {}, VisibleItems = {}, RankCache = {}, LastStaffString = "", ZombieHeads = {}, ZombieHealth = {}, SeenZombies = {} }
_G.MatchaItemScript_RunId = State.RunId

local LocalPlayer = Players.LocalPlayer

local function removeDrawing(d) if d then d.Visible = false d:Remove() end end
local function hideDrawing(d) if d then d.Visible = false end end

local function hideList(list)
    if list then
        for _, v in ipairs(list) do
            if type(v) == "table" then
                for _, d in ipairs(v) do if d then d.Visible = false end end
            elseif v then
                v.Visible = false
            end
        end
    end
end

local function hideLabel(index) hideDrawing(State.Labels[index]) end
local function hideCircle(index) hideList(State.Circles[index]) end

local function isValidItemPart(part)
    if not part or not part.Parent then return false end
    if not part:IsDescendantOf(Workspace) then return false end

    local ok, pos = pcall(function() return part.Position end)
    return ok and pos ~= nil
end

local function getPartPosition(part)
    local ok, pos = pcall(function()
        return part.Position
    end)
    return ok and pos or nil
end
local function removeItemEntry(index)
    removeDrawing(State.Labels[index])

    local circle = State.Circles[index]
    if circle then
        for _, seg in ipairs(circle) do
            removeDrawing(seg)
        end
    end

    table.remove(State.Items, index)
    table.remove(State.Labels, index)
    table.remove(State.LabelCache, index)
    table.remove(State.Circles, index)
    table.remove(State.CircleColors, index)
end

local function trim(list, cache, newCount, remover)
    for i = #list, newCount + 1, -1 do
        remover(list[i])
        table.remove(list, i)
        if cache then table.remove(cache, i) end
    end
end

local function loop(interval, fn)
    task.spawn(function()
        while _G.MatchaItemScript_RunId == State.RunId do
            fn()
            task.wait(interval)
        end
    end)
end

if _G.MatchaItemScript_Labels then
    for _, label in ipairs(_G.MatchaItemScript_Labels) do removeDrawing(label) end
end
_G.MatchaItemScript_Labels = {}

if _G.MatchaItemScript_Circles then
    for _, circle in ipairs(_G.MatchaItemScript_Circles) do
        if circle then for _, seg in ipairs(circle) do removeDrawing(seg) end end
    end
end
_G.MatchaItemScript_Circles = {}

local function getItemType(model)
    local t = TYPES[model.Name:lower()]
    if t then return t end
    for _, child in ipairs(model:GetChildren()) do
        if child:IsA("MeshPart") then
            t = TYPES[child.Name:lower()]
            if t then return t end
        end
    end
    return nil
end

local function newLineSegment()
    local ok, l = pcall(function() return Drawing.new("Line") end)
    if not ok or not l then return nil end
    l.Visible, l.From, l.To, l.Thickness = false, Vector2.new(0,0), Vector2.new(0,0), CONFIG.CircleThickness
    return l
end

local function createCircleSegments(segCount) local segs = {} for i = 1, segCount do local l = newLineSegment() if l then segs[#segs + 1] = l end end return segs end

local function getLocalPosition() local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") return hrp and hrp.Position end

local function createLabel(color) local label = Drawing.new("Text") label.Size, label.Font, label.Center, label.Outline, label.Color, label.Visible = CONFIG.TextSize, Drawing.Fonts.SystemBold, true, true, color, false table.insert(_G.MatchaItemScript_Labels, label) return label end

local function getLabel(index)
    local item, label = State.Items[index], State.Labels[index]
    local color = item.Meta.Color
    if not label then
        label = createLabel(color)
        State.Labels[index] = label
    elseif label.Color ~= color then
        label.Color = color
    end
    return label
end

local function ensureCircleSegments(index)
    if not State.Circles[index] then
        State.Circles[index] = createCircleSegments(Segments)
        State.CircleColors[index] = {}
        for _, seg in ipairs(State.Circles[index]) do
            table.insert(_G.MatchaItemScript_Circles, seg)
        end
    end
    return State.Circles[index]
end

local function hideLabels() hideList(State.Labels) end
local function hideCircles() hideList(State.Circles) end

local function scanItems()
    if _G.MatchaItemScript_RunId ~= State.RunId then return end
    
    local itemsContainer = Workspace:FindFirstChild("Ignore")
    if itemsContainer then itemsContainer = itemsContainer:FindFirstChild("Items") end
    
    if not itemsContainer then
        State.Items = {}
        hideLabels(); hideCircles()
        trim(State.Labels, State.LabelCache, 0, removeDrawing)
        trim(State.Circles, State.CircleColors, 0, function(circle)
            if circle then for _, seg in ipairs(circle) do removeDrawing(seg) end end
        end)
        return
    end
    
    local newItems = {}
    for _, model in ipairs(itemsContainer:GetChildren()) do
        if model:IsA("Model") then
            local matchedName = getItemType(model)
            if matchedName then
                local boxPart = model:FindFirstChild("Box")
                if boxPart and boxPart:IsA("BasePart") then
                    table.insert(newItems, { Part = boxPart, Meta = ITEM_META[matchedName] })
                end
            end
        end
    end
    State.Items = newItems
    trim(State.Labels, State.LabelCache, #State.Items, removeDrawing)
    trim(State.Circles, State.CircleColors, #State.Items, function(circle)
        if circle then for _, seg in ipairs(circle) do removeDrawing(seg) end end
    end)
end

local function updateItemEsp()
    if _G.MatchaItemScript_RunId ~= State.RunId then return end
    if not Workspace.CurrentCamera then hideLabels(); hideCircles(); return end
    
    local charPos = getLocalPosition()
    if not charPos then hideLabels(); hideCircles(); return end
    
    table.clear(State.VisibleItems)

    for i = #State.Items, 1, -1 do
        local data = State.Items[i]
        local part = data and data.Part
        if not isValidItemPart(part) then
            removeItemEntry(i)
        end
    end

    local visibleCount = 0
    
    for i, data in ipairs(State.Items) do
        local part = data.Part
        local pos = getPartPosition(part)
        if pos then
            local dx, dy, dz = pos.X - charPos.X, pos.Y - charPos.Y, pos.Z - charPos.Z
            local distSq = dx*dx + dy*dy + dz*dz
            if distSq <= MaxDistanceSq then
                local screenPos, onScreen = WorldToScreen(pos)
                if onScreen then
                    visibleCount = visibleCount + 1
                    State.VisibleItems[visibleCount] = { Index = i, DistanceSq = distSq, ScreenPos = screenPos, WorldPos = pos }
                else
                    hideLabel(i); hideCircle(i)
                    State.LabelCache[i] = nil
                end
            else
                hideLabel(i); hideCircle(i)
                State.LabelCache[i] = nil
            end
        else
            hideLabel(i); hideCircle(i)
            State.LabelCache[i] = nil
            if data then data.Part = nil end
        end
    end
    
    local showCount = math.min(visibleCount, CONFIG.MaxVisible)
    for i = 1, showCount do
        local bestIdx, bestDist = i, State.VisibleItems[i].DistanceSq
        for j = i + 1, visibleCount do
            if State.VisibleItems[j].DistanceSq < bestDist then
                bestDist, bestIdx = State.VisibleItems[j].DistanceSq, j
            end
        end
        if bestIdx ~= i then
            State.VisibleItems[i], State.VisibleItems[bestIdx] = State.VisibleItems[bestIdx], State.VisibleItems[i]
        end
    end
    
    for idx = 1, showCount do
        local item = State.VisibleItems[idx]
        local distance = math.sqrt(item.DistanceSq)
        local label = getLabel(item.Index)
        local circle = ensureCircleSegments(item.Index)
        local color = State.Items[item.Index].Meta.Color
        local colorCache = State.CircleColors[item.Index]
        
        label.Position = Vector2.new(item.ScreenPos.X, item.ScreenPos.Y - CONFIG.TextYOffset)
        local meters = math.floor(distance)
        if State.LabelCache[item.Index] ~= meters then
            State.LabelCache[item.Index] = meters
            label.Text = meters .. "m"
        end
        label.Visible = true
        
        local alpha = 1 - distance * FadeMul
        if alpha <= 0 then
            for _, seg in ipairs(circle) do seg.Visible = false end
        else
            if alpha > 1 then alpha = 1 end
            local segCount, centerWorld = #circle, item.WorldPos - CircleOffset
            for j = 1, segCount do
                local off1, off2 = CircleOffsets[j], CircleOffsets[(j % segCount) + 1]
                local w1, w2 = centerWorld + off1, centerWorld + off2
                local sp1, on1 = WorldToScreen(w1)
                local sp2, on2 = WorldToScreen(w2)
                local seg = circle[j]
                if on1 and on2 and seg then
                    seg.From, seg.To = sp1, sp2
                    if colorCache[j] ~= color then
                        colorCache[j] = color
                        seg.Color = color
                    end
                    seg.Transparency, seg.Visible = alpha, true
                elseif seg then
                    seg.Visible = false
                end
            end
        end
    end
    
    for idx = showCount + 1, visibleCount do
        hideCircle(State.VisibleItems[idx].Index)
        hideLabel(State.VisibleItems[idx].Index)
    end
end

local function updateZombieHeads()
    local infectedContainer = Workspace:FindFirstChild("Entities")
    if infectedContainer then infectedContainer = infectedContainer:FindFirstChild("Infected") end
    if not infectedContainer then
        table.clear(State.ZombieHeads); table.clear(State.ZombieHealth)
        return
    end
    
    local seen = State.SeenZombies
    table.clear(seen)
    
    for _, zombie in ipairs(infectedContainer:GetChildren()) do
        if zombie:IsA("Model") then
            local addr = zombie.Address or tostring(zombie)
            seen[addr] = true
            if not State.ZombieHeads[addr] then
                local humanoid, head = zombie:FindFirstChild("Humanoid"), zombie:FindFirstChild("Head")
                if humanoid and humanoid.Health > 0 and head and head:IsA("BasePart") then
                    State.ZombieHeads[addr], State.ZombieHealth[addr] = head, humanoid
                end
            end
        end
    end
    
    for addr in pairs(State.ZombieHeads) do
        if not seen[addr] then
            State.ZombieHeads[addr], State.ZombieHealth[addr] = nil, nil
        end
    end
    
    for addr, head in pairs(State.ZombieHeads) do
        if head and head.Parent and head.Size ~= TargetHeadSize then
            local health = State.ZombieHealth[addr]
            if health and health.Health > 0 then
                pcall(function() head.Size = TargetHeadSize end)
            else
                State.ZombieHeads[addr], State.ZombieHealth[addr] = nil, nil
            end
        end
    end
end

local KnownPlayers = {}
local LastPlayerList

local function getGroupRank(userId)
    if State.RankCache[userId] then
        return State.RankCache[userId].rank, State.RankCache[userId].role
    end

    local ok, response = pcall(function()
        return game:HttpGet("https://groups.roblox.com/v2/users/" .. userId .. "/groups/roles")
    end)

if not ok or not response or response == "" then
    State.RankCache[userId] = {rank = 0, role = "Unknown"}
    return 0, "Unknown"
end

    for entry in response:gmatch('{"group".-"role".-}') do
        local idStr = entry:match('"group".-"id"%s*:%s*(%d+)')
        local rankStr = entry:match('"rank"%s*:%s*(%d+)')
        local nameStr = entry:match('"role".-"name"%s*:%s*"([^"]+)"')

        if idStr and tonumber(idStr) == CONFIG.StaffGroupId then
            local rank = tonumber(rankStr) or 0
            local role = nameStr or "Unknown"

            State.RankCache[userId] = { rank = rank, role = role }
            return rank, role
        end
    end

    State.RankCache[userId] = { rank = 0, role = "Unknown" }
    return 0, "Unknown"
end

local function showStaffAlert(playerName, roleName, duration)
    duration = duration or 6
    if notify then
        pcall(function()
            notify(playerName .. " is in the server! " .. roleName, "Staff Detected", duration)
        end)
    end
end

local function handlePlayer(player)
    local userId = player.UserId
    if not userId then return end
    if KnownPlayers[userId] then return end

    KnownPlayers[userId] = player.Name

    task.spawn(function()
        local rank, roleName = getGroupRank(userId)
        if rank >= CONFIG.MinStaffRank then
            showStaffAlert(player.Name, roleName)
        end
    end)
end

local function updateStaffCheck()
    if _G.MatchaItemScript_RunId ~= State.RunId then return end

    local present = {}
    local players = Players:GetPlayers()
    local playerList = ""

    for index, player in ipairs(players) do
        if index > 1 then playerList = playerList .. ", " end
        playerList = playerList .. player.Name
    end

    if playerList == "" then playerList = "None" end

    if playerList ~= LastPlayerList then
        LastPlayerList = playerList
        print("[Staff Detector] CHECKING " .. #players .. " PLAYER(S) | " .. playerList)
    end

    for _, player in ipairs(players) do
        local userId = player.UserId
        if userId then
            present[userId] = true
            handlePlayer(player)
        end
    end

    for userId in pairs(KnownPlayers) do
        if not present[userId] then
            KnownPlayers[userId] = nil
        end
    end
end

updateStaffCheck()
print("[Staff Detector] Ready.")

loop(CONFIG.CacheClearInterval, function() table.clear(State.RankCache) end)
loop(CONFIG.ScanInterval, scanItems)
loop(CONFIG.UpdateInterval, updateItemEsp)
loop(CONFIG.ZombieUpdateInterval, updateZombieHeads)
loop(CONFIG.StaffCheckInterval, updateStaffCheck)

if notify then pcall(function() notify("Loaded", "", 3) end) end
