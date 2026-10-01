
if not game:IsLoaded() then game.Loaded:Wait(); end;

--================================================================
--  SINGLE INSTANCE
--  Re-executing replaces the previous copy instead of stacking two
--  hooks / two HUDs. The running copy exposes stop() on getgenv().
--================================================================
local INSTANCE_KEY = "wh_vsh_instance";
do
    local prev = getgenv()[INSTANCE_KEY];
    if type(prev) == "table" and type(prev.stop) == "function" then
        pcall(function() prev.stop("replaced"); end);
    end;
    getgenv()[INSTANCE_KEY] = { stop = nil };
end;

--================================================================
--  SERVICES
--================================================================
local cloneref = cloneref or function(o) return o end;

local Players    = cloneref(game:GetService("Players"));
local RunService = cloneref(game:GetService("RunService"));
local UIS        = cloneref(game:GetService("UserInputService"));
local Workspace  = cloneref(game:GetService("Workspace"));
local RS         = cloneref(game:GetService("ReplicatedStorage"));

local plr = Players.LocalPlayer;
local Connections = {};
local Running = true;
local stop; -- forward declaration: the menu's unload button is built before the
            -- teardown function is defined, so this upvalue must exist first

local cam = Workspace.CurrentCamera;
table.insert(Connections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    cam = Workspace.CurrentCamera;
end));

-- executor API surface, normalised so the script works on the common ones
local hookfunction  = hookfunction or hookfunc;
local newcclosure   = newcclosure or function(f) return f end;
local clonefunction = clonefunction or function(f) return f end;

-- weapon stats for the equipped gun, filled in by the weapon-mod hook further
-- down. Declared up here because the aim code reads it for prediction.
local liveConfigs = setmetatable({}, { __mode = "k" });

local HookStatus = {
    installed    = false,
    shots        = 0,   -- times the game asked for the mouse position
    redirects    = 0,   -- times we replaced it with a target position
    noSpread     = false,
    noRecoil     = false,
    autoFix      = false,   -- weapon auto-repair armed
    renderErrors = 0,
    last         = "no shot yet",
};


--================================================================
--  SETTINGS
--  Plain globals on getgenv() are the single source of truth, exactly
--  like the rest of the repo, so toggles just write here.
--================================================================
getgenv().wh_silent_aim     = true;
getgenv().wh_fov_size       = 150;   -- pixels
getgenv().wh_fov_toggle     = true;  -- draw the FOV circle
getgenv().wh_fov_center     = true;  -- circle stays on screen centre (not the cursor)
getgenv().wh_fov_color      = Color3.fromRGB(150, 0, 255);
getgenv().wh_tracers        = true;
getgenv().wh_tracer_color   = Color3.fromRGB(150, 0, 255);
getgenv().wh_aim_part       = "Head";
getgenv().wh_wallcheck      = false; -- only shoot parts a raycast can actually reach
getgenv().wh_aim_unseen     = true;  -- if nothing is visible, still fire at the locked part
getgenv().wh_target_npcs    = true;
getgenv().wh_ignore_friends = true;
getgenv().wh_max_distance   = 1000;  -- metres (0 = unlimited)
getgenv().wh_prediction     = true;
getgenv().wh_lead           = 1;     -- 1 = exact lead, >1 over-leads, <1 under-leads
getgenv().wh_ragebot        = false; -- ignore the FOV circle: lock anyone on screen
getgenv().wh_autoshoot      = false; -- fire on the locked target without holding LMB
getgenv().wh_no_spread      = true;
getgenv().wh_no_recoil      = true;
getgenv().wh_auto_fix       = false; -- clear a stuck weapon automatically (opt-in)
getgenv().wh_debug_hook     = false; -- print what the hook decides on every shot

-- ESP
getgenv().wh_esp            = true;
getgenv().wh_esp_boxes      = true;
getgenv().wh_esp_names      = true;
getgenv().wh_esp_distance   = true;
getgenv().wh_esp_health     = true;
getgenv().wh_esp_npcs       = false;
getgenv().wh_esp_max_dist   = 500;   -- metres (0 = unlimited)
getgenv().wh_esp_box_color  = Color3.fromRGB(150, 0, 255);
getgenv().wh_esp_name_color = Color3.fromRGB(235, 235, 240);
getgenv().wh_esp_hp_color   = Color3.fromRGB(80, 220, 120);
getgenv().wh_esp_horses     = true;

-- Weapon extras
getgenv().wh_no_bullet_drop = true;
getgenv().wh_instant_hit    = false; -- forces the game's Hitscan path
getgenv().wh_rapidfire      = false;
getgenv().wh_rpm_mult      = 2;     -- RPM multiplier (interval = 60 / RPM)
getgenv().wh_full_auto     = false; -- Semi/Pump guns fire while the button is held

-- Movement
getgenv().wh_speed_on       = false;
getgenv().wh_speed          = 45;    -- extra studs/s appended by CFrame movement
getgenv().wh_shoot_riding   = false; -- keep a gun equipped while seated on a horse

-- Camera / fake rotation
getgenv().wh_fov_custom     = false;
getgenv().wh_fov            = 90;
getgenv().wh_fake_rot       = false;
getgenv().wh_fake_pitch     = 0;
getgenv().wh_fake_yaw       = 180;   -- 180 = body faces backwards
getgenv().wh_fake_roll      = 0;
getgenv().wh_fake_target_based = false; -- face the silent-aim target instead of the camera
getgenv().wh_fake_mode      = "Custom"; -- Custom | Spin | Random

-- Fall damage
getgenv().wh_no_fall        = true;
getgenv().wh_fall_speed     = 60;   -- max downward studs/s while falling
getgenv().wh_fake_spin_speed = 360;    -- deg/s while in Spin
getgenv().wh_fake_rand_int   = 0.4;    -- seconds between random changes

-- Fly (CFrame)
getgenv().wh_fly            = false;
getgenv().wh_fly_speed      = 80;     -- studs/s
getgenv().wh_fly_key        = "F";    -- keybind that toggles fly

-- Lighting
getgenv().wh_amb            = false;
getgenv().wh_amb_color      = Color3.fromRGB(60, 60, 70);
getgenv().wh_outamb         = false;
getgenv().wh_outamb_color   = Color3.fromRGB(120, 120, 130);
getgenv().wh_bright         = false;
getgenv().wh_bright_val     = 2;
getgenv().wh_nofog          = false;
getgenv().wh_time_on        = false;
getgenv().wh_time           = 12;

-- shared distance conversion (matches the repo's ESP / status readouts)
local STUDS_PER_METER = 3.57;

--================================================================
--  DRAWING HELPERS
--================================================================
local hasDrawing = false;
do
    local ok = pcall(function() return Drawing.new("Circle"); end);
    hasDrawing = ok and Drawing ~= nil;
end;

local drawings = {};
local function createObj(kind, args)
    if not hasDrawing then return nil; end;
    local ok, obj = pcall(Drawing.new, kind);
    if not ok or not obj then return nil; end;
    for i, v in next, args do pcall(function() obj[i] = v; end); end;
    table.insert(drawings, obj);
    return obj;
end
local function removeDrawings()
    for _, o in next, drawings do pcall(function() o:Remove(); end); end;
    table.clear(drawings);
end

-- Roblox rejects non-finite numbers in Vector2/Vector3 ("finite number expected") and
-- WorldToViewportPoint returns inf/NaN for geometry on/behind the camera plane. NaN also
-- fails every comparison, so it would otherwise slip past off-screen checks.
local function isFinite(v)
    return v == v and v > -math.huge and v < math.huge;
end
local function isFiniteVec2(v)
    return v ~= nil and isFinite(v.X) and isFinite(v.Y);
end

-- the point the circle sits at and targets are measured from
local function centerPoint()
    if getgenv().wh_fov_center then
        return cam.ViewportSize / 2;
    end;
    return UIS:GetMouseLocation();
end

-- WorldToViewportPoint coords are already in Drawing space; non-finite projections are
-- pushed far away so the target simply never wins the FOV check.
local function toScreen(vp)
    if not (isFinite(vp.X) and isFinite(vp.Y)) then
        return Vector2.new(math.huge, math.huge);
    end;
    return Vector2.new(vp.X, vp.Y);
end

--================================================================
--  FRAMEWORK DISCOVERY
--  The gun system lives under ReplicatedStorage. We locate it by shape
--  rather than by a hard-coded path so a rename or a reshuffle does not
--  break the script: a ModuleScript named RayMouse is the aim source, and
--  the module exposing .ItemConfigs is the weapon config table.
--================================================================
local function findModuleByName(name)
    local found;
    local ok = pcall(function()
        for _, d in next, RS:GetDescendants() do
            if d:IsA("ModuleScript") and d.Name == name then
                found = d;
                return;
            end;
        end;
    end);
    if not ok then return nil; end;
    return found;
end

-- RayMouse may be required before the game's own framework has replicated it in.
local rayMouseModule = findModuleByName("RayMouse");
if not rayMouseModule and RS:FindFirstChild("FrameworkFiles") then
    -- fall back to the framework tree if the plain scan missed it
    pcall(function()
        for _, d in next, RS.FrameworkFiles:GetDescendants() do
            if d:IsA("ModuleScript") and d.Name == "RayMouse" then rayMouseModule = d; return; end;
        end;
    end);
end

--================================================================
--  SILENT AIM  -  TARGET SELECTION
--================================================================
-- One scan produces the current target; the hook then returns its position
-- instead of the cursor's. Kept allocation-light because it runs every frame.
local aimFilter = RaycastParams.new();
aimFilter.FilterType = Enum.RaycastFilterType.Exclude;
aimFilter.IgnoreWater = true;

-- R15 and R6 spellings for each dropdown choice, most specific first
local PART_SETS = {
    ["Head"]      = { "Head" },
    ["Torso"]     = { "UpperTorso", "Torso", "LowerTorso" },
    ["Left Arm"]  = { "LeftUpperArm", "LeftLowerArm", "LeftHand", "Left Arm" },
    ["Right Arm"] = { "RightUpperArm", "RightLowerArm", "RightHand", "Right Arm" },
    ["Left Leg"]  = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "Left Leg" },
    ["Right Leg"] = { "RightUpperLeg", "RightLowerLeg", "RightFoot", "Right Leg" },
};

-- "Auto": seeded priority used when the player has not picked a single part
local AUTO_ORDER = {
    "Head",
    "UpperTorso", "Torso", "LowerTorso",
    "RightUpperArm", "LeftUpperArm", "RightLowerArm", "LeftLowerArm",
    "RightHand", "LeftHand", "Right Arm", "Left Arm",
    "RightUpperLeg", "LeftUpperLeg", "RightLowerLeg", "LeftLowerLeg",
    "RightFoot", "LeftFoot", "Right Leg", "Left Leg",
};

local function firstPart(model, names)
    -- ipairs, not next: PART_SETS / AUTO_ORDER are priority ordered
    for _, n in ipairs(names) do
        local p = model:FindFirstChild(n);
        if p and p:IsA("BasePart") then return p; end;
    end;
    return nil;
end

-- Resolve the part we want to shoot on this model: the chosen set first, then
-- (as a safety net) the seeded priority so we never miss an oddly named rig.
local function resolveAimPart(model)
    local wanted = getgenv().wh_aim_part;
    if wanted and wanted ~= "Auto" and PART_SETS[wanted] then
        local p = firstPart(model, PART_SETS[wanted]);
        if p then return p; end;
    end;
    return firstPart(model, AUTO_ORDER);
end

local function isWhitelisted(model)
    if not getgenv().wh_ignore_friends then return false; end;
    local owner = Players:GetPlayerFromCharacter(model);
    if not owner or owner == plr then return false; end;
    local ok, friend = pcall(function() return plr:IsFriendsWith(owner.UserId); end);
    return ok and friend == true;
end

-- A model is a valid candidate if it is alive, not us, and either a player or
-- (when enabled) an NPC with a Humanoid.
local function isCandidate(model)
    if model == plr.Character then return false; end;
    local hum = model:FindFirstChildOfClass("Humanoid");
    if not hum or hum.Health <= 0 then return false; end;
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart;
    if not root then return false; end;
    if Players:GetPlayerFromCharacter(model) then
        return not isWhitelisted(model);
    end;
    return getgenv().wh_target_npcs == true;
end


--================================================================
--  SILENT AIM  -  TARGET RESOLUTION
--  Runs at most once per frame (memoised) and stores the result in `last`,
--  which both the hook and the HUD read.
--================================================================
local last = { part = nil, pos = nil, dist = nil, visible = false, name = nil };

local frameId = 0;
local scannedFrame = -1;

-- NPC characters are not owned by a Player and the map is far too big to
-- re-scan every frame, so they are tracked through DescendantAdded instead.
local npcCache = {};
local function trackNpc(v)
    if not getgenv().wh_target_npcs then return; end;
    if v:IsA("Model") and v:FindFirstChildOfClass("Humanoid")
        and v ~= plr.Character and not Players:GetPlayerFromCharacter(v) then
        npcCache[v] = true;
    end;
end
table.insert(Connections, Workspace.DescendantAdded:Connect(function(v)
    if Running then trackNpc(v); end;
end));

-- seed the cache once: NPCs already on the map at load never fire DescendantAdded
task.spawn(function()
    if not getgenv().wh_target_npcs then return; end;
    task.wait(1);
    pcall(function()
        for _, v in next, Workspace:GetDescendants() do
            if not Running then break; end;
            trackNpc(v);
        end;
    end);
end);

-- visibility: is anything solid between the camera and this part?
local function isVisible(part, origin)
    -- the filter must never contain nil (Roblox rejects it) and has to be rebuilt
    -- if the local character was respawned since the last scan
    local filter = {};
    if plr.Character then filter[1] = plr.Character; end;
    aimFilter.FilterDescendantsInstances = filter;
    local ok, hit = pcall(Workspace.Raycast, Workspace, origin, part.Position - origin, aimFilter);
    if not ok or not hit then return true; end;
    local model = part:FindFirstAncestorOfClass("Model");
    return model ~= nil and hit.Instance:IsDescendantOf(model);
end
-- LEAD / PREDICTION
-- A projectile weapon needs time to cross the distance, so a moving target has to
-- be led by velocity * (distance / projectile speed). The real ProjectileVelocity
-- comes from the gun's built config (captured in liveConfigs by the weapon-mod
-- hook). A velocity of 0 means the gun is on its Hitscan path, where leading
-- would only make the shot miss - so prediction simply switches itself off.
local function equippedGun()
    local char = plr.Character;
    local tool = char and char:FindFirstChildOfClass("Tool");
    return tool;
end

local function currentGunSpeed()
    local cfg = liveConfigs[equippedGun()];
    if type(cfg) ~= "table" then
        for _, c in next, liveConfigs do cfg = c; break; end;
    end;
    if type(cfg) ~= "table" then return nil; end;
    local sp = cfg.ProjectileVelocity or cfg.ProjectileSpeed;
    if type(sp) ~= "number" then return nil; end;
    return sp;
end

local function predictAim(part, origin)
    local lead = getgenv().wh_prediction and (getgenv().wh_lead or 1) or 0;
    if lead <= 0 then return part.Position; end;
    local speed = currentGunSpeed();
    if not speed or speed <= 0 then return part.Position; end; -- hitscan: no lead
    local vel = part.AssemblyLinearVelocity;
    if not vel or vel.Magnitude < 0.5 then return part.Position; end; -- standing still
    local dist = (part.Position - origin).Magnitude;
    local travel = dist / speed;
    local point = part.Position + vel * (travel * lead);
    -- never lead behind the shooter: a backwards point is always wrong
    if (point - origin):Dot(part.Position - origin) <= 0 then return part.Position; end;
    return point;
end


local function getTarget()
    last.part, last.pos, last.dist, last.visible, last.name = nil, nil, nil, false, nil;
    if not getgenv().wh_silent_aim then return nil; end;
    if not (plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")) then return nil; end;

    local origin = cam.CFrame.Position;
    local center = centerPoint();
    -- ragebot lifts both gates: any character anywhere on screen is lockable,
    -- and the distance cap is ignored, so you can shoot someone off the edge of
    -- the view (or with the FOV circle set tiny)
    local fov = getgenv().wh_ragebot and math.huge or (getgenv().wh_fov_size or 150);
    local maxStuds = getgenv().wh_ragebot and 0 or ((getgenv().wh_max_distance or 0) * STUDS_PER_METER);

    local best, bestScore, bestDist, bestVisible = nil, math.huge, nil, false;

    local function consider(model)
        if not isCandidate(model) then return; end;
        local part = resolveAimPart(model);
        if not part then return; end;
        local distStuds = (part.Position - origin).Magnitude;
        if maxStuds > 0 and distStuds > maxStuds then return; end;
        local scr = toScreen(cam:WorldToViewportPoint(part.Position));
        if not isFiniteVec2(scr) then return; end;
        local sdist = (scr - center).Magnitude;
        if sdist > fov then return; end;
        local visible = true;
        if getgenv().wh_wallcheck then visible = isVisible(part, origin); end;
        -- a visible target always beats a hidden one; ties are broken by
        -- whichever is closest to the crosshair
        local score = sdist + (visible and 0 or 100000);
        if score < bestScore then
            best, bestScore, bestDist, bestVisible = part, score, distStuds, visible;
        end;
    end

    if getgenv().wh_target_npcs then
        for model in next, npcCache do
            if typeof(model) == "Instance" and model.Parent then consider(model); end;
        end;
    end;
    for _, p in next, Players:GetPlayers() do
        if p ~= plr and p.Character then consider(p.Character); end;
    end;

    if not best then return nil; end;
    -- wall check can veto a shot, unless the player wants to fire anyway
    if getgenv().wh_wallcheck and not bestVisible and not getgenv().wh_aim_unseen then
        return nil;
    end;
    last.part, last.pos, last.dist, last.visible = best, predictAim(best, origin), bestDist, bestVisible;
    last.name = best:FindFirstAncestorOfClass("Model") and best:FindFirstAncestorOfClass("Model").Name or "?";
    return best, last.pos;
end

-- one scan per frame, shared by the hook and the HUD
local function currentTarget()
    if scannedFrame ~= frameId then
        getTarget();
        scannedFrame = frameId;
    end;
    return last.part, last.pos;
end


--================================================================
--  SILENT AIM  -  HOOK
--  RayMouse.GetMousePosition is the exact function the gun client reads
--  right before it fires. hookfunction patches the closure itself, so every
--  existing reference - including the gun's cached upvalue - is redirected.
--================================================================
local originalGetMousePosition;
local function installAimHook()
    if HookStatus.installed or not hookfunction or not rayMouseModule then return; end;
    local ok, mod = pcall(require, rayMouseModule);
    if not ok or type(mod) ~= "table" or type(mod.GetMousePosition) ~= "function" then
        return;
    end;
    originalGetMousePosition = clonefunction(mod.GetMousePosition);
    local replacement = newcclosure(function(...)
        if not Running then return originalGetMousePosition(...); end;
        HookStatus.shots = HookStatus.shots + 1;
        -- a mistake here must never break the shot: on any error we pass through
        local part, pos;
        pcall(function() part, pos = currentTarget(); end);
        if part and pos and typeof(pos) == "Vector3" then
            HookStatus.redirects = HookStatus.redirects + 1;
            HookStatus.last = "redirect -> " .. tostring(last.name);
            if getgenv().wh_debug_hook then
                print("[VSH] silent aim -> " .. tostring(last.name));
            end;
            return pos;
        end;
        HookStatus.last = "pass-through";
        return originalGetMousePosition(...);
    end);
    local ok2 = pcall(hookfunction, mod.GetMousePosition, replacement);
    HookStatus.installed = ok2 and true or false;
    if HookStatus.installed then
        print("[VSH] silent aim hook installed");
    else
        warn("[VSH] could not hook RayMouse.GetMousePosition");
    end;
end

-- the framework can still be replicating in, so retry a few times
task.spawn(function()
    for _ = 1, 30 do
        if not Running then break; end;
        if rayMouseModule == nil then rayMouseModule = findModuleByName("RayMouse"); end;
        installAimHook();
        if HookStatus.installed then break; end;
        task.wait(0.5);
    end;
    if not HookStatus.installed then
        warn("[VSH] silent aim unavailable (RayMouse module not found)");
    end;
end);


--================================================================
--  WEAPON MODS  (spread / recoil / bullet drop / instant hit)
--  A weapon is built by GameConfiguration.ItemConfigs[itemName](tool): every
--  entry is a BUILDER FUNCTION that returns a fresh stats table holding
--    ProjectileSpread, ProjectileGravity, ProjectileVelocity,
--    RecoilInfo = { NudgeX, NudgeY }, Firemodes ...
--  The fire client calls that builder once per equip, so a value must be changed
--  in the table it RETURNS - each builder is wrapped and its result is patched
--  while the matching toggle is on (nothing is written when a toggle is off).
--    * ProjectileVelocity == 0  -> the game takes its Hitscan path (instant hit)
--    * ProjectileGravity        -> the bullet drop
--    * RecoilInfo               -> what GunRecoil() nudges the camera with
--================================================================
local itemConfigs; -- the name -> builder map (required once)
local wrapped = {}; -- [builder] = true
-- the game builds a gun's stats ONCE PER EQUIP, so the built table is kept keyed
-- by tool in liveConfigs - it is the only place the real ProjectileVelocity is readable
local function patchStats(t, tool)
    if type(tool) == "Instance" then liveConfigs[tool] = t; end;
    if type(t) ~= "table" then return t; end;
    if getgenv().wh_no_spread and type(t.ProjectileSpread) == "number" then
        pcall(function() t.ProjectileSpread = 0; end);
    end;
    if getgenv().wh_no_bullet_drop and type(t.ProjectileGravity) == "number" then
        pcall(function() t.ProjectileGravity = 0; end);
    end;
    if getgenv().wh_instant_hit and type(t.ProjectileVelocity) == "number" then
        pcall(function() t.ProjectileVelocity = 0; end);
    end;
    if getgenv().wh_no_recoil and type(t.RecoilInfo) == "table" then
        pcall(function() t.RecoilInfo.NudgeX = NumberRange.new(0, 0); end);
        pcall(function() t.RecoilInfo.NudgeY = NumberRange.new(0, 0); end);
    end;
    -- BOTH firemode envs derive their interval from 60 / GunConfig.RPM, so
    -- scaling RPM here is what actually makes the gun fire faster
    if getgenv().wh_rapidfire and type(t.RPM) == "number" and t.RPM > 0 then
        local mult = math.max(getgenv().wh_rpm_mult or 1, 0.1);
        pcall(function() t.RPM = t.RPM * mult; end);
    end;
    return t;
end

local function wrapBuilder(fn)
    if type(fn) ~= "function" or wrapped[fn] then return false; end;
    wrapped[fn] = true;
    -- wrap whatever it returns; a builder returning a non-table is left alone
    return pcall(function()
        local orig = clonefunction(fn);
        hookfunction(fn, function(tool, ...)
            local r = orig(tool, ...);
            if type(r) == "table" then r = patchStats(r, tool); end;
            return r;
        end);
    end);
end

local function walkBuilders(t, depth)
    if type(t) ~= "table" or (depth or 0) > 2 then return 0; end;
    local n = 0;
    for _, v in next, t do
        if type(v) == "function" then
            if wrapBuilder(v) then n = n + 1; end;
        elseif type(v) == "table" then
            n = n + walkBuilders(v, depth + 1);
        end;
    end;
    return n;
end

local function installWeaponHooks()
    if itemConfigs == nil then
        -- GameConfiguration.ItemConfigs is the exact table the gun reads
        -- (GameConfiguration.ItemConfigs[attr](tool)), so prefer it over
        -- hunting for a module by name and hoping it is the same instance.
        pcall(function()
            local gc = require(findModuleByName("GameConfiguration"));
            if type(gc) == "table" and type(gc.ItemConfigs) == "table" then
                itemConfigs = gc.ItemConfigs;
            end;
        end);
        if itemConfigs == nil then
            local m = findModuleByName("ItemConfigs");
            if m then
                local ok, cfg = pcall(require, m);
                if ok and type(cfg) == "table" then itemConfigs = cfg; end;
            end;
        end;
    end;
    if type(itemConfigs) ~= "table" then return 0; end;
    return walkBuilders(itemConfigs, 0);
end

-- the config module can still be replicating in, so retry until it hooks
task.spawn(function()
    for _ = 1, 60 do
        if not Running then break; end;
        local n = installWeaponHooks();
        if n > 0 then
            HookStatus.noSpread = true;
            HookStatus.noRecoil = true;
            print(string.format("[VSH] weapon builders hooked (%d)", n));
            break;
        end;
        task.wait(0.5);
    end
    if not HookStatus.noSpread then
        warn("[VSH] could not find ItemConfigs (weapon mods are a safe no-op)");
    end
end);



--================================================================
--  WEAPON FIX
--  "The gun is in my hand but I can't fire it" is the client's tool state
--  getting stuck: FireOnce() returns early while State_Firing_Client (or
--  State_Aiming_Client) is left true, or the firemode environment that gates
--  firing was never rebuilt. Clearing the stuck flags fixes most cases; a
--  re-equip rebuilds the firemode environment and resets the internal guard.
--================================================================
local FIX_ATTRS = { "State_Firing_Client", "State_Aiming_Client", "State_Inspect" };

-- the equipped item is a Tool, or a Model tagged "Tool" (the game's own
-- ToolValidator accepts both); anything else is ignored
local function getEquippedTool()
    local char = plr.Character;
    if not char then return nil; end;
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("Tool") or (c:IsA("Model") and c:HasTag("Tool")) then return c; end;
    end;
    return nil;
end

local function clearStuckFlags(tool)
    if not tool then return false; end;
    local cleared = false;
    for _, a in ipairs(FIX_ATTRS) do
        if tool:GetAttribute(a) == true then
            pcall(function() tool:SetAttribute(a, false); end);
            cleared = true;
        end;
    end;
    return cleared;
end

-- NOTE: "State_Firemode" is owned by the server - nothing in the client ever sets
-- it - and it is the gate that decides whether the gun can fire at all. Writing to
-- it from a script desyncs the client from the server and can leave every weapon
-- unable to fire, so it is NEVER touched here. The repair below only clears stuck
-- client-side flags and, on request, re-equips the tool.

-- full repair: clear flags, then re-equip so the gun's equip path re-runs and
-- rebuilds the firemode env / firing guard
function fixWeapon(reason)
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local tool = getEquippedTool();
    if not tool then return false; end;
    clearStuckFlags(tool);
    if hum and tool:IsA("Tool") then
        pcall(function()
            hum:UnequipTools();
            task.wait(0.1);
            hum:EquipTool(tool);
        end);
    end;
    if getgenv().wh_debug_hook then
        print("[VSH] weapon fixed (" .. tostring(reason or "manual") .. ")");
    end;
    return true;
end

-- auto-repair: the firing flag is briefly true on every legit shot, so only a
-- flag that stays set across the whole window counts as stuck
local stuckTicks = 0;
task.spawn(function()
    while Running do
        task.wait(0.25);
        if getgenv().wh_auto_fix then
            local tool = getEquippedTool();
            if tool then
                -- the firing flag is true during a legit shot/burst, so only a flag left
                -- set while the trigger is RELEASED counts as stuck (never cut a burst)
                if tool:GetAttribute("State_Firing_Client") == true
                    and not UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
                    stuckTicks = stuckTicks + 1;
                    if stuckTicks >= 8 then -- ~2s stuck
                        stuckTicks = 0;
                        clearStuckFlags(tool);
                    end;
                else
                    stuckTicks = 0;
                end;
            else
                stuckTicks = 0;
            end;
        else
            stuckTicks = 0;
        end;
    end
end);

--================================================================
--  FULL AUTO  (hold-to-fire on Semi / Pump weapons)
--  The firemode environment is rebuilt per equip by
--  FiremodeEnvConstructors:WaitForChild(State_Firemode). The "Semi" env fires a
--  single round per FireInputStart, which is exactly why holding the button does
--  nothing. Those factories are wrapped so FireInputStart ALSO keeps calling the
--  game's own FireOnce while the trigger is held - the game's shot path is
--  reused, so ammo, reload and the fire remote all behave normally. "Auto" is
--  skipped because it already loops on Heartbeat.
--================================================================
local envWrapped = {}; -- [factory] = true

-- Every firemode env is also recorded per tool. Auto shoot drives the gun
-- through the game's own env (env.FireInputStart) instead of synthesising input,
-- so it uses the real shot path: ammo, reload and the CommunicateGun2 remote
-- all behave exactly as if you had clicked.
local envByTool = setmetatable({}, { __mode = "k" });
local envCaptured = {};

local function captureEnv(factory)
    if envCaptured[factory] then return; end;
    envCaptured[factory] = true;
    pcall(function()
        local origFactory = clonefunction(factory);
        hookfunction(factory, function(ctx, ...)
            local t = origFactory(ctx, ...);
            if type(t) == "table" and type(ctx) == "table" and ctx.Tool then
                envByTool[ctx.Tool] = t;
            end;
            return t;
        end);
    end);
end

local function wrapFiremodeEnv(factory)
    if envWrapped[factory] then return false; end;
    envWrapped[factory] = true;
    return pcall(function()
        local origFactory = clonefunction(factory);
        hookfunction(factory, function(ctx, fireOnce, anims)
            local t = origFactory(ctx, fireOnce, anims);
            if not (getgenv().wh_full_auto and type(t) == "table"
                    and type(fireOnce) == "function"
                    and type(t.FireInputStart) == "function") then
                return t;
            end;
            local tool = ctx and ctx.Tool;
            local rpm = (ctx and ctx.GunConfig and ctx.GunConfig.RPM) or 600;
            local interval = 60 / math.max(rpm, 1);
            local origStart = t.FireInputStart;
            t.FireInputStart = function(...)
                origStart(...);
                task.spawn(function()
                    while Running and getgenv().wh_full_auto do
                        task.wait(interval);
                        if not (Running and getgenv().wh_full_auto) then break; end;
                        if not UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then break; end;
                        if tool and tool:GetAttribute("State_Ammo_Client") == 0 then break; end;
                        pcall(fireOnce);
                    end;
                end);
            end;
            return t;
        end);
    end);
end

-- wrap the click-driven envs shipped inside this weapon
local function installFullAutoForTool(tool)
    if not tool then return 0; end;
    local folder = tool:FindFirstChild("FiremodeEnvConstructors", true);
    if not folder then return 0; end;
    local n = 0;
    for _, c in ipairs(folder:GetChildren()) do
        if c:IsA("ModuleScript") then
            local ok, factory = pcall(require, c);
            if ok and type(factory) == "function" then
                captureEnv(factory); -- every env, needed by autoshoot
                if c.Name ~= "Auto" then
                    if wrapFiremodeEnv(factory) then n = n + 1; end;
                end;
            end;
        end;
    end;
    return n;
end

local function watchForTools(char)
    if not char then return; end;
    local bp = plr:FindFirstChildOfClass("Backpack");
    if bp then
        bp.ChildAdded:Connect(function(t)
            task.defer(function() installFullAutoForTool(t); end);
        end);
    end;
    char.ChildAdded:Connect(function(t)
        task.defer(function() installFullAutoForTool(t); end);
    end);
    -- and whatever is already there
    task.spawn(function()
        for _ = 1, 8 do
            if not Running then return; end;
            installFullAutoForTool(getEquippedTool());
            if bp then
                for _, t in ipairs(bp:GetChildren()) do installFullAutoForTool(t); end;
            end;
            task.wait(1);
        end;
    end);
end

table.insert(Connections, plr.CharacterAdded:Connect(watchForTools));
watchForTools(plr.Character);
--================================================================
--  AUTO SHOOT
--  Instead of synthesising a mouse click (virtual input is not available on the
--  client anyway), this calls the equipped gun's own firemode env. Each env's
--  FireInputStart already rate-limits against 60 / RPM, so calling it once a
--  frame fires as fast as that gun allows - through the real shot path.
--================================================================
local autoshootActive = false;

local function applyAutoshoot()
    local tool = getEquippedTool();
    local env = tool and envByTool[tool];
    if not env then return; end;
    if not getgenv().wh_autoshoot then
        if autoshootActive then
            autoshootActive = false;
            if type(env.FireInputEnd) == "function" then pcall(function() env.FireInputEnd(); end); end;
        end;
        return;
    end;
    if type(env.FireInputStart) ~= "function" then return; end;
    -- nothing locked: release the trigger so a burst does not keep running
    if not last.part then
        if autoshootActive and type(env.FireInputEnd) == "function" then
            autoshootActive = false;
            pcall(function() env.FireInputEnd(); end);
        end;
        return;
    end;
    autoshootActive = true;
    pcall(function() env.FireInputStart(); end);
end

--================================================================
--  CAMERA / MOVEMENT / FAKE ROTATION / HORSES
--================================================================
--================================================================
--  CAMERA / MOVEMENT / FAKE ROTATION / HORSES
--================================================================

-- CUSTOM FOV: FovController tweens camera.FieldOfView only when a modifier is
-- added/removed, so re-asserting our value every frame simply wins.
local DEFAULT_FOV = 70;
local function applyFov()
    if cam and getgenv().wh_fov_custom then
        pcall(function() cam.FieldOfView = getgenv().wh_fov or DEFAULT_FOV; end);
    end;
end

-- SPEED BOOST (CFrame): WalkSpeed is left alone; while a movement key is held the
-- RootPart is translated an extra (speed * dt) along the current move direction.
local function applySpeedBoost(dt)
    if not getgenv().wh_speed_on then return; end;
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if not (hum and hrp) then return; end;
    local dir = hum.MoveDirection;
    if dir.Magnitude < 0.05 then return; end; -- only while actually moving
    local extra = (getgenv().wh_speed or 45) * (dt or 0);
    pcall(function() hrp.CFrame = hrp.CFrame + dir * extra; end);
end

-- FLY (CFrame): WASD plus Space / LeftControl move the RootPart directly.
-- WalkSpeed is never touched; Humanoid.Sit is cleared so the game cannot drop us
-- into a seated state mid-flight.
local function applyFly(dt)
    if not getgenv().wh_fly then return; end;
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if not (hum and hrp) then return; end;
    hum.Sit = false;
    local dir = hum.MoveDirection; -- already world space / camera relative
    if dir.Magnitude < 0.05 then dir = Vector3.zero; end;
    if UIS:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0, 1, 0); end;
    if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir + Vector3.new(0, -1, 0); end;
    if dir.Magnitude < 0.001 then return; end;
    local step = (getgenv().wh_fly_speed or 80) * (dt or 0);
    pcall(function() hrp.CFrame = hrp.CFrame + dir.Unit * step; end);
end

-- FAKE ROTATION: rebuilds the character's facing from the camera yaw plus an
-- offset every frame, so other players see the body turned (e.g. facing backwards
-- or lying down) while the local camera and aim are untouched. AutoRotate is
-- suspended while it is on so physics do not fight the override.
-- Modes: "Custom" uses the sliders, "Spin" turns yaw continuously,
-- "Random" re-rolls pitch/yaw/roll on an interval.
local fakeSpinAngle = 0;
local fakeNextRandom = 0;
local fakeRand = { p = 0, y = 0, r = 0 };

local function fakeAngles(dt)
    local mode = getgenv().wh_fake_mode or "Custom";
    if mode == "Spin" then
        local step = (getgenv().wh_fake_spin_speed or 360) * (dt or 0);
        fakeSpinAngle = (fakeSpinAngle + step) % 360;
        return 0, fakeSpinAngle, 0;
    end;
    if mode == "Random" then
        local now = os.clock();
        if now >= fakeNextRandom then
            fakeNextRandom = now + math.max(getgenv().wh_fake_rand_int or 0.4, 0.05);
            fakeRand.p = math.random(-180, 180);
            fakeRand.y = math.random(-180, 180);
            fakeRand.r = math.random(-180, 180);
        end;
        return fakeRand.p, fakeRand.y, fakeRand.r;
    end;
    return getgenv().wh_fake_pitch or 0, getgenv().wh_fake_yaw or 0, getgenv().wh_fake_roll or 0;
end

local function applyFakeRotation(dt)
    if not getgenv().wh_fake_rot then return; end;
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if not (hum and hrp) then return; end;
    hum.AutoRotate = false;
    local pos = hrp.CFrame.Position;
    -- base facing: normally where the camera looks, but "target based" aims the
    -- body at whatever silent aim is locked onto. Combine that with a yaw of 180
    -- and you are visibly turned AWAY from the enemy you are shooting at.
    local flat;
    if getgenv().wh_fake_target_based and last.part then
        local to = last.part.Position - pos;
        flat = Vector3.new(to.X, 0, to.Z);
    else
        local look = cam.CFrame.LookVector;
        flat = Vector3.new(look.X, 0, look.Z);
    end;
    if flat.Magnitude < 0.001 then return; end;
    local fp, fy, fr = fakeAngles(dt);
    local base = CFrame.lookAt(pos, pos + flat.Unit);
    local off = CFrame.Angles(math.rad(fp), math.rad(fy), math.rad(fr));
    pcall(function() hrp.CFrame = base * off; end);
end
local function restoreAutoRotate()
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    if hum then pcall(function() hum.AutoRotate = true; end); end;
end

--================================================================
--  LIGHTING
--  Every property remembers the game's own value on first change, and each
--  toggle writes only when its value actually changes, so switching everything
--  off puts the scene back exactly as it was.
--================================================================
local Lighting = cloneref(game:GetService("Lighting"));
local lightOriginals = {}; -- [property] = the game's own value, captured once
local touched = {};        -- [property] = true once we have overridden it

-- Compare against the property's CURRENT value rather than a cached one: the
-- game's weather module rewrites ClockTime (and may rewrite the rest), so a
-- cached "already applied" check lets the game win permanently.
local function setLight(key, value)
    if not touched[key] then
        touched[key] = true;
        pcall(function() lightOriginals[key] = Lighting[key]; end);
    end;
    pcall(function()
        if Lighting[key] ~= value then Lighting[key] = value; end;
    end);
end
local function restoreLight(key)
    if not touched[key] then return; end;
    local v = lightOriginals[key];
    if v == nil then return; end;
    pcall(function()
        if Lighting[key] ~= v then Lighting[key] = v; end;
    end);
end
local function resetLighting()
    for k in next, touched do
        local v = lightOriginals[k];
        if v ~= nil then pcall(function() Lighting[k] = v; end); end;
    end;
    table.clear(lightOriginals);
    table.clear(touched);
end

local atmoDensity; -- original Atmosphere density
local function applyLighting()
    if getgenv().wh_amb then setLight("Ambient", getgenv().wh_amb_color); else restoreLight("Ambient"); end;
    if getgenv().wh_outamb then setLight("OutdoorAmbient", getgenv().wh_outamb_color); else restoreLight("OutdoorAmbient"); end;
    if getgenv().wh_bright then setLight("Brightness", getgenv().wh_bright_val or 2); else restoreLight("Brightness"); end;
    if getgenv().wh_time_on then setLight("ClockTime", getgenv().wh_time or 12); else restoreLight("ClockTime"); end;

    local atmo = Lighting:FindFirstChildOfClass("Atmosphere");
    if getgenv().wh_nofog then
        setLight("FogStart", 0);
        setLight("FogEnd", 100000);
        if atmo then
            if atmoDensity == nil then pcall(function() atmoDensity = atmo.Density; end); end;
            pcall(function() atmo.Density = 0; end);
        end;
    else
        restoreLight("FogStart");
        restoreLight("FogEnd");
        if atmo and atmoDensity ~= nil then
            pcall(function() atmo.Density = atmoDensity; end);
            atmoDensity = nil; -- re-capture cleanly next time it is enabled
        end;
    end;
end
-- HORSES: identified through CollectionService tags, so no map scan is needed.
local CollectionService = cloneref(game:GetService("CollectionService"));
local HORSE_TAGS = { "Horse", "HorseV8", "Unicorn" };
local function horseModels()
    local out = {};
    for _, tag in ipairs(HORSE_TAGS) do
        local ok, list = pcall(CollectionService.GetTagged, CollectionService, tag);
        if ok and type(list) == "table" then
            for _, inst in ipairs(list) do
                local m = inst:IsA("Model") and inst or inst:FindFirstAncestorOfClass("Model");
                if m and m.Parent then out[m] = true; end;
            end;
        end;
    end;
    return out;
end
local function isRiding()
    return plr:HasTag("OnHorse") or plr:HasTag("OnV8Horse");
end

-- RIDE & SHOOT: Roblox unequips (and blocks re-equipping) tools while the
-- Humanoid is Seated, which is why the gun vanishes on a horse. Re-parenting a
-- gun straight onto the character sidesteps the seat check so it stays usable.
task.spawn(function()
    while Running do
        task.wait(0.3);
        if getgenv().wh_shoot_riding and isRiding() then
            local char = plr.Character;
            local hum = char and char:FindFirstChildOfClass("Humanoid");
            if char and hum and hum.Seated then
                local bp = plr:FindFirstChildOfClass("Backpack");
                if bp then
                    for _, t in ipairs(bp:GetChildren()) do
                        if t:IsA("Tool") then
                            pcall(function() t.Parent = char; end);
                            break;
                        end;
                    end;
                end;
            end;
        end;
    end
end);
--================================================================
--  FALL DAMAGE
--  MovementSettings.FallHeight (85 studs) is what triggers the landing effects
--  (fall sound + ragdoll), and a hard landing is really "vertical speed got
--  big". Raising the threshold removes the effects, and capping downward
--  velocity means a landing is never hard in the first place.
--================================================================
task.spawn(function()
    for _ = 1, 20 do
        if not Running then break; end;
        local ok = pcall(function()
            local cfg = require(findModuleByName("GameConfiguration"));
            if type(cfg) == "table" and type(cfg.MovementSettings) == "table" then
                cfg.MovementSettings.FallHeight = 1e9;
            end;
        end);
        if ok then break; end;
        task.wait(0.5);
    end;
end)

local function applyNoFallDamage()
    if not getgenv().wh_no_fall then return; end;
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if not (hum and hrp) then return; end;
    local v = hrp.AssemblyLinearVelocity;
    local limit = -(getgenv().wh_fall_speed or 60);
    if v.Y < limit then -- falling faster than allowed: bleed the speed off
        pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(v.X, limit, v.Z); end);
    end;
end



--================================================================
--  ESP  (Drawing)
--  A 2D box built from the projected limbs, a health bar and text labels.
--  Objects are pooled per character and reused, so a steady scene allocates
--  nothing per frame.
--================================================================
local ESP_PARTS = {
    "Head", "UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart",
    "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
    "LeftUpperLeg", "RightUpperLeg", "LeftFoot", "RightFoot",
};
local espPool = {}; -- [model] = { lines[4], name, dist, hpBg, hp }

local function espColorFor(model)
    local owner = Players:GetPlayerFromCharacter(model);
    if owner then
        local ok, c = pcall(function() return owner.TeamColor.Color; end);
        if ok and c then return c; end;
    end;
    return getgenv().wh_esp_box_color;
end

local function newEsp()
    local o = { lines = {} };
    for i = 1, 4 do
        o.lines[i] = createObj("Line", { Thickness = 1, Visible = false, ZIndex = 2 });
    end;
    o.name = createObj("Text", { Size = 13, Center = true, Outline = true,
        OutlineColor = Color3.new(0, 0, 0), Visible = false, ZIndex = 3 });
    o.dist = createObj("Text", { Size = 12, Center = true, Outline = true,
        OutlineColor = Color3.new(0, 0, 0), Visible = false, ZIndex = 3 });
    o.hpBg = createObj("Line", { Thickness = 3, Visible = false, ZIndex = 2 });
    o.hp   = createObj("Line", { Thickness = 3, Visible = false, ZIndex = 3 });
    return o;
end

local function freeEsp(o)
    for _, l in ipairs(o.lines) do if l then pcall(function() l:Remove(); end); end; end;
    for _, k in ipairs({ "name", "dist", "hpBg", "hp" }) do
        if o[k] then pcall(function() o[k]:Remove(); end); end;
    end;
end

local function hideEsp(o)
    for _, l in ipairs(o.lines) do if l then l.Visible = false; end; end;
    for _, k in ipairs({ "name", "dist", "hpBg", "hp" }) do
        if o[k] then o[k].Visible = false; end;
    end;
end

local function drawEsp(model)
    local o = espPool[model];
    if not o then o = newEsp(); espPool[model] = o; end;

    -- project every limb and take the screen-space extremes as the box
    local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge;
    local any = false;
    for _, nm in ipairs(ESP_PARTS) do
        local p = model:FindFirstChild(nm);
        if p and p:IsA("BasePart") then
            local sp = cam:WorldToViewportPoint(p.Position);
            if isFinite(sp.X) and isFinite(sp.Y) and sp.Z > 0 then
                any = true;
                lx = math.min(lx, sp.X); hx = math.max(hx, sp.X);
                ly = math.min(ly, sp.Y); hy = math.max(hy, sp.Y);
            end
        end
    end
    if not any then hideEsp(o); return; end;

    local view = cam.ViewportSize;
    if hx < -view.X or lx > view.X * 2 or hy < -view.Y or ly > view.Y * 2 then
        hideEsp(o); return;
    end;

    local col = espColorFor(model);
    local corners = {
        Vector2.new(lx, ly), Vector2.new(hx, ly), Vector2.new(hx, hy), Vector2.new(lx, hy),
    };
    for i = 1, 4 do
        local ln = o.lines[i];
        if ln then
            if getgenv().wh_esp_boxes then
                ln.From = corners[i];
                ln.To = corners[(i % 4) + 1];
                ln.Color = col;
                ln.Visible = true;
            else
                ln.Visible = false;
            end;
        end;
    end

    local cx = (lx + hx) / 2;
    if o.name then
        if getgenv().wh_esp_names then
            local owner = Players:GetPlayerFromCharacter(model);
            o.name.Text = owner and owner.DisplayName or model.Name;
            o.name.Position = Vector2.new(cx, ly - 16);
            o.name.Color = getgenv().wh_esp_name_color;
            o.name.Visible = true;
        else
            o.name.Visible = false;
        end;
    end

    local hum = model:FindFirstChildOfClass("Humanoid");
    if o.dist then
        if getgenv().wh_esp_distance then
            local pos = (hum and hum.RootPart and hum.RootPart.Position) or model:GetPivot().Position;
            local d = (pos - cam.CFrame.Position).Magnitude / STUDS_PER_METER;
            o.dist.Text = string.format("%d m", math.floor(d + 0.5));
            o.dist.Position = Vector2.new(cx, hy + 2);
            o.dist.Color = getgenv().wh_esp_name_color;
            o.dist.Visible = true;
        else
            o.dist.Visible = false;
        end;
    end

    if o.hp and o.hpBg then
        if getgenv().wh_esp_health and hum then
            local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1);
            o.hpBg.From = Vector2.new(lx - 6, ly);
            o.hpBg.To   = Vector2.new(lx - 6, hy);
            o.hpBg.Color = Color3.new(0, 0, 0);
            o.hpBg.Visible = true;
            o.hp.From = Vector2.new(lx - 6, hy - (hy - ly) * frac);
            o.hp.To   = Vector2.new(lx - 6, hy);
            o.hp.Color = getgenv().wh_esp_hp_color;
            o.hp.Visible = true;
        else
            o.hpBg.Visible = false;
            o.hp.Visible = false;
        end;
    end
end


local function updateEsp()
    if not hasDrawing then return; end;
    if not getgenv().wh_esp then
        for _, o in next, espPool do hideEsp(o); end;
        return;
    end;
    local origin = cam.CFrame.Position;
    local maxStuds = (getgenv().wh_esp_max_dist or 0) * STUDS_PER_METER;
    local seen = {};

    local function consider(model)
        if model == plr.Character then return; end;
        local hum = model:FindFirstChildOfClass("Humanoid");
        if not hum then return; end;
        local root = hum.RootPart or model.PrimaryPart;
        if not root then return; end;
        if maxStuds > 0 and (root.Position - origin).Magnitude > maxStuds then return; end;
        seen[model] = true;
        drawEsp(model);
    end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= plr and p.Character then consider(p.Character); end;
    end;
    if getgenv().wh_esp_npcs then
        for model in next, npcCache do
            if typeof(model) == "Instance" and model.Parent then consider(model); end;
        end;
    end;
    if getgenv().wh_esp_horses then
        for m in next, horseModels() do
            if maxStuds == 0 or (m:GetPivot().Position - origin).Magnitude <= maxStuds then
                seen[m] = true;
                drawEsp(m);
            end;
        end;
    end;

    -- release pools for models that left the scene or dropped out of range
    for model, o in next, espPool do
        if not seen[model] or typeof(model) ~= "Instance" or not model.Parent then
            freeEsp(o);
            espPool[model] = nil;
        end;
    end;
end


--================================================================
--  AIM HUD (Drawing)
--================================================================
local fovCircle = hasDrawing and createObj("Circle", {
    Thickness = 1, NumSides = 64, Radius = getgenv().wh_fov_size,
    Filled = false, Visible = false,
}) or nil;

local tracer = hasDrawing and createObj("Line", { Thickness = 1.5, Visible = false }) or nil;

local function updateHud(targetPart)
    if not hasDrawing then return; end;
    local center = centerPoint();
    if fovCircle then
        fovCircle.Position = center;
        fovCircle.Radius = getgenv().wh_fov_size or 150;
        fovCircle.Color = getgenv().wh_fov_color;
        fovCircle.Visible = (getgenv().wh_fov_toggle and getgenv().wh_silent_aim) or false;
    end
    if tracer then
        if getgenv().wh_tracers and getgenv().wh_silent_aim and targetPart then
            local scr = toScreen(cam:WorldToViewportPoint(targetPart.Position));
            local view = cam.ViewportSize;
            local span = (scr - center).Magnitude;
            local maxSpan = (view.X + view.Y) * 1.5;
            -- a target on the crosshair is a zero-length line (fine); a projection
            -- through the wrong fov produces a line longer than the screen could
            -- explain, which must never be drawn
            if isFiniteVec2(scr) and scr.X > -view.X and scr.X < view.X * 2
                and scr.Y > -view.Y and scr.Y < view.Y * 2 and span < maxSpan then
                tracer.From = center;
                tracer.To = scr;
                tracer.Color = getgenv().wh_tracer_color;
                tracer.Visible = true;
                return;
            end
        end;
        tracer.Visible = false;
    end;
end


--================================================================
--  LINORIA UI (resilient loader)
--  raw.githubusercontent.com regularly times out, which shows up as
--  "HTTP exception while yielding". So try a fast CDN first, then the other
--  mirrors, then the executor's request() API, and abort cleanly if all fail.
--================================================================
local httpRequest = (syn and syn.request) or (http and http.request) or http_request or request;

local function fetchSource(url)
    local ok, body = pcall(function() return game:HttpGet(url); end);
    if ok and type(body) == "string" and #body > 2 then return body; end;

    ok, body = pcall(function() return game:HttpGet(url, true); end);
    if ok and type(body) == "string" and #body > 2 then return body; end;

    if httpRequest then
        local ok2, res = pcall(httpRequest, { Url = url, Method = "GET" });
        if ok2 and type(res) == "table" and type(res.Body) == "string" and #res.Body > 2 then
            return res.Body;
        end;
    end;
    return nil;
end

local LIB_MIRRORS = {
    "https://cdn.jsdelivr.net/gh/violin-suzutsuki/LinoriaLib@main/",
    "https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/",
    "https://raw.githack.com/violin-suzutsuki/LinoriaLib/main/",
};

local function loadRemote(relative)
    local lastErr = "no response";
    -- mirrors are ordered: the jsdelivr CDN is tried before raw.githubusercontent
    for _, base in ipairs(LIB_MIRRORS) do
        local ok, src = pcall(fetchSource, base .. relative);
        if ok and src then
            local chunk, err = loadstring(src, relative);
            if chunk then
                local ran, mod = pcall(chunk);
                if ran and mod ~= nil then return mod; end;
                lastErr = tostring(mod);
            else
                lastErr = tostring(err);
            end;
        else
            task.wait(0.1);
        end;
    end;
    warn("Could not load " .. relative .. " (" .. tostring(lastErr) .. ")");
    return nil;
end

local Library = loadRemote("Library.lua");
if not Library then
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "VSH",
            Text = "Failed to download LinoriaLib from every mirror. Check your connection / executor HTTP.",
            Duration = 8,
        });
    end);
    return warn("Aborted: UI library unavailable.");
end

local ThemeManager = loadRemote("addons/ThemeManager.lua");
local SaveManager = loadRemote("addons/SaveManager.lua");


-- colour pickers / key pickers are not in every Linoria build; every call goes
-- through a helper so a missing method never aborts the whole script (the
-- setting simply falls back to a preset dropdown or no control at all).
local PRESET_COLORS = {
    White = Color3.fromRGB(255, 255, 255), Grey = Color3.fromRGB(200, 200, 200),
    Black = Color3.fromRGB(20, 20, 20), Red = Color3.fromRGB(255, 70, 70),
    Orange = Color3.fromRGB(255, 150, 40), Yellow = Color3.fromRGB(240, 230, 60),
    Green = Color3.fromRGB(60, 255, 90), Cyan = Color3.fromRGB(60, 220, 255),
    Blue = Color3.fromRGB(70, 130, 255), Purple = Color3.fromRGB(150, 0, 255),
    Pink = Color3.fromRGB(255, 90, 190), Brown = Color3.fromRGB(140, 90, 50),
};
local PRESET_NAMES = { "White", "Grey", "Black", "Red", "Orange", "Yellow",
    "Green", "Cyan", "Blue", "Purple", "Pink", "Brown" };

local function closestPreset(color)
    local best, bestDist = "White", math.huge;
    for _, nm in next, PRESET_NAMES do
        local c = PRESET_COLORS[nm];
        local d = (c.R - color.R) ^ 2 + (c.G - color.G) ^ 2 + (c.B - color.B) ^ 2;
        if d < bestDist then best, bestDist = nm, d; end;
    end;
    return best;
end

local function addColorPicker(owner, id, options)
    if not owner then return nil; end;
    if owner.AddColorPicker then
        local ok, w = pcall(owner.AddColorPicker, owner, id, options);
        if ok and w then return w; end;
    end;
    if owner.AddDropdown then
        local wanted = options and options.Default;
        local ok, w = pcall(owner.AddDropdown, owner, id, {
            Text = (options and (options.Title or options.Text)) or "Color",
            Values = PRESET_NAMES,
            Default = (type(wanted) == "table" and closestPreset(wanted)) or "White",
            AllowNull = false,
            Tooltip = "This build has no colour picker, so these are the available colours",
            Callback = function(v)
                local picked = PRESET_COLORS[v];
                if picked and options and options.Callback then options.Callback(picked); end;
            end,
        });
        if ok then return w; end;
    end;
    return nil;
end

local function addKeyPicker(owner, id, options)
    if not owner then return nil; end;
    for _, method in ipairs({ "AddKeyPicker", "AddKeyBind" }) do
        local fn = owner[method];
        if fn then
            local ok, w = pcall(fn, owner, id, options);
            if ok and w then return w; end;
        end;
    end;
    return nil;
end

local Window = Library:CreateWindow({
    Title = "aimwhere | vagrant survival",
    Center = true,
    AutoShow = true,
    TabPadding = 8,
    MenuFadeTime = 0.2,
});

local Tabs = {
    Aim = Window:AddTab("Aim"),
    Esp = Window:AddTab("ESP"),
    Gun = Window:AddTab("Gun"),
    Move = Window:AddTab("Movement"),
    Render = Window:AddTab("Render"),
    Config = Window:AddTab("Config"),
};


--================================================================
--  TAB: AIM
--================================================================
local SA = Tabs.Aim:AddLeftGroupbox("Silent Aim");

SA:AddToggle("VSH_SilentAim", {
    Text = "Silent Aim",
    Default = getgenv().wh_silent_aim,
    Tooltip = "Redirects your shot onto the target inside the circle without moving the view",
    Callback = function(v) getgenv().wh_silent_aim = v; end,
});

SA:AddDropdown("VSH_AimPart", {
    Text = "Aim Body Part",
    Values = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg", "Auto" },
    Default = getgenv().wh_aim_part,
    AllowNull = false,
    Callback = function(v) getgenv().wh_aim_part = v; end,
});

SA:AddSlider("VSH_FovSize", {
    Text = "FOV",
    Default = getgenv().wh_fov_size,
    Min = 20,
    Max = 600,
    Rounding = 0,
    Suffix = "px",
    Callback = function(v) getgenv().wh_fov_size = v; end,
});

SA:AddSlider("VSH_MaxDistance", {
    Text = "Max Distance",
    Default = getgenv().wh_max_distance,
    Min = 0,
    Max = 1000,
    Rounding = 0,
    Suffix = "m",
    Tooltip = "0 = unlimited",
    Callback = function(v) getgenv().wh_max_distance = v; end,
});

SA:AddToggle("VSH_WallCheck", {
    Text = "Wall Check",
    Default = getgenv().wh_wallcheck,
    Tooltip = "Only lock parts a raycast can actually reach",
    Callback = function(v) getgenv().wh_wallcheck = v; end,
});

local AimUnseenToggle = SA:AddToggle("VSH_AimUnseen", {
    Text = "Fire When Unseen",
    Default = getgenv().wh_aim_unseen,
    Tooltip = "With Wall Check on, still fire at the locked target when nothing is visible",
    Callback = function(v) getgenv().wh_aim_unseen = v; end,
});

SA:AddToggle("VSH_Prediction", {
    Text = "Lead Target",
    Default = getgenv().wh_prediction,
    Tooltip = "Aims ahead of a moving target using the gun's real projectile speed (auto-off for hitscan)",
    Callback = function(v) getgenv().wh_prediction = v; end,
});

SA:AddSlider("VSH_Lead", {
    Text = "Lead Amount",
    Default = getgenv().wh_lead,
    Min = 0,
    Max = 2,
    Rounding = 2,
    Suffix = "x",
    Tooltip = "1 = mathematically exact, higher over-leads",
    Callback = function(v) getgenv().wh_lead = v; end,
});

SA:AddToggle("VSH_Ragebot", {
    Text = "Ragebot (No FOV Limit)",
    Default = getgenv().wh_ragebot,
    Tooltip = "Locks any character on screen, ignoring the FOV circle and the distance cap",
    Callback = function(v) getgenv().wh_ragebot = v; end;
});

SA:AddToggle("VSH_AutoShoot", {
    Text = "Auto Shoot",
    Default = getgenv().wh_autoshoot,
    Tooltip = "Fires on the locked target through the gun's own fire mode (no mouse needed)",
    Callback = function(v) getgenv().wh_autoshoot = v; end;
});

SA:AddToggle("VSH_TargetNpcs", {
    Text = "Target NPCs",
    Default = getgenv().wh_target_npcs,
    Tooltip = "Also aim at Humanoid models that are not players",
    Callback = function(v) getgenv().wh_target_npcs = v; end,
});

SA:AddToggle("VSH_IgnoreFriends", {
    Text = "Ignore Friends",
    Default = getgenv().wh_ignore_friends,
    Callback = function(v) getgenv().wh_ignore_friends = v; end,
});


local VIS = Tabs.Aim:AddRightGroupbox("Visuals");

VIS:AddToggle("VSH_FovToggle", {
    Text = "FOV Circle",
    Default = getgenv().wh_fov_toggle,
    Callback = function(v) getgenv().wh_fov_toggle = v; end,
});

VIS:AddToggle("VSH_FovCenter", {
    Text = "Circle On Screen Center",
    Default = getgenv().wh_fov_center,
    Tooltip = "Off = the circle follows the cursor instead",
    Callback = function(v) getgenv().wh_fov_center = v; end,
});

addColorPicker(VIS, "VSH_FovColor", {
    Title = "FOV Color",
    Default = getgenv().wh_fov_color,
    Callback = function(c) getgenv().wh_fov_color = c; end,
});

VIS:AddToggle("VSH_Tracers", {
    Text = "Target Tracer",
    Default = getgenv().wh_tracers,
    Callback = function(v) getgenv().wh_tracers = v; end,
});

addColorPicker(VIS, "VSH_TracerColor", {
    Title = "Tracer Color",
    Default = getgenv().wh_tracer_color,
    Callback = function(c) getgenv().wh_tracer_color = c; end,
});

VIS:AddToggle("VSH_DebugHook", {
    Text = "Debug Hook (print)",
    Default = getgenv().wh_debug_hook,
    Callback = function(v) getgenv().wh_debug_hook = v; end,
});

--================================================================
--  TAB: GUN
--================================================================
local GUN = Tabs.Gun:AddLeftGroupbox("Weapon");

GUN:AddToggle("VSH_NoSpread", {
    Text = "No Spread",
    Default = getgenv().wh_no_spread,
    Tooltip = "Zeroes ProjectileSpread so every pellet lands dead centre",
    Callback = function(v)
        getgenv().wh_no_spread = v;
        installWeaponHooks();
    end,
});

GUN:AddToggle("VSH_NoRecoil", {
    Text = "No Recoil",
    Default = getgenv().wh_no_recoil,
    Tooltip = "Zeroes the camera nudge (NudgeX / NudgeY) applied on every shot",
    Callback = function(v)
        getgenv().wh_no_recoil = v;
        installWeaponHooks();
    end,
});

GUN:AddToggle("VSH_NoDrop", {
    Text = "No Bullet Drop",
    Default = getgenv().wh_no_bullet_drop,
    Tooltip = "Zeroes ProjectileGravity so shots stay on the line",
    Callback = function(v) getgenv().wh_no_bullet_drop = v; end,
});

GUN:AddToggle("VSH_InstantHit", {
    Text = "Instant Hit",
    Default = getgenv().wh_instant_hit,
    Tooltip = "ProjectileVelocity = 0 makes the gun take the game's Hitscan path",
    Callback = function(v) getgenv().wh_instant_hit = v; end,
});

GUN:AddToggle("VSH_RapidFire", {
    Text = "Rapid Fire",
    Default = getgenv().wh_rapidfire,
    Tooltip = "Multiplies the gun's RPM (both fire modes use 60 / RPM as the interval)",
    Callback = function(v) getgenv().wh_rapidfire = v; end,
});

GUN:AddSlider("VSH_RpmMult", {
    Text = "RPM Multiplier",
    Default = getgenv().wh_rpm_mult,
    Min = 1,
    Max = 5,
    Rounding = 2,
    Suffix = "x",
    Callback = function(v) getgenv().wh_rpm_mult = v; end,
});

GUN:AddToggle("VSH_FullAuto", {
    Text = "Full Auto (all guns)",
    Default = getgenv().wh_full_auto,
    Tooltip = "Makes Semi/Pump guns keep firing while the mouse is held",
    Callback = function(v) getgenv().wh_full_auto = v; end,
});


GUN:AddLabel("Mods are patched into the weapon config builder on equip.");

local FIXBOX = Tabs.Gun:AddRightGroupbox("Weapon Fix");

FIXBOX:AddToggle("VSH_AutoFix", {
    Text = "Auto Fix Weapon",
    Default = getgenv().wh_auto_fix,
    Tooltip = "Clears a stuck firing flag automatically (gun in hand but won't fire)",
    Callback = function(v) getgenv().wh_auto_fix = v; end,
});

FIXBOX:AddButton("Fix Weapon Now", function()
    fixWeapon("button");
end);

FIXBOX:AddLabel("Re-equips the held gun to rebuild its fire state.");

local INFO = Tabs.Gun:AddRightGroupbox("Status");
local gunStatusLabel = INFO:AddLabel("waiting for weapon configs...");

--================================================================
--  TAB: ESP
--================================================================
local ESPG = Tabs.Esp:AddLeftGroupbox("Players");

ESPG:AddToggle("VSH_Esp", {
    Text = "ESP",
    Default = getgenv().wh_esp,
    Callback = function(v) getgenv().wh_esp = v; end,
});

ESPG:AddToggle("VSH_EspBoxes", {
    Text = "Boxes",
    Default = getgenv().wh_esp_boxes,
    Callback = function(v) getgenv().wh_esp_boxes = v; end,
});

ESPG:AddToggle("VSH_EspNames", {
    Text = "Names",
    Default = getgenv().wh_esp_names,
    Callback = function(v) getgenv().wh_esp_names = v; end,
});

ESPG:AddToggle("VSH_EspDist", {
    Text = "Distance",
    Default = getgenv().wh_esp_distance,
    Callback = function(v) getgenv().wh_esp_distance = v; end,
});

ESPG:AddToggle("VSH_EspHp", {
    Text = "Health Bar",
    Default = getgenv().wh_esp_health,
    Callback = function(v) getgenv().wh_esp_health = v; end,
});

ESPG:AddToggle("VSH_EspNpcs", {
    Text = "Include NPCs",
    Default = getgenv().wh_esp_npcs,
    Callback = function(v) getgenv().wh_esp_npcs = v; end,
});

ESPG:AddToggle("VSH_EspHorses", {
    Text = "Horses",
    Default = getgenv().wh_esp_horses,
    Tooltip = "Show horses / unicorns (CollectionService tags)",
    Callback = function(v) getgenv().wh_esp_horses = v; end,
});

ESPG:AddSlider("VSH_EspRange", {
    Text = "Max Distance",
    Default = getgenv().wh_esp_max_dist,
    Min = 0,
    Max = 2000,
    Rounding = 0,
    Suffix = "m",
    Tooltip = "0 = unlimited",
    Callback = function(v) getgenv().wh_esp_max_dist = v; end,
});

local ESPV = Tabs.Esp:AddRightGroupbox("Colors");
addColorPicker(ESPV, "VSH_EspBoxColor", {
    Title = "Box Color",
    Default = getgenv().wh_esp_box_color,
    Callback = function(c) getgenv().wh_esp_box_color = c; end,
});
addColorPicker(ESPV, "VSH_EspNameColor", {
    Title = "Text Color",
    Default = getgenv().wh_esp_name_color,
    Callback = function(c) getgenv().wh_esp_name_color = c; end,
});
addColorPicker(ESPV, "VSH_EspHpColor", {
    Title = "Health Color",
    Default = getgenv().wh_esp_hp_color,
    Callback = function(c) getgenv().wh_esp_hp_color = c; end,
});


--================================================================
--  TAB: MOVEMENT
--================================================================
local MOVE = Tabs.Move:AddLeftGroupbox("Speed Boost");

MOVE:AddToggle("VSH_Speed", {
    Text = "CFrame Speed Boost",
    Default = getgenv().wh_speed_on,
    Tooltip = "Moves you with CFrame instead of WalkSpeed (does not touch WalkSpeed)",
    Callback = function(v) getgenv().wh_speed_on = v; end,
});

MOVE:AddSlider("VSH_SpeedAmount", {
    Text = "Boost Speed",
    Default = getgenv().wh_speed,
    Min = 0,
    Max = 200,
    Rounding = 0,
    Suffix = " st/s",
    Callback = function(v) getgenv().wh_speed = v; end,
});

MOVE:AddLabel("Extra distance per second while you hold a movement key.");
local FLY = Tabs.Move:AddLeftGroupbox("Fly");

local flyToggle = FLY:AddToggle("VSH_Fly", {
    Text = "Fly (CFrame)",
    Default = getgenv().wh_fly,
    Tooltip = "WASD to move, Space up, LeftControl down. WalkSpeed untouched.",
    Callback = function(v) getgenv().wh_fly = v; end,
});

FLY:AddSlider("VSH_FlySpeed", {
    Text = "Fly Speed",
    Default = getgenv().wh_fly_speed,
    Min = 10,
    Max = 400,
    Rounding = 0,
    Suffix = " st/s",
    Callback = function(v) getgenv().wh_fly_speed = v; end,
});

-- Linoria keybind, attached to the TOGGLE (not the groupbox): SyncToggleState
-- makes the key and the toggle share one state - pressing the key flips the
-- toggle, flipping the toggle clears the key - and the key is listed in the
-- library's own keybinds panel. This is the pattern from Linoria's docs:
--   groupbox:AddToggle("id", {...}):AddKeyPicker("id_Key", { SyncToggleState = true })
local flyKeyPicker = addKeyPicker(flyToggle, "VSH_FlyKey", {
    Default = getgenv().wh_fly_key,
    Text = "Fly Toggle Key",
    SyncToggleState = true,
    NoUI = false,
});

FLY:AddLabel("WASD = move, Space = up, LeftControl = down");

local FALL = Tabs.Move:AddLeftGroupbox("Fall Damage");

FALL:AddToggle("VSH_NoFall", {
    Text = "No Fall Damage",
    Default = getgenv().wh_no_fall,
    Tooltip = "Removes the landing effects and caps how fast you can fall",
    Callback = function(v) getgenv().wh_no_fall = v; end,
});

FALL:AddSlider("VSH_FallSpeed", {
    Text = "Max Fall Speed",
    Default = getgenv().wh_fall_speed,
    Min = 10,
    Max = 300,
    Rounding = 0,
    Suffix = " st/s",
    Callback = function(v) getgenv().wh_fall_speed = v; end,
});

local RIDE = Tabs.Move:AddRightGroupbox("Riding");

RIDE:AddToggle("VSH_ShootRiding", {
    Text = "Shoot While Riding",
    Default = getgenv().wh_shoot_riding,
    Tooltip = "Re-parents a gun onto the character so the seated state stops blocking it",
    Callback = function(v) getgenv().wh_shoot_riding = v; end,
});

RIDE:AddLabel("Keep this off if it fights with the game's own mount handling.");

--================================================================
--  TAB: RENDER
--================================================================
local CAML = Tabs.Render:AddLeftGroupbox("Field of View");

CAML:AddToggle("VSH_FovCustom", {
    Text = "Custom FOV",
    Default = getgenv().wh_fov_custom,
    Callback = function(v) getgenv().wh_fov_custom = v; end,
});

CAML:AddSlider("VSH_Fov", {
    Text = "FOV",
    Default = getgenv().wh_fov,
    Min = 30,
    Max = 120,
    Rounding = 0,
    Callback = function(v) getgenv().wh_fov = v; end,
});

local FAKE = Tabs.Render:AddRightGroupbox("Fake Rotation");

FAKE:AddToggle("VSH_FakeRot", {
    Text = "Fake Rotation",
    Default = getgenv().wh_fake_rot,
    Tooltip = "Others see your body turned; your camera and aim stay normal",
    Callback = function(v) getgenv().wh_fake_rot = v; end,
});

FAKE:AddSlider("VSH_FakePitch", {
    Text = "Pitch",
    Default = getgenv().wh_fake_pitch,
    Min = -180,
    Max = 180,
    Rounding = 0,
    Suffix = " deg",
    Callback = function(v) getgenv().wh_fake_pitch = v; end,
});

FAKE:AddDropdown("VSH_FakeMode", {
    Text = "Rotation Mode",
    Values = { "Custom", "Spin", "Random" },
    Default = getgenv().wh_fake_mode,
    AllowNull = false,
    Tooltip = "Custom = your sliders | Spin = continuous yaw | Random = re-rolls all angles",
    Callback = function(v) getgenv().wh_fake_mode = v; end,
});

FAKE:AddSlider("VSH_SpinSpeed", {
    Text = "Spin Speed",
    Default = getgenv().wh_fake_spin_speed,
    Min = 10,
    Max = 1000,
    Rounding = 0,
    Suffix = " deg/s",
    Callback = function(v) getgenv().wh_fake_spin_speed = v; end,
});

FAKE:AddSlider("VSH_RandInt", {
    Text = "Random Every",
    Default = getgenv().wh_fake_rand_int,
    Min = 0.05,
    Max = 3,
    Rounding = 2,
    Suffix = " s",
    Callback = function(v) getgenv().wh_fake_rand_int = v; end,
});

FAKE:AddToggle("VSH_FakeTargetBased", {
    Text = "Base On Silent-Aim Target",
    Default = getgenv().wh_fake_target_based,
    Tooltip = "Turn the body toward whatever silent aim is locked on (add Yaw 180 to face away from the enemy)",
    Callback = function(v) getgenv().wh_fake_target_based = v; end,
});

FAKE:AddSlider("VSH_FakeYaw", {
    Text = "Yaw",
    Default = getgenv().wh_fake_yaw,
    Min = -180,
    Max = 180,
    Rounding = 0,
    Suffix = " deg",
    Callback = function(v) getgenv().wh_fake_yaw = v; end,
});

FAKE:AddSlider("VSH_FakeRoll", {
    Text = "Roll",
    Default = getgenv().wh_fake_roll,
    Min = -180,
    Max = 180,
    Rounding = 0,
    Suffix = " deg",
    Callback = function(v) getgenv().wh_fake_roll = v; end,
});

FAKE:AddLabel("Yaw 180 = body faces backwards. AutoRotate is suspended while on.");

--================================================================
--  TAB: LIGHTING
--================================================================
local LIGHT = Tabs.Render:AddLeftGroupbox("Lighting");

LIGHT:AddToggle("VSH_Ambient", {
    Text = "Ambient",
    Default = getgenv().wh_amb,
    Callback = function(v) getgenv().wh_amb = v; end,
});
addColorPicker(LIGHT, "VSH_AmbColor", {
    Title = "Ambient Color",
    Default = getgenv().wh_amb_color,
    Callback = function(c) getgenv().wh_amb_color = c; end,
});

LIGHT:AddToggle("VSH_OutAmb", {
    Text = "Outdoor Ambient",
    Default = getgenv().wh_outamb,
    Callback = function(v) getgenv().wh_outamb = v; end,
});
addColorPicker(LIGHT, "VSH_OutAmbColor", {
    Title = "Outdoor Ambient Color",
    Default = getgenv().wh_outamb_color,
    Callback = function(c) getgenv().wh_outamb_color = c; end,
});

LIGHT:AddToggle("VSH_Bright", {
    Text = "Brightness",
    Default = getgenv().wh_bright,
    Callback = function(v) getgenv().wh_bright = v; end,
});
LIGHT:AddSlider("VSH_BrightVal", {
    Text = "Brightness Value",
    Default = getgenv().wh_bright_val,
    Min = 0,
    Max = 5,
    Rounding = 2,
    Callback = function(v) getgenv().wh_bright_val = v; end,
});

LIGHT:AddToggle("VSH_NoFog", {
    Text = "No Fog",
    Default = getgenv().wh_nofog,
    Tooltip = "Pushes FogEnd out and drops Atmosphere density to 0",
    Callback = function(v) getgenv().wh_nofog = v; end,
});

LIGHT:AddToggle("VSH_Time", {
    Text = "Time Of Day",
    Default = getgenv().wh_time_on,
    Callback = function(v) getgenv().wh_time_on = v; end,
});
LIGHT:AddSlider("VSH_TimeVal", {
    Text = "Clock Time",
    Default = getgenv().wh_time,
    Min = 0,
    Max = 24,
    Rounding = 2,
    Callback = function(v) getgenv().wh_time = v; end,
});

LIGHT:AddButton("Reset Lighting", function() resetLighting(); end);

local CLOCKLABEL = Tabs.Render:AddRightGroupbox("Status");
local clockLabel = CLOCKLABEL:AddLabel("lighting untouched");
--================================================================
--  TAB: CONFIG
--================================================================
local MENU = Tabs.Config:AddLeftGroupbox("Menu");
MENU:AddButton("Toggle UI", function() Library:Toggle(); end);
MENU:AddButton("Unload", function()
    stop("menu");
    pcall(function() Library:Unload(); end);
end);
MENU:AddLabel("Menu bind: the library's own UI keybind");

local STATUS_BOX = Tabs.Config:AddRightGroupbox("Diagnostics");
local diagLabel = STATUS_BOX:AddLabel("hook: pending");


--================================================================
--  RENDER LOOP
--  One frame = one target scan (shared with the hook) + HUD refresh.
--================================================================
--  FLY KEYBIND FALLBACK
--  Normally the Linoria key picker on the toggle handles this, including
--  listing the key in the library's own keybind panel. This listener is only
--  installed when that build has no AddKeyPicker/AddKeyBind at all, so the
--  keybind works either way.
--================================================================
if flyKeyPicker == nil then
    table.insert(Connections, UIS.InputBegan:Connect(function(input, gpe)
        if not Running or gpe then return; end; -- gpe: don't fire while typing
        local key = getgenv().wh_fly_key;
        if type(key) ~= "string" or key == "" then key = "F"; end;
        if input.KeyCode and input.KeyCode.Name == key then
            local v = not (getgenv().wh_fly == true);
            getgenv().wh_fly = v;
            if flyToggle then pcall(function() flyToggle:SetValue(v); end); end;
        end;
    end));
end
local fakeRotWasOn = false;
table.insert(Connections, RunService.RenderStepped:Connect(function(dt)
    if not Running then return; end;
    frameId = frameId + 1;
    local ok = pcall(function()
        local part = currentTarget();
        updateHud(part);
        applyAutoshoot();
        updateEsp();
        applyFov();
        applySpeedBoost(dt);
        applyFly(dt);
        applyLighting();
        applyNoFallDamage();
        -- fake rotation rebuilds the facing every frame; put AutoRotate back
        -- as soon as it is switched off
        if getgenv().wh_fake_rot then
            applyFakeRotation(dt);
            fakeRotWasOn = true;
        elseif fakeRotWasOn then
            fakeRotWasOn = false;
            restoreAutoRotate();
        end;
    end);
    if not ok then
        HookStatus.renderErrors = HookStatus.renderErrors + 1;
        if tracer then tracer.Visible = false; end; -- never leave a stale line behind
    end;
end));

-- diagnostics, refreshed a few times a second rather than every frame
task.spawn(function()
    while Running do
        task.wait(0.25);
        pcall(function()
            diagLabel:SetText(string.format(
                "hook %s | shots %d | redirects %d | spread %s | recoil %s",
                HookStatus.installed and "on" or "off",
                HookStatus.shots, HookStatus.redirects,
                HookStatus.noSpread and "on" or "off",
                HookStatus.noRecoil and "on" or "off"));
            local wt = getEquippedTool();
            -- show the gun's LIVE built stats: this is how you confirm the weapon
            -- mods actually applied (spread 0, and speed 0 = hitscan/instant)
            local lc = wt and liveConfigs[wt];
            gunStatusLabel:SetText(string.format("%s | fm %s | spd %s | sprd %s | rpm %s",
                wt and wt.Name or "none",
                tostring(wt and wt:GetAttribute("State_Firemode")),
                lc and tostring(lc.ProjectileVelocity) or "-",
                lc and tostring(lc.ProjectileSpread) or "-",
                lc and tostring(lc.RPM) or "-"));
            clockLabel:SetText(string.format("clock %.2f | amb %s | fog %s",
                Lighting.ClockTime, tostring(Lighting.Ambient),
                getgenv().wh_nofog and "off" or "on"));
        end);
        -- drop NPC references that have been destroyed
        for model in next, npcCache do
            if typeof(model) ~= "Instance" or model.Parent == nil then
                npcCache[model] = nil;
            end;
        end;
    end
end);

--================================================================
--  TEARDOWN
--  The aim hook stays installed but passes straight through once Running is
--  false, which sidesteps executor-specific unhook behaviour.
--================================================================
function stop(reason)
    if not Running then return; end;
    Running = false;
    getgenv().wh_silent_aim = false;
    pcall(restoreAutoRotate); -- never leave AutoRotate off behind us
    for _, c in next, Connections do pcall(function() c:Disconnect(); end); end;
    table.clear(Connections);
    for _, o in next, espPool do freeEsp(o); end;
    table.clear(espPool);
    removeDrawings();
    pcall(function() Library:Unload(); end);
    if getgenv()[INSTANCE_KEY] ~= nil then getgenv()[INSTANCE_KEY] = nil; end;
    print("[VSH] unloaded (" .. tostring(reason or "manual") .. ")");
end

if type(getgenv()[INSTANCE_KEY]) == "table" then
    getgenv()[INSTANCE_KEY].stop = stop;
end

-- tear down whenever the library itself unloads (its unload key, its button, ...)
pcall(function()
    Library:OnUnload(function() stop("library"); end);
end);

if ThemeManager then
    pcall(function()
        ThemeManager:SetLibrary(Library);
        ThemeManager:ApplyToTab(Tabs.Config);
    end);
end
if SaveManager then
    pcall(function()
        SaveManager:SetLibrary(Library);
        SaveManager:IgnoreThemeSettings();
        SaveManager:BuildConfigSection(Tabs.Config);
        SaveManager:LoadAutoloadConfig();
    end);
end

print("[VSH] vagrant survival loaded  (silent aim hook " .. (HookStatus.installed and "on" or "pending") .. ")");

