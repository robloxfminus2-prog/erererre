--[[
    TheLostFront.lua  —  game-specific silent aim
    Game: "The Lost Front" (Roblox)

    Protocol (reverse-engineered from RemoteSpy v5 capture):
      The fire remote lives at ReplicatedStorage.<obfuscated>:FireServer(buffer)
      where the remote name and caller script are randomized per server, but the
      payload is always identifiable by:
          arg[1] is a buffer
          buffer[0] == 0x04          (opcode = "fire")
          buffer ends with 00 00     (2-byte trailing padding)
          length is weapon-dependent (~115-120 bytes for typical weapons)

      The last 14 bytes are: 12-byte hit Vector3 (3 x float32 LE) + 2 zero bytes.

      Silent aim works by replacing those 12 bytes with the chosen target's
      world position. Origin, weapon name, camera CFrame, mouse coords, fire
      flags, and per-shot UUID are all left untouched, so the packet still
      passes structural validation.

    Public API at bottom: SilentAim:Toggle(), :SetFOV(n), :SetTargetPart(name), etc.
--]]

----------------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------------
local Config = {
    Enabled        = true,
    TargetPart     = "Head",            -- "Head" or "HumanoidRootPart"
    FOV            = 150,               -- pixel radius around cursor; 0 = unlimited
    TeamCheck      = true,
    AliveCheck     = true,
    WallCheck      = false,             -- if true, target must be visible from camera
    RangeCheck     = true,              -- skip targets beyond MaxRange (server-side anti-distance)
    MaxRange       = 1500,              -- studs
    OnlyWhenAimingNear = false,         -- if true, only redirect when camera is roughly pointed at target
    AimNearTolerance   = 0.85,          -- dot(cameraLook, originToTarget) must exceed this
    ToggleKey      = Enum.KeyCode.RightShift,
    DrawFovRing    = true,
    FovColor       = Color3.fromRGB(255, 80, 120),
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
-- FOV RING (optional)
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

    RunService.RenderStepped:Connect(function()
        if not fovRing then return end
        local pos = UserInputSvc:GetMouseLocation()
        fovRing.Position = Vector2.new(pos.X, pos.Y)
        fovRing.Radius   = Config.FOV
        fovRing.Color    = Config.FovColor
        fovRing.Visible  = Config.Enabled and Config.FOV > 0
    end)
end

----------------------------------------------------------------------
-- TARGET RESOLUTION
----------------------------------------------------------------------
local function isVisible(part)
    if not part then return false end
    local origin = Camera.CFrame.Position
    local dir    = part.Position - origin
    local rp     = RaycastParams.new()
    rp.FilterType        = Enum.RaycastFilterType.Exclude
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

local function getClosestTarget()
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

----------------------------------------------------------------------
-- BUFFER REWRITE
----------------------------------------------------------------------
local function isFirePacket(b)
    if typeof(b) ~= "buffer" then return false end
    local len = buffer.len(b)
    if len < 50 then return false end                    -- skip heartbeats / small pings
    if buffer.readu8(b, 0) ~= 0x04 then return false end -- opcode must be "fire"
    -- trailing 2 zero bytes
    if buffer.readu8(b, len - 1) ~= 0x00 then return false end
    if buffer.readu8(b, len - 2) ~= 0x00 then return false end
    return true
end

local function rewriteHit(b, pos)
    local len    = buffer.len(b)
    local newBuf = buffer.create(len)
    buffer.copy(newBuf, 0, b, 0, len)
    -- hit Vector3 is at bytes [len-14 .. len-3]; trailing [len-2..len-1] = 00 00
    buffer.writef32(newBuf, len - 14, pos.X)
    buffer.writef32(newBuf, len - 10, pos.Y)
    buffer.writef32(newBuf, len -  6, pos.Z)
    return newBuf
end

----------------------------------------------------------------------
-- HOOK
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
            local target = getClosestTarget()
            if target then
                args[1] = rewriteHit(args[1], target.Position)
                return oldNamecall(self, table.unpack(args))
            end
        end
    end
    return oldNamecall(self, ...)
end)

----------------------------------------------------------------------
-- TOGGLE HOTKEY
----------------------------------------------------------------------
UserInputSvc.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == Config.ToggleKey then
        Config.Enabled = not Config.Enabled
        print("[TheLostFront SilentAim] " .. (Config.Enabled and "ON" or "OFF"))
    end
end)

----------------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------------
local SilentAim = { Config = Config }

function SilentAim:Toggle(state)
    Config.Enabled = (state == nil) and (not Config.Enabled) or state
end
function SilentAim:SetFOV(n)             Config.FOV         = math.max(0, n) end
function SilentAim:SetTargetPart(name)   Config.TargetPart  = name           end
function SilentAim:SetTeamCheck(b)       Config.TeamCheck   = b              end
function SilentAim:SetWallCheck(b)       Config.WallCheck   = b              end
function SilentAim:SetMaxRange(n)        Config.MaxRange    = n              end
function SilentAim:SetAimNearOnly(b, t)
    Config.OnlyWhenAimingNear = b
    if t then Config.AimNearTolerance = t end
end

print("[TheLostFront SilentAim] loaded — RightShift to toggle, FOV " .. Config.FOV)
return SilentAim
