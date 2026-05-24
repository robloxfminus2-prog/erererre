--[[
    TheLostFront.lua  —  game-specific silent aim + snaplines
    Game: "The Lost Front" (Roblox)

    Protocol (reverse-engineered from RemoteSpy v5 capture):
      Fire remote: ReplicatedStorage.<obfuscated>:FireServer(buffer)
        - remote name and caller script are randomized per server
        - identified by buffer signature: byte[0] == 0x04, trailing 00 00,
          length >= 50 bytes
        - last 14 bytes = hit Vector3 (3 x float32 LE) + 2 zero bytes
        - silent aim swaps just those 12 hit-position bytes; everything else
          (origin, weapon name, camera CFrame, mouse coords, fire flags,
          per-shot UUID) is left untouched so structural validation passes

    Features:
      - silent aim with FOV / team / wall / range / alive checks
      - snaplines (lines from screen anchor to every visible enemy/ally)
      - locked-target snapline drawn in distinct color so you can see who
        the next bullet will redirect to
      - per-player name + distance labels
      - hotkeys: RightShift = silent aim toggle, RightAlt = snaplines toggle

    Public API at bottom: SilentAim:Toggle(), :SetFOV(n), :ToggleSnaplines(),
    :SetSnaplineOrigin("Top"|"Center"|"Bottom"|"Mouse"), etc.
--]]

----------------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------------
local Config = {
    -- Silent aim ---------------------------------------------------
    Enabled              = true,
    TargetPart           = "Head",
    FOV                  = 150,
    TeamCheck            = true,
    AliveCheck           = true,
    WallCheck            = false,
    RangeCheck           = true,
    MaxRange             = 1500,
    OnlyWhenAimingNear   = false,
    AimNearTolerance     = 0.85,
    ToggleKey            = Enum.KeyCode.RightShift,
    DrawFovRing          = true,
    FovColor             = Color3.fromRGB(255, 80, 120),

    -- Snaplines ---------------------------------------------------
    SnaplinesEnabled     = true,
    SnaplineOrigin       = "Bottom",            -- "Top" | "Center" | "Bottom" | "Mouse"
    SnaplineEnemy        = Color3.fromRGB(255, 60, 80),
    SnaplineAlly         = Color3.fromRGB(80, 220, 120),
    SnaplineTarget       = Color3.fromRGB(255, 230, 60),
    SnaplineThickness    = 1,
    SnaplineShowAllies   = false,
    SnaplineShowName     = true,
    SnaplineShowDistance = true,
    SnaplineTransparency = 0.85,
    SnaplineToggleKey    = Enum.KeyCode.RightAlt,
}

----------------------------------------------------------------------
-- SERVICES / LOCALS
----------------------------------------------------------------------
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local UserInputSvc = game:GetService("UserInputService")
local Workspace    = game:GetService("Workspace")

local LP           = Players.LocalPlayer
local Camera       = Workspace.CurrentCamera

----------------------------------------------------------------------
-- TARGET RESOLUTION (shared by silent aim + snaplines)
----------------------------------------------------------------------
local function isVisible(part)
    if not part then return false end
    local origin = Camera.CFrame.Position
    local dir    = part.Position - origin
    local rp     = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = { LP.Character }
    local hit = Workspace:Raycast(origin, dir, rp)
    if not hit then return true end
    return hit.Instance:IsDescendantOf(part.Parent)
end

local function validTarget(plr)
    if plr == LP then return nil end
    local char = plr.Character
    if not char then return nil end
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if Config.AliveCheck and (not hum or hum.Health <= 0) then return nil end
    if Config.TeamCheck and LP.Team and plr.Team == LP.Team then return nil end
    local part = char:FindFirstChild(Config.TargetPart) or char:FindFirstChild("HumanoidRootPart")
    if not part then return nil end
    if Config.RangeCheck and (part.Position - Camera.CFrame.Position).Magnitude > Config.MaxRange then
        return nil
    end
    if Config.WallCheck and not isVisible(part) then return nil end
    return part
end

local function resolveTarget()
    if not Config.Enabled then return nil end
    local mouseLoc = UserInputSvc:GetMouseLocation()
    local best, bestDist = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        local part = validTarget(plr)
        if part then
            local sp, onScreen = Camera:WorldToViewportPoint(part.Position)
            if onScreen then
                local d = (Vector2.new(sp.X, sp.Y) - mouseLoc).Magnitude
                if d < bestDist and (Config.FOV == 0 or d <= Config.FOV) then
                    best, bestDist = part, d
                end
            end
        end
    end
    if best and Config.OnlyWhenAimingNear then
        local toTarget = (best.Position - Camera.CFrame.Position).Unit
        if Camera.CFrame.LookVector:Dot(toTarget) < Config.AimNearTolerance then
            return nil
        end
    end
    return best
end

-- _currentTarget is refreshed every render frame by the snaplines loop
-- and read by the FireServer hook for color-consistency between visual + shot
local _currentTarget = nil

----------------------------------------------------------------------
-- FOV RING
----------------------------------------------------------------------
local fovRing
if Drawing and Config.DrawFovRing then
    fovRing = Drawing.new("Circle")
    fovRing.Thickness    = 1
    fovRing.NumSides     = 64
    fovRing.Filled       = false
    fovRing.Transparency = 1
    fovRing.Color        = Config.FovColor
    fovRing.Visible      = false
end

----------------------------------------------------------------------
-- SNAPLINES
----------------------------------------------------------------------
local linePool, textPool = {}, {}

local function getLine(plr)
    local l = linePool[plr]
    if not l then
        l = Drawing.new("Line")
        l.Visible = false
        linePool[plr] = l
    end
    return l
end

local function getText(plr)
    local t = textPool[plr]
    if not t then
        t = Drawing.new("Text")
        t.Size    = 13
        t.Center  = true
        t.Outline = true
        t.Visible = false
        textPool[plr] = t
    end
    return t
end

local function originPoint()
    local vs = Camera.ViewportSize
    local o  = Config.SnaplineOrigin
    if o == "Top"    then return Vector2.new(vs.X / 2, 0)         end
    if o == "Center" then return Vector2.new(vs.X / 2, vs.Y / 2)  end
    if o == "Mouse"  then return UserInputSvc:GetMouseLocation()  end
    return Vector2.new(vs.X / 2, vs.Y) -- Bottom default
end

local function hideAllSnaplines()
    for _, l in pairs(linePool) do l.Visible = false end
    for _, t in pairs(textPool) do t.Visible = false end
end

Players.PlayerRemoving:Connect(function(plr)
    if linePool[plr] then linePool[plr]:Remove(); linePool[plr] = nil end
    if textPool[plr] then textPool[plr]:Remove(); textPool[plr] = nil end
end)

if Drawing then
    RunService.RenderStepped:Connect(function()
        -- keep FOV ring in sync
        if fovRing then
            local mp = UserInputSvc:GetMouseLocation()
            fovRing.Position = Vector2.new(mp.X, mp.Y)
            fovRing.Radius   = Config.FOV
            fovRing.Color    = Config.FovColor
            fovRing.Visible  = Config.Enabled and Config.FOV > 0
        end

        -- refresh locked target for both snapline highlight and fire hook
        _currentTarget = resolveTarget()

        if not Config.SnaplinesEnabled then
            hideAllSnaplines()
            return
        end

        local origin = originPoint()
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP then
                local line = getLine(plr)
                local txt  = getText(plr)
                local char = plr.Character
                local hum  = char and char:FindFirstChildOfClass("Humanoid")
                local part = char and (char:FindFirstChild(Config.TargetPart)
                                       or char:FindFirstChild("HumanoidRootPart"))
                local sameTeam = LP.Team and plr.Team and plr.Team == LP.Team
                local alive    = hum and hum.Health > 0
                local show     = part and alive and (Config.SnaplineShowAllies or not sameTeam)

                if show then
                    local sp, onScreen = Camera:WorldToViewportPoint(part.Position)
                    if onScreen then
                        local color, thick
                        if part == _currentTarget then
                            color = Config.SnaplineTarget
                            thick = Config.SnaplineThickness + 1
                        elseif sameTeam then
                            color = Config.SnaplineAlly
                            thick = Config.SnaplineThickness
                        else
                            color = Config.SnaplineEnemy
                            thick = Config.SnaplineThickness
                        end

                        line.From         = origin
                        line.To           = Vector2.new(sp.X, sp.Y)
                        line.Color        = color
                        line.Thickness    = thick
                        line.Transparency = Config.SnaplineTransparency
                        line.Visible      = true

                        if Config.SnaplineShowName or Config.SnaplineShowDistance then
                            local label = ""
                            if Config.SnaplineShowName then
                                local nm = plr.DisplayName ~= "" and plr.DisplayName or plr.Name
                                label = nm
                            end
                            if Config.SnaplineShowDistance then
                                local d = (part.Position - Camera.CFrame.Position).Magnitude
                                label = label .. (label ~= "" and "  " or "")
                                              .. string.format("[%dm]", math.floor(d / 3.5))
                            end
                            txt.Text     = label
                            txt.Position = Vector2.new(sp.X, sp.Y - 18)
                            txt.Color    = color
                            txt.Visible  = true
                        else
                            txt.Visible = false
                        end
                    else
                        line.Visible = false
                        txt.Visible  = false
                    end
                else
                    line.Visible = false
                    txt.Visible  = false
                end
            end
        end
    end)
end

----------------------------------------------------------------------
-- BUFFER REWRITE
----------------------------------------------------------------------
local function isFirePacket(b)
    if typeof(b) ~= "buffer" then return false end
    local len = buffer.len(b)
    if len < 50 then return false end
    if buffer.readu8(b, 0) ~= 0x04 then return false end
    if buffer.readu8(b, len - 1) ~= 0x00 then return false end
    if buffer.readu8(b, len - 2) ~= 0x00 then return false end
    return true
end

local function rewriteHit(b, pos)
    local len    = buffer.len(b)
    local newBuf = buffer.create(len)
    buffer.copy(newBuf, 0, b, 0, len)
    buffer.writef32(newBuf, len - 14, pos.X)
    buffer.writef32(newBuf, len - 10, pos.Y)
    buffer.writef32(newBuf, len -  6, pos.Z)
    return newBuf
end

----------------------------------------------------------------------
-- FIRE HOOK
----------------------------------------------------------------------
local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local m = getnamecallmethod()
    if Config.Enabled and not checkcaller()
       and m == "FireServer"
       and typeof(self) == "Instance"
       and self:IsA("RemoteEvent")
    then
        local args = { ... }
        if #args == 1 and isFirePacket(args[1]) then
            -- prefer the freshly cached render-frame target; fall back to
            -- a live recompute if snaplines disabled and cache is empty
            local target = _currentTarget or resolveTarget()
            if target then
                args[1] = rewriteHit(args[1], target.Position)
                return oldNamecall(self, table.unpack(args))
            end
        end
    end
    return oldNamecall(self, ...)
end)

----------------------------------------------------------------------
-- HOTKEYS
----------------------------------------------------------------------
UserInputSvc.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == Config.ToggleKey then
        Config.Enabled = not Config.Enabled
        print("[TheLostFront] silent aim " .. (Config.Enabled and "ON" or "OFF"))
    elseif i.KeyCode == Config.SnaplineToggleKey then
        Config.SnaplinesEnabled = not Config.SnaplinesEnabled
        print("[TheLostFront] snaplines " .. (Config.SnaplinesEnabled and "ON" or "OFF"))
    end
end)

----------------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------------
local SilentAim = { Config = Config }

function SilentAim:Toggle(state)
    Config.Enabled = (state == nil) and (not Config.Enabled) or state
end
function SilentAim:SetFOV(n)            Config.FOV         = math.max(0, n) end
function SilentAim:SetTargetPart(name)  Config.TargetPart  = name           end
function SilentAim:SetTeamCheck(b)      Config.TeamCheck   = b              end
function SilentAim:SetWallCheck(b)      Config.WallCheck   = b              end
function SilentAim:SetMaxRange(n)       Config.MaxRange    = n              end
function SilentAim:SetAimNearOnly(b, t)
    Config.OnlyWhenAimingNear = b
    if t then Config.AimNearTolerance = t end
end

function SilentAim:ToggleSnaplines(state)
    Config.SnaplinesEnabled = (state == nil) and (not Config.SnaplinesEnabled) or state
end
function SilentAim:SetSnaplineOrigin(o)      Config.SnaplineOrigin       = o end
function SilentAim:SetSnaplineEnemyColor(c)  Config.SnaplineEnemy        = c end
function SilentAim:SetSnaplineAllyColor(c)   Config.SnaplineAlly         = c end
function SilentAim:SetSnaplineTargetColor(c) Config.SnaplineTarget       = c end
function SilentAim:SetSnaplineThickness(n)   Config.SnaplineThickness    = n end
function SilentAim:SetShowAllies(b)          Config.SnaplineShowAllies   = b end
function SilentAim:SetShowName(b)            Config.SnaplineShowName     = b end
function SilentAim:SetShowDistance(b)        Config.SnaplineShowDistance = b end

print("[TheLostFront] loaded — RightShift = silent aim, RightAlt = snaplines, FOV " .. Config.FOV)
return SilentAim
