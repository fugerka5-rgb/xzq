-- ===================== FARMING (Rayfield UI) =====================

-- Необходимые переменные (должны быть определены в основном скрипте)
local rs = game:GetService("ReplicatedStorage")
local packets = require(rs.Modules.Packets)
local plr = game.Players.LocalPlayer
local char = plr.Character or plr.CharacterAdded:Wait()
local root = char:WaitForChild("HumanoidRootPart")
local runs = game:GetService("RunService")
-- TweenService больше не нужен (движение через CFrame)

-- Обновление root при респавне
plr.CharacterAdded:Connect(function(newChar)
    char = newChar
    root = char:WaitForChild("HumanoidRootPart")
end)

-- Mapping фруктов -> itemID
local fruittoitemid = {
    Bloodfruit = 94,
    Bluefruit = 377,
    Lemon = 99,
    Coconut = 1,
    Jelly = 604,
    Banana = 606,
    Orange = 602,
    Oddberry = 32,
    Berry = 35,
    Strangefruit = 302,
    Strawberry = 282,
    Sunfruit = 128,
    Pumpkin = 80,
    ["Prickly Pear"] = 378,
    Apple = 243,
    Barley = 247,
    Cloudberry = 101,
    Carrot = 147
}

-- ВАЖНО: эти переменные должны быть объявлены ДО циклов (Lua scope)
local selectedFruit = "Bloodfruit"

-- Посадка/подбор
local function plant(entityid, itemID)
    if packets.InteractStructure and packets.InteractStructure.send then
        packets.InteractStructure.send({ entityID = entityid, itemID = itemID })
    end
end

local function pickup(entityid)
    if packets.Pickup and packets.Pickup.send then
        packets.Pickup.send(entityid)
    end
end

-- Поиск Plant Box в радиусе
local function getpbs(range)
    local plantboxes = {}
    pcall(function()
        local dep = workspace:FindFirstChild("Deployables")
        if not dep or not root or not root.Parent then return end
        local rootPos = root.Position

        for _, deployable in ipairs(dep:GetChildren()) do
            if deployable:IsA("Model") and deployable.Name == "Plant Box" then
                local entityid = deployable:GetAttribute("EntityID")
                local ppart = deployable.PrimaryPart or deployable:FindFirstChildWhichIsA("BasePart")
                if entityid and ppart then
                    local dist = (ppart.Position - rootPos).Magnitude
                    if dist <= range then
                        plantboxes[#plantboxes+1] = {
                            entityid = entityid,
                            deployable = deployable,
                            dist = dist,
                            cf = ppart.CFrame,
                            pos = ppart.Position,
                        }
                    end
                end
            end
        end

        table.sort(plantboxes, function(a,b) return a.dist < b.dist end)
    end)
    return plantboxes
end

-- Поиск кустов (по имени) в радиусе
local function getbushes(range, fruitname)
    local bushes = {}
    pcall(function()
        if not root or not root.Parent then return end
        local rootPos = root.Position

        local key = tostring(fruitname or "")
        for _, model in ipairs(workspace:GetChildren()) do
            local ok, hasKey = pcall(function() return model:IsA("Model") and model.Name:find(key) end)
            if ok and hasKey then
                local ppart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
                if ppart then
                    local dist = (ppart.Position - rootPos).Magnitude
                    if dist <= range then
                        local entityid = model:GetAttribute("EntityID")
                        if entityid then
                            bushes[#bushes+1] = {
                                entityid = entityid,
                                model = model,
                                dist = dist,
                                cf = ppart.CFrame,
                                pos = ppart.Position,
                            }
                        end
                    end
                end
            end
        end

        table.sort(bushes, function(a,b) return a.dist < b.dist end)
    end)
    return bushes
end

-- ===================== Movement (Heartbeat + Lerp rotation, constant speed) =====================
local moveToPlantBoxEnabled = false
local moveToBushPlantBoxEnabled = false
local moveRange = 250
local moveHeight = 5
local moveSmoothness = 0.08 -- как в примере
local moveSpeed = 20.7 -- ВСЕГДА постоянная скорость
local MOVE_SCAN_CD = 0.25 -- кэш целей (не лагало)
local MOVE_MIN_DIST = 2 -- игнорируем цели "под ногами"
local MOVE_ARRIVE_DIST = 1.2 -- чтобы не было микро-остановок у цели
local MOVE_BLACKLIST_TTL = 0.8 -- сек: чтобы не залипать на одном пустом боксе пока не посадит seed

local moveTarget = nil -- { kind="pb"/"bush", id=number|string|nil, cf=CFrame, pos=Vector3 }
local moveLastScan = 0
local cachedMovePbs = {}
local cachedMoveBushes = {}
local moveBlacklistUntil = {} -- [entityID]=timeUntil

local function refreshMoveCache()
    local now = tick()
    if (now - moveLastScan) < MOVE_SCAN_CD then return end
    moveLastScan = now

    -- не трогаем Workspace слишком часто
    cachedMovePbs = getpbs(moveRange)
    cachedMoveBushes = getbushes(moveRange, selectedFruit)
end

local function isBlacklisted(entityID)
    if entityID == nil then return false end
    local t = moveBlacklistUntil[entityID]
    return (t ~= nil) and (t > tick())
end

local function blacklist(entityID)
    if entityID == nil then return end
    moveBlacklistUntil[entityID] = tick() + MOVE_BLACKLIST_TTL
end

local function pickMoveTarget()
    if not root or not root.Parent then return nil end
    refreshMoveCache()

    -- выбираем первый валидный пустой plant box (кэш уже отсортирован)
    local function firstEmptyBox()
        for _, box in ipairs(cachedMovePbs) do
            if box.deployable and box.deployable.Parent and box.pos then
                if not box.deployable:FindFirstChild("Seed") then
                    if box.dist and box.dist >= MOVE_MIN_DIST then
                        if not isBlacklisted(box.entityid) then
                            return box
                        end
                    end
                end
            end
        end
        return nil
    end

    -- выбираем первый валидный bush (кэш уже отсортирован)
    local function firstBush()
        for _, b in ipairs(cachedMoveBushes) do
            if b.pos and b.dist and b.dist >= MOVE_MIN_DIST then
                if not isBlacklisted(b.entityid) then
                return b
                end
            end
        end
        return nil
    end

    local chosen = nil -- {kind,id,pos}

    if moveToBushPlantBoxEnabled then
        local b = firstBush()
        local box = firstEmptyBox()
        if b and box then
            chosen = (box.dist < b.dist)
                and { kind = "pb", id = box.entityid, pos = box.pos }
                or  { kind = "bush", id = b.entityid, pos = b.pos }
        elseif box then
            chosen = { kind = "pb", id = box.entityid, pos = box.pos }
        elseif b then
            chosen = { kind = "bush", id = b.entityid, pos = b.pos }
        end
    elseif moveToPlantBoxEnabled then
        local box = firstEmptyBox()
        if box then chosen = { kind = "pb", id = box.entityid, pos = box.pos } end
    end

    if not chosen or not chosen.pos then return nil end

    local pos = Vector3.new(chosen.pos.X, chosen.pos.Y + moveHeight, chosen.pos.Z)
    return {
        kind = chosen.kind,
        id = chosen.id,
        pos = pos,
    }
end

runs.Heartbeat:Connect(function(deltaTime)
    if not root or not root.Parent then return end
    if (not moveToPlantBoxEnabled) and (not moveToBushPlantBoxEnabled) then
        moveTarget = nil
        return
    end

    -- если цели нет или мы "долетели" — выбираем следующую
    if not moveTarget then
        moveTarget = pickMoveTarget()
        return
    end

    local curPos = root.Position
    local goalPos = moveTarget.pos
    if not goalPos then
        moveTarget = nil
        return
    end

    -- защита от "битых" координат, которые могут ломать камеру/улетать
    if goalPos.X ~= goalPos.X or goalPos.Y ~= goalPos.Y or goalPos.Z ~= goalPos.Z then
        blacklist(moveTarget.id)
        moveTarget = nil
        return
    end
    if math.abs(goalPos.X) > 1e7 or math.abs(goalPos.Y) > 1e7 or math.abs(goalPos.Z) > 1e7 then
        blacklist(moveTarget.id)
        moveTarget = nil
        return
    end

    local flatDist = (Vector3.new(curPos.X, 0, curPos.Z) - Vector3.new(goalPos.X, 0, goalPos.Z)).Magnitude

    -- долетели: blacklist и сразу берём следующую (НЕ ждём seed)
    if flatDist < MOVE_ARRIVE_DIST then
        blacklist(moveTarget.id)
        moveLastScan = 0 -- форсим перескан
        moveTarget = pickMoveTarget()
        return
    end

    -- постоянная скорость 20.7
    local diff = goalPos - curPos
    if diff.Magnitude < 0.01 then return end
    local dir = diff.Unit
    local step = math.min(diff.Magnitude, moveSpeed * deltaTime)
    local newPos = curPos + dir * step

    -- ВАЖНО: не крутим персонажа (чтобы камера не "улетала"), двигаем только позицию.
    local rot = root.CFrame - root.CFrame.Position
    root.CFrame = CFrame.new(newPos) * rot
end)

-- ===================== UI =====================
local FarmingTab = Window:CreateTab("Farming", 4483362458)

local autoPlantEnabled = false
local plantRange = 30
local plantDelay = 0.10
local plantMaxPerCycle = 4

local autoHarvestEnabled = false
local harvestRange = 30
local harvestMaxPerCycle = 20

selectedFruit = "Bloodfruit"

-- ===================== Visual: Plant Range Ring (Optimized) =====================
local showPlantRange = false
local plantRingFolder = nil
local plantRingParts = {}
local RING_SEGMENTS = 12
local ringLastRadius = 0

local function destroyPlantRing()
    if plantRingFolder then
        pcall(function() plantRingFolder:Destroy() end)
        plantRingFolder = nil
        plantRingParts = {}
        ringLastRadius = 0
    end
end

local function ensurePlantRing()
    if plantRingFolder and plantRingFolder.Parent and #plantRingParts > 0 then return end
    destroyPlantRing()
    local folder = Instance.new("Folder")
    folder.Name = "_PlantRangeRing"
    folder.Parent = workspace
    plantRingFolder = folder
    plantRingParts = {}
    local ringColor = Color3.fromRGB(0, 255, 120)
    for i = 0, RING_SEGMENTS - 1 do
        local part = Instance.new("Part")
        part.Name = "_RingSeg" .. i
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.CastShadow = false
        part.Material = Enum.Material.Neon
        part.Color = ringColor
        part.Transparency = 0.3
        part.Size = Vector3.new(1, 0.2, 0.2)
        part.Parent = folder
        table.insert(plantRingParts, part)
    end
end

-- Обновление кольца Plant Range (оптимизировано)
task.spawn(function()
    while true do
        if showPlantRange and root and root.Parent then
            ensurePlantRing()
            local centerPos = Vector3.new(root.Position.X, root.Position.Y - 3, root.Position.Z)
            local radius = plantRange
            local needSizeUpdate = (ringLastRadius ~= radius)
            ringLastRadius = radius
            local segLen = radius * 2 * math.sin(math.pi / RING_SEGMENTS) + 0.15
            for i, part in ipairs(plantRingParts) do
                local midAngle = ((i - 1) / RING_SEGMENTS) * math.pi * 2 + (math.pi / RING_SEGMENTS)
                local x = centerPos.X + math.cos(midAngle) * radius
                local z = centerPos.Z + math.sin(midAngle) * radius
                if needSizeUpdate then
                    part.Size = Vector3.new(segLen, 0.2, 0.2)
                end
                part.CFrame = CFrame.new(x, centerPos.Y, z) * CFrame.Angles(0, -midAngle + math.rad(90), 0)
            end
            task.wait(0.03)
        else
            destroyPlantRing()
            task.wait(0.1)
        end
    end
end)

FarmingTab:CreateDropdown({
    Name = "Select Fruit",
    Options = {"Bloodfruit", "Bluefruit", "Lemon", "Coconut", "Jelly", "Banana", "Orange", "Oddberry", "Berry", "Strangefruit", "Strawberry", "Sunfruit", "Pumpkin", "Prickly Pear", "Apple", "Barley", "Cloudberry", "Carrot"},
    CurrentOption = "Bloodfruit",
    Flag = "fruitdropdown",
    Callback = function(v) selectedFruit = v or "Bloodfruit" end,
})

FarmingTab:CreateToggle({
    Name = "Auto Plant",
    CurrentValue = false,
    Flag = "planttoggle",
    Callback = function(v) autoPlantEnabled = v end,
})

FarmingTab:CreateSlider({
    Name = "Plant Range",
    Range = {1, 30},
    Increment = 1,
    Suffix = " studs",
    CurrentValue = 30,
    Flag = "plantrange",
    Callback = function(v) plantRange = v end,
})

FarmingTab:CreateToggle({
    Name = "Show Plant Range",
    CurrentValue = false,
    Flag = "showPlantRange",
    Callback = function(v)
        showPlantRange = v
        if not v then destroyPlantRing() end
    end,
})

FarmingTab:CreateSlider({
    Name = "Plant Delay (s)",
    Range = {0.01, 1.00},
    Increment = 0.01,
    Suffix = " s",
    CurrentValue = 0.10,
    Flag = "plantdelay",
    Callback = function(v) plantDelay = v end,
})

FarmingTab:CreateSlider({
    Name = "Max plants / cycle",
    Range = {1, 12},
    Increment = 1,
    CurrentValue = 4,
    Flag = "plantmax",
    Callback = function(v) plantMaxPerCycle = v end,
})

FarmingTab:CreateToggle({
    Name = "Auto Harvest",
    CurrentValue = false,
    Flag = "harvesttoggle",
    Callback = function(v) autoHarvestEnabled = v end,
})

FarmingTab:CreateSlider({
    Name = "Harvest Range",
    Range = {1, 30},
    Increment = 1,
    Suffix = " studs",
    CurrentValue = 30,
    Flag = "harvestrange",
    Callback = function(v) harvestRange = v end,
})

FarmingTab:CreateSlider({
    Name = "Max pickups / cycle",
    Range = {1, 80},
    Increment = 1,
    CurrentValue = 20,
    Flag = "harvestmax",
    Callback = function(v) harvestMaxPerCycle = v end,
})

-- ===================== Movement UI =====================
FarmingTab:CreateToggle({
    Name = "Move to Plant Box (Lerp)",
    CurrentValue = false,
    Flag = "moveToPlantBox",
    Callback = function(v)
        moveToPlantBoxEnabled = v
        if v then
            moveToBushPlantBoxEnabled = false
        else
            moveTargetCF = nil
        end
    end,
})

FarmingTab:CreateToggle({
    Name = "Move to Bush + Plant Box (Lerp)",
    CurrentValue = false,
    Flag = "moveToBushPlantBox",
    Callback = function(v)
        moveToBushPlantBoxEnabled = v
        if v then
            moveToPlantBoxEnabled = false
        else
            moveTargetCF = nil
        end
    end,
})

FarmingTab:CreateSlider({
    Name = "Move Range",
    Range = {1, 250},
    Increment = 1,
    Suffix = " studs",
    CurrentValue = 250,
    Flag = "moveRange",
    Callback = function(v) moveRange = v end,
})

FarmingTab:CreateSlider({
    Name = "Move Height",
    Range = {0, 8},
    Increment = 0.5,
    Suffix = " studs",
    CurrentValue = 5,
    Flag = "moveHeight",
    Callback = function(v) moveHeight = v end,
})

FarmingTab:CreateSlider({
    Name = "Move Smoothness",
    Range = {0.01, 0.20},
    Increment = 0.01,
    CurrentValue = 0.08,
    Flag = "moveSmoothness",
    Callback = function(v) moveSmoothness = v end,
})

-- Скорость фиксированная 20.7, слайдера нет (по запросу)

-- ===================== Loops =====================

-- Auto Plant (оптимизировано)
task.spawn(function()
    local lastScan = 0
    local cachedPbs = {}
    local SCAN_INTERVAL = 0.5

    while true do
        if autoPlantEnabled then
            if not root or not root.Parent then
                char = plr.Character or plr.CharacterAdded:Wait()
                root = char:WaitForChild("HumanoidRootPart")
            end

            local now = tick()
            if (now - lastScan) >= SCAN_INTERVAL then
                cachedPbs = getpbs(plantRange)
                lastScan = now
            end

            local itemID = fruittoitemid[selectedFruit] or 94
            local planted = 0
            for _, box in ipairs(cachedPbs) do
                if planted >= plantMaxPerCycle then break end
                if box.deployable and box.deployable.Parent and not box.deployable:FindFirstChild("Seed") then
                    plant(box.entityid, itemID)
                    planted = planted + 1
                    if planted < plantMaxPerCycle then
                        task.wait() -- мини-пауза между посадками
                    end
                end
            end

            task.wait(math.max(0.25, plantDelay))
        else
            task.wait(0.2)
        end
    end
end)

-- Auto Harvest (оптимизировано)
task.spawn(function()
    local lastScan = 0
    local cachedBushes = {}
    local SCAN_INTERVAL = 0.4

    while true do
        if autoHarvestEnabled then
            if not root or not root.Parent then
                char = plr.Character or plr.CharacterAdded:Wait()
                root = char:WaitForChild("HumanoidRootPart")
            end

            local now = tick()
            if (now - lastScan) >= SCAN_INTERVAL then
                cachedBushes = getbushes(harvestRange, selectedFruit)
                lastScan = now
            end

            local n = 0
            for _, b in ipairs(cachedBushes) do
                if n >= harvestMaxPerCycle then break end
                pickup(b.entityid)
                n = n + 1
            end

            task.wait(0.15)
        else
            task.wait(0.2)
        end
    end
end)

-- (ЛОГИКА ПЕРЕДВИЖЕНИЯ УДАЛЕНА ПО ЗАПРОСУ)

