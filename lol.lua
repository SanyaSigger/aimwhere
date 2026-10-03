
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
local Debris     = cloneref(game:GetService("Debris"));
local SoundSvc   = cloneref(game:GetService("SoundService"));
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
local Library; -- forward decl: hit logs can notify before the UI loader runs
local lastShotAt = 0; -- last time a round was actually created (drives SafeShoot)
lastBulletAt = 0;  -- last real bullet seen; lets the trigger-pull fallback stay quiet
lastMissAt = 0;   -- miss throttling, see MISS_THROTTLE
lastStepError = ""; -- name of the last per-frame step that failed
MISS_THROTTLE = 0.2; -- min seconds between reported misses (auto fire otherwise floods)
local playHitSound; -- forward decl: the instant hit path reports before the sound section
charBorn = {};        -- [Player] = os.clock() when their character appeared
PROTECT_WINDOW = 8;   -- seconds a freshly spawned target counts as protected

-- remember when each player's character appeared; a target that is only a few
-- seconds old is very likely still under spawn protection
do
    local function watch(p)
        charBorn[p] = os.clock();
        p.CharacterAdded:Connect(function() charBorn[p] = os.clock(); end);
    end;
    task.spawn(function()
        for _, p in ipairs(Players:GetPlayers()) do watch(p); end;
        Players.PlayerAdded:Connect(watch);
    end);
end

-- body charm / weapon charm are separate so each can be driven on its own
local function noteShot() lastShotAt = os.clock(); end;
local liveConfigs = setmetatable({}, { __mode = "k" });
-- exact ItemConfigs key each built table came from, so logs name the real item
local liveNames = setmetatable({}, { __mode = "k" });
local builderNames = {};

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
getgenv().wh_fov_thickness  = 3;     -- FOV circle line thickness
getgenv().wh_fov_toggle     = true;  -- draw the FOV circle
getgenv().wh_fov_center     = true;  -- circle stays on screen centre (not the cursor)
getgenv().wh_fov_color      = Color3.fromRGB(150, 0, 255);
getgenv().wh_tracers        = true;
getgenv().wh_tracer_bullets = true;  -- real per-pellet trajectories
getgenv().wh_tracer_life    = 30;    -- seconds a trail stays on screen
getgenv().wh_no_kick        = true;  -- neutralise the client-side kick/anti-cheat
getgenv().wh_no_anticheat     = false; -- master: strip teleport / rubberband / kick logic
getgenv().wh_gravity_on       = false;  -- override workspace.Gravity
getgenv().wh_gravity          = 196.2;  -- the value this place ships with
getgenv().wh_phys_fps         = 60;     -- what GetRealPhysicsFPS() reports
getgenv().wh_tracer_seg_color = Color3.fromRGB(255, 230, 120);
getgenv().wh_tracer_color   = Color3.fromRGB(150, 0, 255);
getgenv().wh_aim_part       = "Head";
getgenv().wh_wallcheck      = false; -- only shoot parts a raycast can actually reach
getgenv().wh_aim_unseen     = true;  -- if nothing is visible, still fire at the locked part
getgenv().wh_target_scavs    = true;
getgenv().wh_target_bears    = true;
getgenv().wh_target_horses   = false;
getgenv().wh_ignore_friends = true;
getgenv().wh_ignore_team    = true;
getgenv().wh_log_leave      = true;  -- notify when a player leaves the server
getgenv().wh_log_reload     = true;  -- notify when you reload
getgenv().wh_log_near       = true;  -- notify when a player is nearby
getgenv().wh_log_near_m     = 100;
getgenv().wh_gun_info       = true;  -- weapon stats under the FOV circle
getgenv().wh_max_distance   = 1000;  -- metres (0 = unlimited)
getgenv().wh_prediction     = true;
getgenv().wh_lead           = 1;     -- 1 = exact lead, >1 over-leads, <1 under-leads
getgenv().wh_ragebot        = false; -- ignore the FOV circle: lock anyone on screen
getgenv().wh_autoshoot      = false; -- fire on the locked target without holding LMB
getgenv().wh_autoshoot_pulse = 0.08;  -- press/release period for semi/pump guns
getgenv().wh_no_spread      = true;
getgenv().wh_no_recoil      = true;
getgenv().wh_auto_fix       = false; -- clear a stuck weapon automatically (opt-in)
getgenv().wh_debug_hook     = false; -- print what the hook decides on every shot
getgenv().wh_hitlogs        = false; -- hit / kill / miss notifications
getgenv().wh_hitlogs_miss   = true;  -- also log shots that did nothing
getgenv().wh_hitlogs_bullet = true;  -- one log per bullet/pellet, not per pull
getgenv().wh_hitlogs_cd     = 0.25;  -- seconds between popups
getgenv().wh_hitlogs_time   = 30;    -- how long a hit log stays on screen

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
getgenv().wh_esp_max_dist   = 500;   -- players / corpses (metres, 0 = unlimited)
getgenv().wh_esp_npc_dist   = 300;   -- npcs + horses (metres, 0 = unlimited)
getgenv().wh_esp_pack_dist  = 200;   -- dropped backpacks (metres, 0 = unlimited)
getgenv().wh_esp_pack       = true;  -- label players/corpses with their backpack
getgenv().wh_esp_pack_max   = 3;     -- backpacks listed per character
getgenv().wh_esp_pack_color = Color3.fromRGB(200, 200, 120);
getgenv().wh_esp_corpses    = false; -- dead bodies
getgenv().wh_esp_corpse_color = Color3.fromRGB(230, 90, 90);
getgenv().wh_item_finder    = false; -- show what a player is holding
getgenv().wh_item_search    = { Any = true }; -- Linoria Multi values are a set
getgenv().wh_item_color      = Color3.fromRGB(120, 255, 140);

-- Weapon extras
getgenv().wh_no_bullet_drop = true;
getgenv().wh_instant_hit    = false; -- forces the game's Hitscan path
getgenv().wh_rapidfire      = false;
getgenv().wh_tool_fast_rate  = 1;     -- melee swing rate multiplier (1 = off)
getgenv().wh_rpm_mult      = 2;     -- RPM multiplier (interval = 60 / RPM)
getgenv().wh_full_auto     = false; -- Semi/Pump guns fire while the button is held
getgenv().wh_force_auto     = false; -- alias of full auto, named for clarity in the menu
getgenv().wh_force_hit      = false; -- remove the weapon's max range so any distance hits

-- Instant action


-- Movement
getgenv().wh_speed_on       = false;
getgenv().wh_speed_accel    = 8;      -- how fast the boost ramps up (higher = smoother)
getgenv().wh_speed_cap      = 0;     -- hard speed ceiling in st/s (0 = no limit)
getgenv().wh_reach_on        = false;  -- extend proximity prompt range
getgenv().wh_reach_distance  = 40;     -- new MaxActivationDistance in studs
getgenv().wh_respawn_death   = false; -- respawn where you died
getgenv().wh_autoloadout      = false; -- instantly respawn + auto-equip default loadout
getgenv().wh_loadout_slot     = 1;     -- which of the 3 loadouts to use
getgenv().wh_loadout_equip    = true;  -- also equip the first tool
getgenv().wh_rb_logs         = true;  -- rubberband monitor
getgenv().wh_rb_notify       = true;  -- print to chat as well
getgenv().wh_rb_adaptive     = true;  -- take 1 st/s off the speed per snap
getgenv().wh_speed_floor     = 16;    -- auto-lower will not go below this
getgenv().wh_rb_threshold    = 7;     -- studs of unexplained movement = a snap
getgenv().wh_rb_notify_time  = 5;    -- seconds the popup stays up

getgenv().wh_jump          = false;
getgenv().wh_jump_power    = 95;    -- studs/s of upward velocity on take-off
getgenv().wh_speed          = 45;    -- extra studs/s appended by CFrame movement
getgenv().wh_shoot_riding   = false; -- keep a gun equipped while seated on a horse

-- Camera / fake rotation
getgenv().wh_fov_custom     = false;
getgenv().wh_fov            = 90;
getgenv().wh_fake_rot       = false;
getgenv().wh_fake_rot_weapon_only = true; -- auto-off while a melee tool is held
getgenv().wh_fake_pitch     = 0;
getgenv().wh_fake_yaw       = 180;   -- 180 = body faces backwards
getgenv().wh_fake_roll      = 0;
getgenv().wh_fake_target_based = false; -- face the silent-aim target instead of the camera
getgenv().wh_safeshoot     = true;  -- stand normally for a moment around each shot
getgenv().wh_safeshoot_time = 0.3;  -- seconds
getgenv().wh_fake_cam       = false; -- make the server think we look at the ground
getgenv().wh_fake_cam_pitch = 45;   -- degrees of extra downward pitch
getgenv().wh_fake_cam_dir  = "Down"; -- Down = ground, Up = sky

-- Sounds
getgenv().wh_snd_hit        = false;
getgenv().wh_snd_hit_id     = "rbxassetid://6607204501";
getgenv().wh_snd_hit_preset = "neverlose";
getgenv().wh_snd_vol        = 1.5;


-- Body charm
getgenv().wh_charm          = false;
getgenv().wh_charm_mat      = "ForceField";
getgenv().wh_charm_color    = Color3.fromRGB(80, 170, 255);
getgenv().wh_charm_parts    = { Head = true };
getgenv().wh_charm_w        = false;      -- weapon charm (separate settings)
getgenv().wh_charm_w_mat    = "ForceField";
getgenv().wh_charm_w_color  = Color3.fromRGB(255, 140, 60);
getgenv().wh_fake_mode      = "Custom"; -- Custom | Spin | Random | Jitter | Manual

-- Fall damage
getgenv().wh_onetap_anims     = false; -- animations play at ~15 fps
getgenv().wh_onetap_fps       = 15;    -- target "framerate" for animations
getgenv().wh_no_fall        = true;
getgenv().wh_fall_speed     = 60;   -- max downward studs/s while falling
getgenv().wh_fake_spin_speed = 720;    -- deg/s while in Spin
getgenv().wh_fake_rand_int   = 0.4;    -- seconds between random changes
getgenv().wh_jitter_interval  = 0.15;  -- seconds between yaw changes in Jitter

-- Fly (CFrame)
getgenv().wh_fly            = false;
getgenv().wh_fly_speed      = 80;     -- studs/s
getgenv().wh_fly_key        = "F";    -- keybind that toggles fly

-- Lighting
getgenv().wh_nofog          = false;
getgenv().wh_weather          = "Game"; -- Off | Clear | Rain | LightningStorm | BloodMoon
getgenv().wh_fullbright      = false; -- force the lighting values every time the game changes them
getgenv().wh_nograss         = false;

-- shared distance conversion (matches the repo's ESP / status readouts)
local STUDS_PER_METER = 3.57;

--================================================================
--  KICK BYPASS
--  The game ships client-side anti-cheat that calls LocalPlayer:Kick directly:
--    * "Code 2" - Humanoid.WalkSpeed goes above 29.2
--    * "Code 3" - workspace.Gravity is changed
--    * "Code 5" - workspace:GetRealPhysicsFPS() is >= 65 (rewards you for being TOO
--                 fast, which is what CFrame movement looks like)
--  All three resolve to LocalPlayer.Kick, so shadowing that one method stops them.
--  (The server still validates independently - this only removes the local kick.)
--================================================================
--  Two things failed with the original single hookfunction(plr.Kick, noop):
--    * plr.Kick = noop cannot work - Kick is a protected Instance method;
--    * swapping __index on a Roblox Instance metatable usually fails silently,
--      and the "installed" flag used to be set BEFORE the attempt, so it never
--      even retried.
--  Each strategy below is attempted and the one that actually took is recorded,
--  so the status readout reports the truth rather than assuming success.
kickShieldMode = "none";   -- none | hook | hookmethod | metatable
physShadowMode = "none";   -- none | hook | metatable

function disableClientKicks()
    local noop = function() return end;

    if kickShieldMode == "none" then
        local ok = pcall(function()
            local orig = plr.Kick;
            if type(orig) == "function" then
                hookfunction(orig, newcclosure(noop));
                kickShieldMode = "hook";
            end;
        end);
        if ok and kickShieldMode == "hook" then return; end;
    end;

    if kickShieldMode == "none" and type(hookmethod) == "function" then
        local ok = pcall(function()
            hookmethod(plr, "Kick", newcclosure(noop));
            kickShieldMode = "hookmethod";
        end);
        if ok and kickShieldMode == "hookmethod" then return; end;
    end;

    if kickShieldMode == "none" then
        local ok = pcall(function()
            local mt = getmetatable(plr);
            if type(mt) ~= "table" then return; end;
            local orig = mt.__index;
            if type(orig) ~= "function" then
                orig = function(_, k) return rawget(plr, k); end;
            end;
            mt.__index = function(self, key)
                if key == "Kick" then return noop; end;
                return orig(self, key);
            end;
            kickShieldMode = "metatable";
        end);
        if ok and kickShieldMode == "metatable" then return; end;
    end;

    pcall(function()
        hookfunction(Players.LocalPlayer.Kick, newcclosure(noop));
        if kickShieldMode == "none" then kickShieldMode = "hook"; end;
    end);
end

-- GetRealPhysicsFPS is read-only, so the number the GAME sees is changed by
-- shadowing the method it calls. PhysicsSpeed.lua calls it fresh each tick, so a
-- working hook is enough to control what it compares against 65.
workspaceShadowInstalled = false;
function installWorkspaceShadow()
    if workspaceShadowInstalled and physShadowMode ~= "none" then return; end;
    workspaceShadowInstalled = true;
    local function fake()
        local v = getgenv().wh_phys_fps;
        if type(v) ~= "number" then v = 60; end;
        return math.clamp(v, 1, 1000);
    end;
    local ok1, done1 = pcall(function()
        local orig = Workspace.GetRealPhysicsFPS;
        if type(orig) ~= "function" then return false; end;
        hookfunction(orig, newcclosure(fake));
        return true;
    end);
    if ok1 and done1 then physShadowMode = "hook"; return; end;
    local ok2, done2 = pcall(function()
        local mt = getmetatable(Workspace);
        if type(mt) ~= "table" then return false; end;
        local orig = mt.__index;
        if type(orig) ~= "function" then
            orig = function(_, k) return rawget(Workspace, k); end;
        end;
        mt.__index = function(self, key)
            if key == "GetRealPhysicsFPS" then return fake; end;
            return orig(self, key);
        end;
        return true;
    end);
    if ok2 and done2 then physShadowMode = "metatable"; end;
end

-- Any override needs the Kick shield, otherwise the game kicks us for using it.
function ensureKickShield()
    disableClientKicks();
    installWorkspaceShadow();
end

function refreshShields()
    disableClientKicks();
    installWorkspaceShadow();
end

--================================================================
--  GRAVITY / PHYSICS FPS
--
--  Gravity and GetRealPhysicsFPS are the two values the game's own checks read:
--      workspace.Gravity changed   -> Kick("Code 3")
--      GetRealPhysicsFPS() >= 65   -> Kick("Code 5")
--  So moving either one kicks you BY DESIGN unless the Kick shield is active, so
--  touching either one turns the shield on automatically. Gravity is written
--  straight through; GetRealPhysicsFPS is read-only and shadowed instead.
--================================================================
gravityOriginal = nil;

function applyGravityAndPhysics()
    local wantGravity = getgenv().wh_gravity_on == true;
    local anti = getgenv().wh_no_anticheat == true;

    if gravityOriginal == nil then
        pcall(function() gravityOriginal = Workspace.Gravity; end);
    end;

    if wantGravity or anti then ensureKickShield(); end;

    if wantGravity then
        local g = getgenv().wh_gravity or 196.2;
        pcall(function()
            if Workspace.Gravity ~= g then Workspace.Gravity = g; end;
        end);
    elseif anti and gravityOriginal ~= nil then
        -- only restore when the anti-cheat toggle owns gravity; otherwise the
        -- gravity slider above does
        pcall(function()
            if Workspace.Gravity ~= gravityOriginal then
                Workspace.Gravity = gravityOriginal;
            end;
        end);
    end;
end

function applyAntiCheat()
    if not getgenv().wh_no_anticheat then return; end;
    ensureKickShield();
end

--================================================================
--  RUBBERBAND DETECTION
--
--  A rubberband is the server disagreeing with the position we force on the
--  client: we ask for a step forward, and next frame we are somewhere else.
--  It is detected by comparing the distance actually covered this frame against
--  the distance our own boost could legitimately account for.
--
--  Reading the expectation off the live velocity alone is not enough:
--    * the Velocity method bleeds the horizontal component off when no key is
--      held, so post-collision velocity understates what we just moved;
--    * the CFrame / TPWalk methods move the RootPart directly and leave almost
--      no velocity behind, which made every frame look like a snap.
--  So the commanded speed (speedRamp) is used while the boost is running.
--================================================================
rbLastPos = nil;
rbCount = 0;
rbLastAt = 0;
rbLastInfo = "none yet";

function detectRubberband(dt)
    local char = plr.Character;
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if not hrp then
        rbLastPos = nil;
        return;
    end;
    local p = hrp.Position;
    if rbLastPos then
        local moved = (p - rbLastPos).Magnitude;
        local expected = math.min(hrp.AssemblyLinearVelocity.Magnitude * dt, 40);
        if getgenv().wh_speed_on and type(speedRamp) == "number" and speedRamp > 0 then
            expected = math.min(speedRamp * dt, 40);
        end;
        local thresh = getgenv().wh_rb_threshold or 7;
        if getgenv().wh_rb_logs and moved > expected + thresh and moved > thresh then
            rbCount = rbCount + 1;
            rbLastAt = os.clock();
            rbLastInfo = string.format("#%d snap %.1f st", rbCount, moved);
            if getgenv().wh_rb_notify then
                -- Library toast rather than a chat message, matching how the hit
                -- logs report. Console print kept as a fallback for traces.
                local msg = string.format(
                    "Rubberband: moved %.1f st but only %.1f st was expected",
                    moved, expected);
                print("[VSH] " .. msg);
                pcall(function()
                    Library:Notify(msg, getgenv().wh_rb_notify_time or 5);
                end);
            end;
            -- Auto-lower: each detected snap takes ONE stud off the speed slider
            -- itself, so the value shown in the menu is the real, reduced one
            -- rather than a hidden multiplier. The slider is pushed back in sync
            -- so the number on screen matches.
            if getgenv().wh_rb_adaptive then
                local cur = getgenv().wh_speed or 45;
                local floor = getgenv().wh_speed_floor or 16;
                local nextSpeed = math.max(floor, cur - 1);
                getgenv().wh_speed = nextSpeed;
                if speedSlider then
                    pcall(function() speedSlider:SetValue(nextSpeed); end);
                end;
                rbLastInfo = string.format("#%d  speed %d st/s", rbCount, nextSpeed);
            else
                rbLastInfo = string.format("#%d snap %.1f st", rbCount, moved);
            end;
        end;
    end;
    rbLastPos = p;
end


task.spawn(function()
    for _ = 1, 20 do
        if not Running then break; end;
        ensureKickShield();
        task.wait(0.5);
    end;
end);
table.insert(Connections, plr.CharacterAdded:Connect(function()
    task.defer(function() ensureKickShield(); end);
end));

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

-- Wildlife is spawned with generated, asset-style names (long hashes and the
-- like), so label those by their CollectionService tag instead of the raw
-- instance name. Players still show their DisplayName.
local KIND_LABELS = {
    ["Horse"] = "Horse",
    ["HorseV8"] = "Horse",
    ["Unicorn"] = "Unicorn",
    ["Bear"] = "Bear",
};
local function displayNameOf(model)
    local owner = Players:GetPlayerFromCharacter(model);
    if owner then return owner.DisplayName; end;
    for tag, label in next, KIND_LABELS do
        if model:HasTag(tag) then return label; end;
    end;
    -- this game spawns its hostile NPCs with random code names; anything armed
    -- gets a readable label instead
    for _, c in ipairs(model:GetChildren()) do
        if c:IsA("Tool") then return "Scav"; end;
    end;
    return model.Name;
end

-- A model is a valid candidate if it is alive, not us, and either a player or
-- (when enabled) an NPC with a Humanoid.
-- What KIND of thing is this model?
-- Decided from the same CollectionService tags the game itself uses (see
-- AITypes.lua and the tag handlers):
--   Horse / HorseV8 / Unicorn -> mount
--   Bear                     -> bear
--   carries a Tool            -> scavenger (the game's armed NPCs)
--   otherwise                 -> some other NPC, not a target
local function modelKind(model)
    if Players:GetPlayerFromCharacter(model) then return "Player"; end;
    local ok, res = pcall(function()
        if model:HasTag("Horse") or model:HasTag("HorseV8")
            or model:HasTag("Unicorn") then return "Horse"; end;
        if model:HasTag("Bear") then return "Bear"; end;
        return nil;
    end);
    if ok and res then return res; end;
    for _, c in ipairs(model:GetChildren()) do
        if c:IsA("Tool") then return "Scav"; end;
    end;
    return "Other";
end

-- Teammates are skipped when "ignore team" is on.
local function onSameTeam(model)
    local owner = Players:GetPlayerFromCharacter(model);
    local myTeam = nil;
    pcall(function() myTeam = plr and plr.Team; end);
    return (owner and myTeam and owner.Team == myTeam) == true;
end

local function isCandidate(model)
    if model == plr.Character then return false; end;
    local hum = model:FindFirstChildOfClass("Humanoid");
    if not hum or hum.Health <= 0 then return false; end;
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart;
    if not root then return false; end;
    if getgenv().wh_ignore_team and onSameTeam(model) then return false; end;
    if Players:GetPlayerFromCharacter(model) then
        return not isWhitelisted(model);
    end;
    -- one switch per kind of NPC
    local kind = modelKind(model);
    if kind == "Horse" then return getgenv().wh_target_horses == true; end;
    if kind == "Bear" then return getgenv().wh_target_bears == true; end;
    if kind == "Scav" then return getgenv().wh_target_scavs == true; end;
    return false;  -- any other unmarked NPC is not a target
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
    if not char then return nil; end;
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("Tool") or (c:IsA("Model") and c:HasTag("Tool")) then return c; end;
    end;
    return nil;
end

-- prefer the real ItemConfigs key, then the game's own attribute, then the raw name
local function gunName(tool)
    if not tool then return "?"; end;
    return liveNames[tool] or tool:GetAttribute("ItemConfig") or tool.Name or "?";
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

    for model in next, npcCache do
        if typeof(model) == "Instance" and model.Parent then consider(model); end;
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
    local bestModel = best:FindFirstAncestorOfClass("Model");
    last.name = bestModel and displayNameOf(bestModel) or "?";
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
--  HIT LOGS
--  Every shot we fire is parked with who it was aimed at, how far away they
--  were and which gun fired it. The game reports the damage of a landed hit
--  locally (EventsClient.Indicator "Hit Indicator"), so a moment later we can
--  say exactly what happened:
--    shot hit   NAME with GUN, 40 damage
--    shot killed NAME with GUN, 210 damage
--    shot miss  NAME with GUN, due to "Not visible"
--  If the indicator never fires, we fall back to comparing the target's health.
--================================================================
local MISS_WINDOW = 0.25; -- a shot with no hit by now is reported missed
local shotQueue = {};
local indicatorHits = {};

local lastNotifyAt = 0;

local function notifyHit(text)
    print("[VSH] " .. text);
    local now = os.clock();
    local cd = getgenv().wh_hitlogs_cd;
    if type(cd) == "number" and cd > 0 and now - lastNotifyAt < cd then return; end;
    lastNotifyAt = now;
    pcall(function() Library:Notify(text, getgenv().wh_hitlogs_time or 30); end);
end

local function distTag(s)
    if type(s.dist) ~= "number" then return ""; end;
    return string.format(" (%dm)", math.floor(s.dist + 0.5));
end

local function logHit(s, dmg, head)
    playHitSound();
    local who = s.name or "target";
    local killed = s.hum == nil or s.hum.Health == nil or s.hum.Health <= 0;
    if killed then
        notifyHit(string.format("shot killed %s with %s, %d damage%s",
            who, s.gun, math.floor(dmg), distTag(s)));
    else
        notifyHit(string.format("shot hit %s with %s, %d damage%s%s",
            who, s.gun, math.floor(dmg), head and " (head)" or "", distTag(s)));
    end;
end

-- why did the shot do nothing? read the gun's own range and the target's state
local function verdictFor(s, diff)
    if type(s.range) == "number" and s.range > 0 and type(s.studs) == "number"
        and s.studs > s.range then
        return "Too far away";
    end;
    if (s.resist and s.resist >= 100) then return "Protected"; end;
    if s.born and (os.clock() - s.born) < PROTECT_WINDOW then return "Protected"; end;
    if diff > 0 then return nil; end; -- it did land after all
    return "Unknown";
end

-- The game's hit marker arrives the moment a round connects, so the newest
-- unresolved shot is claimed and reported straight away instead of waiting for
-- a poll. That is what makes the log feel instant.
local function claimShotForHit(dmg, head, pos)
    local now = os.clock();
    for i = #shotQueue, 1, -1 do
        local s = shotQueue[i];
        if not s.resolved and (now - s.t) < 0.6 then
            s.resolved = true;
            s.total = (s.total or 0) + dmg;
            s.head = s.head or (head == true);
            s.pos = s.pos or pos;
            table.remove(shotQueue, i);
            logHit(s, s.total, s.head);
            return true;
        end;
    end;
    return false;
end

-- the game's own hit marker carries the exact damage it dealt
local function installIndicatorLog()
    local ok, ev = pcall(function()
        local events = RS:FindFirstChild("Events");
        local client = events and events:FindFirstChild("EventsClient");
        local ind = client and client:FindFirstChild("Indicator");
        return ind;
    end);
    if not ok or not ev or typeof(ev) ~= "Instance" then return false; end;
    local signal = ev:FindFirstChild("Event");
    if not signal or typeof(signal.Connect) ~= "function" then return false; end;
    local okc, conn = pcall(signal.Connect, signal, function(name, pos, dmg, head)
        if name == "Hit Indicator" and type(dmg) == "number" then
            table.insert(indicatorHits, {
                t = os.clock(), dmg = dmg, head = (head == true), pos = pos,
            });
            -- report the hit NOW rather than on the next resolve tick
            if getgenv().wh_hitlogs then claimShotForHit(dmg, head == true, pos); end;
        end;
    end);
    if okc and conn then
        table.insert(Connections, conn);
        return true;
    end;
    return false;
end
task.spawn(function()
    for _ = 1, 12 do
        if not Running then break; end;
        if installIndicatorLog() then break; end;
        task.wait(0.5);
    end;
end);

local lastParkAt = 0;

-- Every hit sound from additional/hitsounds.lua, by its key.
local HIT_SOUNDS = {
    ["neverlose"] = "rbxassetid://6607204501",
    ["rust"] = "rbxassetid://4764109000",
    ["skeet.cc"] = "rbxassetid://4817809188",
    ["fatal"] = "rbxassetid://94204395881101",
    ["bubble"] = "rbxassetid://85730811347567",
    ["csgo kill"] = "rbxassetid://7269900245",
    ["csgo headshot"] = "rbxassetid://6937353691",
    ["fortnite headshot"] = "rbxassetid://2513174484",
    ["arsenal headshot"] = "rbxassetid://8522515167",
    ["fallen headshot"] = "rbxassetid://988593556",
};

-- The dropdown list is derived from the keys above, so adding a sound to
-- HIT_SOUNDS is enough for it to appear in the menu.
--
-- This MUST be defined before the menu is built. It has now been lost twice:
-- once when the weapon/kill sound removal pass cut across this table, and once
-- when an earlier snapshot was restored. Both times the Hit Sound preset
-- dropdown was left with a nil Values list and Linoria threw
--   "AddDropDown: Missing dropdown value list"
local hitPresetValues = {};
for key in pairs(HIT_SOUNDS) do
    table.insert(hitPresetValues, key);
end;
table.sort(hitPresetValues);

--================================================================
--  BODY CHARM
--  Rewrites material + colour on the selected body parts. Originals are stored
--  once so switching it off restores the real character, and the selection is a
--  group set, so picking "Torso" and "Head" touches only those two.
--================================================================
local CHARM_GROUPS = {
    ["Head"]     = { "Head" },
    ["Hair"]     = { "Hair", "HairAccessory" },
    ["Torso"]    = { "UpperTorso", "Torso", "LowerTorso" },
    ["LeftArm"]  = { "LeftUpperArm", "LeftLowerArm", "Left Arm" },
    ["RightArm"] = { "RightUpperArm", "RightLowerArm", "Right Arm" },
    ["LeftLeg"]  = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "Left Leg" },
    ["RightLeg"] = { "RightUpperLeg", "RightLowerLeg", "RightFoot", "Right Leg" },
};
local charmOriginals = {};
weaponCharmOriginals = {};

local function restoreCharm()
    for part, rec in next, charmOriginals do
        if part and part.Parent then
            pcall(function()
                part.Material = rec.mat;
                part.Color = rec.col;
            end);
        end;
    end;
    table.clear(charmOriginals);
end

local function applyCharm()
    if not getgenv().wh_charm then
        restoreCharm(); -- idempotent: clears as soon as the toggle goes off
        return;
    end;
    local char = plr.Character;
    if not char then return; end;
    local matName = getgenv().wh_charm_mat or "ForceField";
    local mat = Enum.Material[matName];
    if not mat then return; end;
    local col = getgenv().wh_charm_color or Color3.new(1, 1, 1);
    local sel = getgenv().wh_charm_parts;
    if type(sel) ~= "table" then sel = { Head = true }; end;
    local function dress(part)
        if not (part and part:IsA("BasePart")) then return; end;
        if not charmOriginals[part] then
            charmOriginals[part] = { mat = part.Material, col = part.Color };
        end;
        pcall(function()
            part.Material = mat;
            part.Color = col;
        end);
    end;

    for group, parts in next, CHARM_GROUPS do
        if sel[group] then
            for _, pn in ipairs(parts) do
                dress(char:FindFirstChild(pn));
            end;
        end;
    end;

    -- hair usually arrives as an Accessory, so catch those by name too
    if sel["Hair"] then
        for _, acc in ipairs(char:GetChildren()) do
            if acc:IsA("Accessory") and string.find(string.lower(acc.Name), "hair", 1, true) then
                for _, p in ipairs(acc:GetDescendants()) do dress(p); end;
            end;
        end;
    end;

end


local restoreWeaponCharm; -- forward decl: called above its definition
-- Every tool we own, not just the equipped one. Tools move between the
-- Backpack and the Character, and the game resets a tool's appearance when it is
-- equipped, so charming only the held weapon meant the charm vanished on the next
-- equip. Charming everything up front (and re-arming on every change) keeps it.
weaponCharmHooked = {};

function weaponTools()
    local out, seen = {}, {};
    local function add(t)
        if t and not seen[t] then seen[t] = true; out[#out + 1] = t; end;
    end;
    local char = plr.Character;
    if char then
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") or (c:IsA("Model") and c:HasTag("Tool")) then add(c); end;
        end;
    end;
    local bp = plr:FindFirstChildOfClass("Backpack");
    if bp then
        for _, c in ipairs(bp:GetChildren()) do
            if c:IsA("Tool") then add(c); end;
        end;
    end;
    return out;
end

local function applyWeaponCharm()
    if not getgenv().wh_charm_w then
        restoreWeaponCharm();
        return;
    end;
    local mat = Enum.Material[getgenv().wh_charm_w_mat or "ForceField"];
    if not mat then return; end;
    local col = getgenv().wh_charm_w_color or Color3.new(1, 1, 1);
    for _, tool in ipairs(weaponTools()) do
        -- re-assert on every equip: the game rebuilds the tool when it is used
        if not weaponCharmHooked[tool] then
            weaponCharmHooked[tool] = true;
            table.insert(Connections, tool.Equipped:Connect(function()
                task.defer(function() applyWeaponCharm(); end);
            end));
        end;
        for _, p in ipairs(tool:GetDescendants()) do
            if p:IsA("BasePart") then
                if not weaponCharmOriginals[p] then
                    weaponCharmOriginals[p] = { mat = p.Material, col = p.Color };
                end;
                pcall(function()
                    p.Material = mat;
                    p.Color = col;
                end);
            end;
        end;
    end;
end

function restoreWeaponCharm()
    for part, rec in next, weaponCharmOriginals do
        if part and part.Parent then
            pcall(function()
                part.Material = rec.mat;
                part.Color = rec.col;
            end);
        end;
    end;
    table.clear(weaponCharmOriginals);
end

-- watch the backpack itself (it is recreated on respawn) and every new tool
local function watchWeaponCharm()
    local bp = plr:FindFirstChildOfClass("Backpack");
    if bp then
        table.insert(Connections, bp.ChildAdded:Connect(function()
            task.defer(function() applyWeaponCharm(); end);
        end));
    end;
    if plr.Character then
        table.insert(Connections, plr.Character.ChildAdded:Connect(function()
            task.defer(function() applyWeaponCharm(); end);
        end));
    end;
end
table.insert(Connections, plr.ChildAdded:Connect(function(child)
    if child:IsA("Backpack") then task.defer(watchWeaponCharm); end;
end));
watchWeaponCharm();

table.insert(Connections, plr.CharacterAdded:Connect(function()
    task.defer(function()
        table.clear(charmOriginals);
        table.clear(weaponCharmOriginals);
        applyCharm();
        applyWeaponCharm();
    end);
end));

--================================================================
--  SOUNDS
--  A small pool of Sound objects is reused instead of spawning one per shot,
--  and ids are accepted with or without the rbxassetid:// prefix.
--================================================================
soundBank = {};
lastHitSoundAt = 0;

local function playOneShot(soundId, position, volume)
    if type(soundId) ~= "string" or soundId == "" then return; end;
    if soundId:match("^%d+$") then soundId = "rbxassetid://" .. soundId; end;
    local snd, fallback;
    for _, s in next, soundBank do
        if not fallback then fallback = s; end;
        if not s.Playing then snd = s; break; end;
    end;
    -- every sound is busy (rapid hits): reuse one and restart it rather than
    -- spawning a new Sound for every single pellet
    snd = snd or fallback;
    if not snd then
        local ok, made = pcall(function()
            local s = Instance.new("Sound");
            s.RollOffMode = Enum.RollOffMode.Inverse;
            s.RollOffMinDistance = 40;
            s.RollOffMaxDistance = 2000;
            s.Parent = SoundSvc;
            return s;
        end);
        if not ok then return; end;
        snd = made;
        table.insert(soundBank, snd);
    end;
    pcall(function()
        snd.SoundId = soundId;
        snd.Volume = volume or getgenv().wh_snd_vol or 1;
        if position then snd:Play(position); else snd:Play(); end;
    end);
end

function playHitSound()
    if not getgenv().wh_snd_hit then return; end;
    -- a shotgun can land many hits at once, so cap the rate
    local now = os.clock();
    if now - lastHitSoundAt < 0.06 then return; end;
    lastHitSoundAt = now;
    -- deliberately 2D (no position): a positional Sound is attenuated by distance
    -- from the listener, which is exactly why a clear hit could go unheard
    playOneShot(getgenv().wh_snd_hit_id, nil, getgenv().wh_snd_vol or 1);
end

local function parkShot(part)
    if not getgenv().wh_hitlogs then return; end;
    local tool = equippedGun();
    local now = os.clock();
    -- The aim hook can run more than once per shot, and at high RPM two real
    -- shots are closer together than the popup cooldown - so never record faster
    -- than the gun can physically fire.
    local cfg = tool and liveConfigs[tool];
    local rpm = (type(cfg) == "table" and cfg.RPM) or 0;
    local minGap;
    if getgenv().wh_hitlogs_bullet then
        -- one record per bullet: only a hair above zero, just enough to keep the
        -- duplicate signal (trigger pull) from double counting the same round
        minGap = 0.004;
    else
        -- merged mode: pellets of one blast collapse into a single entry, using
        -- the EFFECTIVE rate so rapid fire does not swallow genuine shots
        if type(rpm) == "number" and rpm > 0 and getgenv().wh_rapidfire then
            rpm = rpm * math.max(getgenv().wh_rpm_mult or 1, 0.1);
        end;
        minGap = 0.02;
        if type(rpm) == "number" and rpm > 0 then
            minGap = math.max(0.02, (60 / rpm) * 0.55);
        end;
    end;
    if now - lastParkAt < minGap then return; end;
    lastParkAt = now;
    local rec = { t = now, gun = gunName(tool) };
    if part then
        local model = part:FindFirstAncestorOfClass("Model");
        local owner = model and Players:GetPlayerFromCharacter(model);
        rec.name = (owner and owner.DisplayName) or (model and model.Name) or "?";
        local h = model and model:FindFirstChildOfClass("Humanoid");
        rec.hum = h;
        rec.hp = h and h.Health or nil;
        local studs = (part.Position - cam.CFrame.Position).Magnitude;
        rec.dist = studs / STUDS_PER_METER;
        rec.studs = studs;
        -- pull everything we can from the live weapon config, so the log can say
        -- WHY a shot did nothing (out of this gun's range, etc.)
        local wcfg = tool and liveConfigs[tool];
        if type(wcfg) == "table" then
            rec.range = wcfg.ProjectileMaxRange;
            rec.rpm = wcfg.RPM;
        end;
        -- DamageResistance 100 == immune (heavy armour / protection)
        rec.resist = h and h.Parent and h.Parent:GetAttribute("DamageResistance") or nil;
        local owner = model and Players:GetPlayerFromCharacter(model);
        rec.born = owner and charBorn[owner] or nil;
        rec.reason = "Unknown";
    else
        rec.reason = "No target locked";
    end;
    table.insert(shotQueue, rec);
    while #shotQueue > 96 do table.remove(shotQueue, 1); end -- hard bound
end

local function resolveShot(s)
    if not getgenv().wh_hitlogs or s.resolved then return; end;
    s.resolved = true;
    -- nobody claimed this shot: if the target lost health anyway, count it as a
    -- hit (the indicator was missed), otherwise report the miss
    local hpNow = s.hum and s.hum.Health or nil;
    local diff = (s.hp and hpNow) and (s.hp - hpNow) or 0;
    local verdict = verdictFor(s, diff);
    if diff > 0 or verdict == nil then
        logHit(s, math.max(diff, 0), false);
    elseif getgenv().wh_hitlogs_miss and (os.clock() - lastMissAt) >= MISS_THROTTLE then
        -- with force/auto fire the miss rate is enormous; report at most a few a
        -- second so hits and kills are never buried
        lastMissAt = os.clock();
        notifyHit(string.format("shot miss%s with %s%s, due to \"%s\"",
            s.name and (" " .. s.name) or "", s.gun, distTag(s), verdict));
    end;
end

task.spawn(function()
    while Running do
        task.wait(0.03);
        local now = os.clock();
        for i = #shotQueue, 1, -1 do
            if now - shotQueue[i].t >= MISS_WINDOW then
                pcall(resolveShot, table.remove(shotQueue, i));
            end;
        end;
        for k = #indicatorHits, 1, -1 do
            if now - indicatorHits[k].t > 2.5 then table.remove(indicatorHits, k); end;
        end;
    end;
end);

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
-- Every weapon config builder in this game ends with `return table.freeze(t)`,
-- so writing to the table we are handed is REJECTED - which is exactly why the
-- weapon mods used to do nothing at all (the write error was swallowed). Detect
-- the frozen table once and hand the game a private writable copy instead: it is
-- the same data, and the fire code only reads fields off whatever GunConfig it
-- is given.
local frozenCache = setmetatable({}, { __mode = "k" });
local baseRPM = setmetatable({}, { __mode = "k" });
local baseSwingCd = setmetatable({}, { __mode = "k" });   -- original swing cooldown
local baseSwingDur = setmetatable({}, { __mode = "k" });  -- original swing duration
local baseSwingPlay = setmetatable({}, { __mode = "k" }); -- original swing animation speed


local function writableVersion(cfg)
    local cached = frozenCache[cfg];
    if cached then return cached; end;
    -- try an in-place no-op write of an existing key: allowed on a normal table,
    -- an error on a frozen one
    local probe = cfg.ProjectileSpread ~= nil and "ProjectileSpread"
        or (cfg.RPM ~= nil and "RPM" or nil);
    if probe then
        local ok = pcall(function() cfg[probe] = cfg[probe]; end);
        if ok then return cfg; end; -- writable: edit in place
    end;
    local copy = table.clone(cfg);
    if type(copy.RecoilInfo) == "table" then copy.RecoilInfo = table.clone(copy.RecoilInfo); end;
    frozenCache[cfg] = copy;
    return copy;
end

local function applyWeaponModsTo(cfg)
    if type(cfg) ~= "table" then return cfg, false; end;
    local t = writableVersion(cfg);
    local touched = false;
    if getgenv().wh_no_spread and type(t.ProjectileSpread) == "number" then
        pcall(function() t.ProjectileSpread = 0; end);
        touched = true;
    end;
    if getgenv().wh_no_bullet_drop and type(t.ProjectileGravity) == "number" then
        pcall(function() t.ProjectileGravity = 0; end);
        touched = true;
    end;
    if getgenv().wh_instant_hit and type(t.ProjectileVelocity) == "number" then
        pcall(function() t.ProjectileVelocity = 0; end);
        touched = true;
    end;
    -- force hit: the shot raycast / projectile is cut off at ProjectileMaxRange,
    -- so lifting it is what lets a bullet reach a target at any distance
    if getgenv().wh_force_hit and type(t.ProjectileMaxRange) == "number" then
        pcall(function() t.ProjectileMaxRange = 100000; end);
        touched = true;
    end;
    if getgenv().wh_no_recoil and type(t.RecoilInfo) == "table" then
        pcall(function() t.RecoilInfo.NudgeX = NumberRange.new(0, 0); end);
        pcall(function() t.RecoilInfo.NudgeY = NumberRange.new(0, 0); end);
        touched = true;
    end;
    -- BOTH fire mode envs derive the shot interval from 60 / RPM. The original
    -- RPM is remembered per table so re-applying multiplies the BASE value
    -- instead of compounding on the current one.
    -- Melee tools run BehaviourMeleeClient, and their damage is NOT event based:
    --     task.delay(DurationSwingDelay) captures where the HitAttachment markers
    --       are, then a Heartbeat loop raycasts between each marker's old and new
    --       position and applies damage on the first thing it hits
    --     task.delay(DurationSwing) calls StopActiveSwingConn()
    -- Zeroing DurationSwingDelay captures the markers before the arm moves (the
    -- raycast spans nothing) and zeroing DurationSwing tears the hit loop down
    -- immediately. Both produce "animation and sound play, but nothing registers".
    --
    -- So the whole swing is scaled instead: cooldown and duration down, and
    -- PlaybackSpeedSwingAnimation up by the same factor, which keeps the animation
    -- filling its window exactly as before but faster - so the swing no longer
    -- gets chopped off at the end. DurationSwing keeps a floor so a few
    -- Heartbeat frames remain for the raycast to find a target.
    local toolRate = getgenv().wh_tool_fast_rate or 1;
    if type(toolRate) == "number" and toolRate > 1 then
        if baseSwingCd[t] == nil and type(t.DurationSwingCooldown) == "number" then
            baseSwingCd[t] = t.DurationSwingCooldown;
        end;
        if baseSwingDur[t] == nil and type(t.DurationSwing) == "number" then
            baseSwingDur[t] = t.DurationSwing;
        end;
        if baseSwingPlay[t] == nil and type(t.PlaybackSpeedSwingAnimation) == "number" then
            baseSwingPlay[t] = t.PlaybackSpeedSwingAnimation;
        end;
        if baseSwingCd[t] ~= nil then
            pcall(function() t.DurationSwingCooldown = math.max(0, baseSwingCd[t] / toolRate); end);
            touched = true;
        end;
        if baseSwingDur[t] ~= nil then
            pcall(function() t.DurationSwing = math.max(baseSwingDur[t] / toolRate, 0.08); end);
            touched = true;
        end;
        if baseSwingPlay[t] ~= nil then
            pcall(function() t.PlaybackSpeedSwingAnimation = baseSwingPlay[t] * toolRate; end);
            touched = true;
        end;
    elseif baseSwingCd[t] ~= nil then
        -- switching it off puts every original value back exactly
        if type(t.DurationSwingCooldown) == "number" then
            pcall(function() t.DurationSwingCooldown = baseSwingCd[t]; end);
        end;
        if baseSwingDur[t] ~= nil and type(t.DurationSwing) == "number" then
            pcall(function() t.DurationSwing = baseSwingDur[t]; end);
        end;
        if baseSwingPlay[t] ~= nil and type(t.PlaybackSpeedSwingAnimation) == "number" then
            pcall(function() t.PlaybackSpeedSwingAnimation = baseSwingPlay[t]; end);
        end;
    end;

    if type(t.RPM) == "number" and t.RPM > 0 then
        if baseRPM[t] == nil then baseRPM[t] = t.RPM; end;
        if getgenv().wh_rapidfire then
            local mult = math.max(getgenv().wh_rpm_mult or 1, 0.1);
            pcall(function() t.RPM = baseRPM[t] * mult; end);
            touched = true;
        else
            pcall(function() t.RPM = baseRPM[t]; end);
        end;
    end;
    return t, touched;
end

local function patchStats(t, tool, itemName)
    local patched = applyWeaponModsTo(t);
    if type(tool) == "Instance" then
        liveConfigs[tool] = patched;
        liveNames[tool] = itemName;
    end;
    return patched;
end

local function wrapBuilder(fn)
    if type(fn) ~= "function" or wrapped[fn] then return false; end;
    wrapped[fn] = true;
    -- wrap whatever it returns; a builder returning a non-table is left alone
    return pcall(function()
        local orig = clonefunction(fn);
        local itemName = builderNames[fn];
        hookfunction(fn, function(tool, ...)
            local r = orig(tool, ...);
            if type(r) == "table" then r = patchStats(r, tool, itemName); end;
            return r;
        end);
    end);
end

local function walkBuilders(t, depth, prefix)
    if type(t) ~= "table" or (depth or 0) > 2 then return 0; end;
    local n = 0;
    for k, v in next, t do
        local key = (prefix and prefix ~= "") and (prefix .. "/" .. tostring(k)) or tostring(k);
        if type(v) == "function" then
            builderNames[v] = key; -- remember before wrapping so the hook can read it
            if wrapBuilder(v) then n = n + 1; end;
        elseif type(v) == "table" then
            n = n + walkBuilders(v, depth + 1, key);
        end;
    end;
    return n;
end

local function installWeaponHooks()
    if itemConfigs == nil then
        -- GameConfiguration.ItemConfigs is the exact table the gun reads
        -- (GameConfiguration.ItemConfigs[attr](tool)), so prefer it over hunting
        -- for a module by name and hoping it is the same instance.
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
local envRealStart = setmetatable({}, { __mode = "k" }); -- original FireInputStart
local envRealExtra = setmetatable({}, { __mode = "k" }); -- original CanFire/ShootOnce
local applyEnvInterval; -- forward decl: captureEnv uses it before its definition
local envCaptured = {};

local function captureEnv(factory)
    if envCaptured[factory] then return; end;
    envCaptured[factory] = true;
    pcall(function()
        local origFactory = clonefunction(factory);
        hookfunction(factory, function(ctx, ...)
            -- patch the LIVE config BEFORE the env is built: the env derives its
            -- fire interval from 60 / RPM at construction time
            if type(ctx) == "table" and type(ctx.GunConfig) == "table" then
                -- assign back: the env captures this table, so a frozen original
                -- must be swapped for the writable copy BEFORE it is built
                local gc = applyWeaponModsTo(ctx.GunConfig);
                ctx.GunConfig = gc;
                if ctx.Tool then liveConfigs[ctx.Tool] = gc; end;
            end;
            local t = origFactory(ctx, ...);
            if type(t) == "table" and type(ctx) == "table" and ctx.Tool then
                envByTool[ctx.Tool] = t;
                envRealExtra[ctx.Tool] = { CanFire = t.CanFire, ShootOnce = t.ShootOnce };
                -- the interval is captured the moment the env is built, so shrink
                -- it here too when rapid fire is already on
                if getgenv().wh_rapidfire then applyEnvInterval(ctx.Tool); end;
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
            if type(ctx) == "table" and type(ctx.GunConfig) == "table" then
                ctx.GunConfig = applyWeaponModsTo(ctx.GunConfig);
            end;
            local t = origFactory(ctx, fireOnce, anims);
            if not ((getgenv().wh_full_auto or getgenv().wh_force_auto) and type(t) == "table"
                    and type(fireOnce) == "function"
                    and type(t.FireInputStart) == "function") then
                return t;
            end;
            local tool = ctx and ctx.Tool;
            local rpm = (ctx and ctx.GunConfig and ctx.GunConfig.RPM) or 600;
            local interval = 60 / math.max(rpm, 1);
            local origStart = t.FireInputStart;
            -- keep the TRUE original here: the rapid fire pass rewrites the
            -- interval captured in ITS upvalues
            if type(ctx) == "table" and ctx.Tool then envRealStart[ctx.Tool] = origStart; end;
            t.FireInputStart = function(...)
                -- backup shot signal: a genuine trigger pull. parkShot de-duplicates,
                -- so this only covers the case where the projectile env was missed
                noteShot();
                -- fallback only: the projectile env logs the real bullet, so skip
                -- here if one was already seen for this pull
                if os.clock() - lastBulletAt > 0.05 then pcall(parkShot, last.part); end;
                local fmTool = type(ctx) == "table" and ctx.Tool or nil;
                local fmName = fmTool and fmTool:GetAttribute("State_Firemode");
                origStart(...);
                -- an "Auto" fire mode already loops on its own Heartbeat; running
                -- our loop on top would double the rate and double every log entry
                if fmName == "Auto" then return end;
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

-- Melee tools never build a gun firemode env, so installFullAutoForTool never
-- sees them. Patch the shared ItemConfigs table instead, which is what
-- BehaviourMeleeClient reads its swing durations from. Runs for the whole
-- session so the slider stays live on the tool already in hand, and so setting
-- it back to 1x restores the originals.
function patchMeleeItemConfigs()
    -- no early-out at 1x: applyWeaponModsTo carries the restore branch
    pcall(function()
        local configs = findModuleByName("ItemConfigs");
        if type(configs) ~= "table" then return; end;
        for key, fn in pairs(configs) do
            if type(fn) == "function" then
                local ok, res = pcall(fn);
                if ok and type(res) == "table" then
                    applyWeaponModsTo(res);
                    local w = writableVersion(res);
                    if w ~= res then configs[key] = function() return w; end; end;
                end;
            end;
        end;
    end);
end
task.spawn(function()
    while Running do
        pcall(patchMeleeItemConfigs);
        task.wait(0.5);
    end;
end);

table.insert(Connections, plr.CharacterAdded:Connect(watchForTools));
watchForTools(plr.Character);

-- Weapon toggles apply to the gun you are ALREADY holding: the fire mode envs
-- keep a reference to the same config table and re-read RPM, so re-apply often.
task.spawn(function()
    while Running do
        task.wait(0.5);
        local char = plr.Character;
        local tool = char and char:FindFirstChildOfClass("Tool");
        local cfg = tool and liveConfigs[tool];
        if cfg then
            local patched = applyWeaponModsTo(cfg);
            if patched ~= cfg and tool then liveConfigs[tool] = patched; end;
        end;
        -- rewrite the captured shot interval so enabling rapid fire (or changing
        -- the multiplier) works on the gun already in your hands
        if tool then applyEnvInterval(tool); end;
    end;
end);
--================================================================
--  AUTO SHOOT
--
--  THE REAL SHOT MESSAGE (BehaviourGunClient.lua, inside FireOnce):
--      CommunicateGun2:FireServer("Fired",
--          v86.Position,   -- muzzle position
--          v86.LookVector, -- aim direction
--          v82,            -- the point aimed at (RayMouse.GetMousePosition)
--          t6,            -- per-pellet { id, lookVector } table
--          v_u_2)         -- MessageHandler instance
--
--  Two things the earlier versions got wrong, both of which made firing a
--  no-op:
--    1. WRONG PAYLOAD. It sent FireServer("Fired", mousePos) - two arguments.
--       The server expects six. The shape has to match or the shot is dropped.
--    2. WRONG REMOTE NAMING. Inside the game, "CommunicateGun2" is the SERVER
--       RemoteEvent (EventsReplication.CommunicateGun) and plain
--       "CommunicateGun" is the LOCAL BindableEvent (EventsClient). The names
--       are inverted relative to intuition, so this resolves both explicitly by
--       path instead of by guessing.
--
--  This reproduces FireOnce's own message exactly, and lets the game's own
--  firemode env run first so ammo, reload, sound and recoil all stay correct.
--================================================================
gunFireRemote = nil;    -- EventsReplication.CommunicateGun  (-> server)
gunLocalFire = nil;     -- EventsClient.CommunicateGun       (local bindable)
gunFireRemoteTool = nil;
gunMsgHandler = nil;

function getGunFireRemotes()
    if gunFireRemote and gunLocalFire then return; end;
    pcall(function()
        local e = RS:FindFirstChild("Events");
        local rep = e and e:FindFirstChild("EventsReplication");
        local cli = e and e:FindFirstChild("EventsClient");
        local r = rep and rep:FindFirstChild("CommunicateGun");
        local l = cli and cli:FindFirstChild("CommunicateGun");
        if type(r) == "Instance" then gunFireRemote = r; end;
        if type(l) == "Instance" then gunLocalFire = l; end;
    end);
    if not gunMsgHandler then
        -- the game passes its MessageHandler instance as the last argument
        pcall(function()
            local ok, mod = pcall(findModuleByName, "MessageHandler");
            if ok and mod then
                local okReq, req = pcall(require, mod);
                if okReq then
                    local okCall, h = pcall(function() return req(); end);
                    if okCall and type(h) == "table" then gunMsgHandler = h; end;
                end;
            end;
        end);
    end;
end

function getGunFireRemote()
    getGunFireRemotes();
    return gunFireRemote;
end;

autoshootHolding = false;
autoshootNextAt = 0;

function isAutoFire(tool)
    return tool and tool:GetAttribute("State_Firemode") == "Auto";
end

-- The world point a shot should be aimed at. Silent aim and the aura both
-- redirect the game's own GetMousePosition, so this stays consistent with them.
function gunShotAimPoint()
    local ok, rm = pcall(findModuleByName, "RayMouse");
    if ok and rm then
        local okReq, req = pcall(require, rm);
        if okReq and type(req) == "table" and type(req.GetMousePosition) == "function" then
            local okPos, pos = pcall(req.GetMousePosition);
            if okPos and typeof(pos) == "Vector3" then return pos; end;
        end;
    end;
    if cam then return cam.CFrame.Position + cam.CFrame.LookVector * 500; end;
    return Vector3.new(0, 0, 0);
end

-- Where the muzzle is. Falls back to the root part when the tool has no Handle.
-- Push the shot origin out past our own body.
--
-- The game excludes { Character, Camera } from its CLIENT raycast
-- (BehaviourGunClient.UpdateRayParams), so on our own screen a shot never hits
-- us. But the SERVER resolves damage from the muzzle position we hand it in the
-- "Fired" payload. That origin sits inside the tool Handle, which is attached to
-- our arm - so with fake rotation, a rotated body, or a close-range shot, the
-- server's ray starts inside our own hitbox and kills us.
--
-- Fix: cast along the shot direction, and if the very first thing hit is part of
-- our own character, move the origin just past that surface. The direction and
-- the aim point are untouched, so the shot still lands exactly where it should.
-- Include (not Exclude) with ONLY our character in the list: the ray then
-- reports our own limbs and nothing else, which is exactly what we need to test
-- for. Using Exclude here would hide our own body and the check could never fire.
selfFilter = RaycastParams.new();
selfFilter.FilterType = Enum.RaycastFilterType.Include;
selfFilter.IgnoreWater = true;

function gunClearMuzzle(muzzle, dir)
    local char = plr.Character;
    if not char then return muzzle; end;
    -- aim at something far away along the shot direction, but only to the nearest
    -- hit: we are testing whether OUR OWN body is the first thing in the way
    selfFilter.FilterDescendantsInstances = { char };
    local ok, hit = pcall(Workspace.Raycast, Workspace, muzzle, dir * 12, selfFilter);
    if not ok or not hit then return muzzle; end;
    local model = hit.Instance:FindFirstAncestorOfClass("Model");
    if model and model:IsDescendantOf(char) then
        -- step just beyond our own limb so the server ray no longer starts inside us
        return hit.Position + dir * 0.25;
    end;
    return muzzle;
end

function gunMuzzlePosition(tool)
    local handle = tool and tool:FindFirstChild("Handle", true);
    if handle and handle:IsA("BasePart") then return handle.Position; end;
    local char = plr.Character;
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if hrp then return hrp.Position; end;
    return Vector3.new(0, 0, 0);
end

-- The authoritative shot, matching FireOnce's six-argument payload exactly.
function gunSendFired(tool)
    if not gunFireRemote then return; end;
    local muzzle = gunMuzzlePosition(tool);
    local aimPoint = gunShotAimPoint();
    local dir = (aimPoint - muzzle);
    if dir.Magnitude < 0.001 then
        if cam then dir = cam.CFrame.LookVector; else dir = Vector3.new(0, 0, -1); end;
    end;
    -- keep the origin out of our own hitbox so the server cannot hit us
    muzzle = gunClearMuzzle(muzzle, dir.Unit);
    local cf = CFrame.lookAt(muzzle, muzzle + dir.Unit);
    -- per-pellet entries: { "<servertime>|<index>", <lookVector> }
    local stamp = tostring(workspace:GetServerTimeNow());
    local pellets = { { stamp .. "|1", cf.LookVector } };
    pcall(function()
        gunFireRemote:FireServer("Fired", cf.Position, cf.LookVector,
            aimPoint, pellets, gunMsgHandler);
    end);
end

-- One complete round: open the burst, fire, close it.
function gunFireOnce(tool)
    if gunLocalFire then
        pcall(function() gunLocalFire:Fire(tool, "ReplicateFire"); end);
    end;
    if gunFireRemote then
        pcall(function() gunFireRemote:FireServer("FireStart"); end);
    end;
    gunSendFired(tool);
    if gunFireRemote then
        pcall(function() gunFireRemote:FireServer("FireEnd"); end);
    end;
    if gunLocalFire then
        pcall(function() gunLocalFire:Fire(tool, "ReplicateFireEnd"); end);
    end;
end

--================================================================
--  AUTO SHOOT  (VirtualInputManager)
--
--  VIM drives the REAL trigger input:
--      VIM:SendMouseButtonEvent(MouseButton1, 0, x, y, 0, true/false, false, 0)
--  so the weapon fires through the game's own path - ContextActionService sees a
--  genuine mouse button and everything downstream (ammo, reload, sound, recoil,
--  rate limiting) stays the game's own code.
--
--  VirtualInputManager is a STUDIO-ONLY service. It is absent on a published
--  client, and that is exactly why an earlier VIM attempt appeared to do nothing.
--  vimKind records which path is genuinely in use and is shown in the Combat
--  status box, so it is never guesswork. The CommunicateGun protocol is kept as a
--  fallback so the feature still functions when VIM is not available.
--================================================================
vim = nil;
vimKind = "none";

function getVim()
    if vim then return vim; end;
    local ok, v = pcall(function()
        local svc = game:GetService("VirtualInputManager");
        if not svc or type(svc.SendMouseButtonEvent) ~= "function" then return nil; end;
        return svc;
    end);
    if ok and v then
        vim = v;
        vimKind = "VIM";
    else
        vimKind = "gun remote (no VIM)";
    end;
    return vim;
end

function vimPress(down)
    local v = getVim();
    if not v then return false; end;
    local x, y = 0, 0;
    pcall(function()
        local loc = UIS:GetMouseLocation();
        if loc then x, y = loc.X, loc.Y; end;
    end);
    local ok = pcall(function()
        v:SendMouseButtonEvent(Enum.UserInputType.MouseButton1, 0, x, y, 0,
            down, false, 0);
    end);
    return ok;
end

function applyAutoshoot()
    local enabled = getgenv().wh_autoshoot == true;
    local hasTarget = (last and last.part ~= nil);
    local wantFire = enabled and hasTarget;

    local tool = getEquippedTool();
    if wantFire and tool then
        getVim();
        getGunFireRemotes();
    end;
    local server = wantFire and gunFireRemote or nil;

    -- release: let go of the trigger and close any open server burst
    if not wantFire or not tool then
        if autoshootHolding then
            autoshootHolding = false;
            vimPress(false);
            if server then pcall(function() server:FireServer("FireEnd"); end); end;
            if gunLocalFire then
                pcall(function() gunLocalFire:Fire(tool, "ReplicateFireEnd"); end);
            end;
        end;
        if not wantFire then gunFireRemoteTool = nil; end;
        return;
    end;

    if getVim() then
        -- VIM path: hold the real mouse button down and let the weapon's own RPM
        -- decide how fast rounds leave the barrel.
        if not autoshootHolding then
            autoshootHolding = true;
            vimPress(true);
            gunSendFired(tool);   -- first round goes out immediately
        end;
        return;
    end;

    -- fallback for clients with no VirtualInputManager: the game's own protocol
    if not server then return; end;
    local ammo = tool:GetAttribute("State_Ammo_Client");
    if type(ammo) == "number" and ammo <= 0 then return; end;

    if gunFireRemoteTool ~= tool then
        if autoshootHolding then
            pcall(function() server:FireServer("FireEnd"); end);
        end;
        autoshootHolding = false;
        gunFireRemoteTool = tool;
    end;

    local env = envByTool[tool];
    local now = os.clock();
    if isAutoFire(tool) then
        if not autoshootHolding then
            autoshootHolding = true;
            if env and type(env.FireInputStart) == "function" then
                pcall(function() env.FireInputStart(); end);
            end;
            if gunLocalFire then
                pcall(function() gunLocalFire:Fire(tool, "ReplicateFire"); end);
            end;
            pcall(function() server:FireServer("FireStart"); end);
        end;
        if now >= autoshootNextAt then
            autoshootNextAt = now + math.max(getgenv().wh_autoshoot_pulse or 0.35, 0.02);
            gunSendFired(tool);
        end;
        return;
    end;

    -- semi / pump / bolt
    if autoshootHolding then
        autoshootHolding = false;
        if env and type(env.FireInputEnd) == "function" then
            pcall(function() env.FireInputEnd(); end);
        end;
        pcall(function() server:FireServer("FireEnd"); end);
        if gunLocalFire then
            pcall(function() gunLocalFire:Fire(tool, "ReplicateFireEnd"); end);
        end;
    end;
    if now >= autoshootNextAt then
        autoshootNextAt = now + math.max(getgenv().wh_autoshoot_pulse or 0.35, 0.05);
        if env then
            local can = true;
            if type(env.CanFire) == "function" then
                local okC, res = pcall(function()
                    return env.CanFire(plr.Character and plr.Character:GetAttribute("IsReloading"));
                end);
                if okC and res == false then can = false; end;
            end;
            if can then
                pcall(function() env.FireInputStart(); end);
                pcall(function() env.FireInputEnd(); end);
            end;
        end;
        gunFireOnce(tool);
    end;
end

--================================================================
--  BULLET TRAILS
--  The projectile envs call env.Fire(shotId, origin, dir) ONCE PER PELLET, with
--  the direction already rotated by that pellet's spread offset and the origin at
--  the muzzle. Wrapping env.Fire (read-only - the original still runs untouched)
--  therefore hands us the exact flight path of every bullet, which we integrate
--  with the gun's own ProjectileVelocity / ProjectileGravity so the trail drops
--  exactly like the real round. Hitscan guns (velocity 0) get a straight line
--  ending at their real raycast hit.
--================================================================
--================================================================
--  BULLET TRAILS  (real 3D Parts, not 2D Drawing)
--  An anchored Neon beam between the muzzle and wherever the round actually
--  stopped. These are real instances, so they replicate and every player sees
--  them, and Debris removes them after the trail lifetime. CanQuery is off so a
--  trail can never interfere with the game's own bullet raycasts.
--================================================================
local tracerWrapped = {}; -- [projectile env factory] = true, already wrapped
trailParts = {};          -- every Part we spawned, so they can be wiped early

local function clearTrails()
    for i = #trailParts, 1, -1 do
        pcall(function() trailParts[i]:Destroy(); end);
    end;
    table.clear(trailParts);
end

-- One anchored Neon Part running from the muzzle to wherever the round actually
-- stopped. These are real instances, so they replicate and everyone sees the
-- bullet rather than only you.
function drawBulletTrail(cfg, origin, dir)
    if not getgenv().wh_tracer_bullets then return; end;
    if not (origin and dir) then return; end;
    if not (isFinite(origin.X) and isFinite(origin.Y) and isFinite(origin.Z)) then return; end;
    if not (isFinite(dir.X) and isFinite(dir.Y) and isFinite(dir.Z)) then return; end;
    local mag = dir.Magnitude;
    if mag < 0.0001 then return; end;
    local unit = dir / mag;
    local range = (type(cfg) == "table" and cfg.ProjectileMaxRange) or 2000;
    if type(range) ~= "number" or range <= 0 then range = 2000; end;
    local length = math.min(range, 100000);
    local okc, hit = pcall(Workspace.Raycast, Workspace, origin, unit * length, aimFilter);
    if okc and hit then
        length = math.min(length, (hit.Position - origin).Magnitude);
    end;
    if length < 0.5 then return; end;
    local mid = origin + unit * (length * 0.5);
    local ok, part = pcall(function()
        local p = Instance.new("Part");
        p.Name = "VHSTrail";
        p.Anchored = true;
        p.CanCollide = false;
        p.CanTouch = false;
        p.CanQuery = false;   -- a trail must never block a bullet raycast
        p.CastShadow = false;
        p.Material = Enum.Material.Neon;
        p.Color = getgenv().wh_tracer_seg_color or Color3.new(1, 1, 1);
        p.Transparency = 0.35;
        p.Size = Vector3.new(0.15, 0.15, length);
        p.CFrame = CFrame.lookAt(mid, origin + unit * length);
        p.Parent = Workspace;
        return p;
    end);
    if not (ok and part) then return; end;
    table.insert(trailParts, part);
    while #trailParts > 60 do -- keep the list bounded
        local old = table.remove(trailParts, 1);
        pcall(function() old:Destroy(); end);
    end;
    pcall(function() Debris:AddItem(part, getgenv().wh_tracer_life or 30); end);
end

local function wrapTracerFactory(factory)
    if tracerWrapped[factory] then return; end;
    tracerWrapped[factory] = true;
    pcall(function()
        local orig = clonefunction(factory);
        hookfunction(factory, function(ctx, ...)
            local env = orig(ctx, ...);
            if type(env) == "table" and type(env.Fire) == "function"
                and not tracerWrapped[env.Fire] then
                tracerWrapped[env.Fire] = true;
                local cfg = (type(ctx) == "table" and ctx.GunConfig) or nil;
                local tool = type(ctx) == "table" and ctx.Tool or nil;
                local realFire = clonefunction(env.Fire);
                hookfunction(env.Fire, function(shotId, origin, dir, extra)
                    -- observe only: the game's own Fire still runs, unchanged
                    -- this is a REAL bullet, so this is where a shot is logged
                    noteShot();
                    lastBulletAt = os.clock();   -- a real bullet: one log per bullet
                    pcall(parkShot, last.part);
                    pcall(drawBulletTrail, cfg or (tool and liveConfigs[tool]), origin, dir);
                    return realFire(shotId, origin, dir, extra);
                end);
            end;
            return env;
        end);
    end);
end

-- RAPID FIRE, second pass.
-- The "Auto" fire mode captures its shot interval as an UPVALUE when the env is
-- built:   local interval = 60 / GunConfig.RPM
-- Boosting RPM afterwards therefore does nothing for that gate, which is exactly
-- why the toggle looked dead. So rewrite the captured value itself - that number
-- IS the delay between shots. ("Semi" re-reads RPM live, so it already worked.)
local MIN_SHOT_DELAY = 0.017; -- the game hard-blocks re-entry at ~0.015s

local function shotDelays(tool)
    local cfg = tool and liveConfigs[tool];
    local rpm = (type(cfg) == "table" and baseRPM[cfg]) or nil;
    if type(rpm) ~= "number" then rpm = (type(cfg) == "table" and cfg.RPM) or 600; end;
    local base = 60 / math.max(rpm, 1);
    local mult = getgenv().wh_rapidfire and math.max(getgenv().wh_rpm_mult or 1, 1) or 1;
    return base, math.max(base / mult, MIN_SHOT_DELAY);
end

-- rewrite any captured upvalue that sits on the gun's own shot interval
function applyEnvInterval(tool)
    local env = tool and envByTool[tool];
    if type(env) ~= "table" then return false; end;
    local base, want = shotDelays(tool);
    local targets = {};
    local s = envRealStart[tool];
    if type(s) == "function" then targets[#targets + 1] = s; end;
    local extra = envRealExtra[tool];
    if type(extra) == "table" then
        if type(extra.CanFire) == "function" then targets[#targets + 1] = extra.CanFire; end;
        if type(extra.ShootOnce) == "function" then targets[#targets + 1] = extra.ShootOnce; end;
    end;
    if type(env.CanFire) == "function" then targets[#targets + 1] = env.CanFire; end;
    local changed = false;
    for _, fn in ipairs(targets) do
        pcall(function()
            for i = 1, 64 do
                local up, val = debug.getupvalue(fn, i);
                if up == nil then break; end;
                if type(val) == "number" and val > 0 and math.abs(val - base) <= base * 0.35 then
                    debug.setupvalue(fn, i, want);
                    changed = true;
                end;
            end;
        end);
    end;
    return changed;
end

local function installTracerForTool(tool)
    if not tool then return 0; end;
    local folder = tool:FindFirstChild("ProjectileEnvConstructors", true);
    if not folder then return 0; end;
    local n = 0;
    for _, c in ipairs(folder:GetChildren()) do
        if c:IsA("ModuleScript") then
            local ok, factory = pcall(require, c);
            if ok and type(factory) == "function" then
                wrapTracerFactory(factory);
                n = n + 1;
            end;
        end;
    end;
    return n;
end

-- GLOBAL env scan. Locating the env folders inside the equipped tool is fragile
-- (the folders live on the gun's client module, which is not always a descendant
-- of the Tool), so sweep ReplicatedStorage ONCE for the env constructors by name
-- and wrap every one of them. Both wrappers are self-guarding, so wrapping a
-- module that is not the expected kind is harmless.
local ENV_MODULE_NAMES = { "Auto", "Semi", "Pump", "Hitscan", "Projectile", "ProjectileHoming" };
local envSwept = false;

local function sweepAllEnvModules()
    if envSwept then return 0; end;
    envSwept = true;
    local n = 0;
    pcall(function()
        for _, d in next, RS:GetDescendants() do
            if d:IsA("ModuleScript") then
                local match = false;
                for _, want in ipairs(ENV_MODULE_NAMES) do
                    if d.Name == want then match = true; break; end;
                end;
                if match then
                    local ok, factory = pcall(require, d);
                    if ok and type(factory) == "function" then
                        captureEnv(factory);      -- records the env per tool (autoshoot)
                        wrapTracerFactory(factory); -- bullet trails + shot detection
                        if d.Name ~= "Auto" then wrapFiremodeEnv(factory); end;
                        n = n + 1;
                    end;
                end;
            end;
        end;
    end);
    return n;
end

task.spawn(function()
    for _ = 1, 30 do
        if not Running then break; end;
        if sweepAllEnvModules() > 0 then break; end;
        task.wait(0.5);
    end;
end);

local function watchTracerEnvs(char)
    if not char then return; end;
    local function scan(t) task.defer(function() installTracerForTool(t); end); end;
    local bp = plr:FindFirstChildOfClass("Backpack");
    if bp then bp.ChildAdded:Connect(scan); end;
    char.ChildAdded:Connect(scan);
    task.spawn(function()
        for _ = 1, 8 do
            if not Running then return; end;
            installTracerForTool(getEquippedTool());
            if bp then for _, t in ipairs(bp:GetChildren()) do installTracerForTool(t); end; end;
            task.wait(1);
        end;
    end);
end
table.insert(Connections, plr.CharacterAdded:Connect(watchTracerEnvs));
watchTracerEnvs(plr.Character);

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

table.insert(Connections, plr.CharacterAdded:Connect(function()
    -- a new character starts at the game's default WalkSpeed; the cached base is
    -- re-taken on the next boost frame, but drop the old one so a respawn at a
    -- different speed (spawn protection, mounts) cannot skew the ratio ceiling
    task.defer(function()
        if speedLockOn then
            local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid");
            if hum then setSpeedLock(hum, false); end;
        end;
        speedBaseWalk = nil;
        speedRamp = 0;
    end);
end));

--================================================================
--  WALK SPEED LOCK
--  The game's own Movement module writes Humanoid.WalkSpeed every time the
--  sprint state flips, and the Humanoid's internal controller then adds its own
--  velocity on top of ours every physics step. Left alone, the two fight: the
--  boost gets damped and the movement stutters.
--
--  While the boost is on we therefore take the game's own contribution out of
--  the picture by pinning WalkSpeed to 0, so the ONLY horizontal force is the
--  one we apply. That makes the boost predictable instead of fighting itself.
--
--  The ceiling still has to be derived from the character's REAL WalkSpeed, so
--  that value is cached BEFORE it is zeroed. While the lock is on, the cache
--  follows the game's live value on its change signals, which keeps sprint
--  changes (the game adds RunSpeed) reflected without letting our zeroing win.
--================================================================
speedBaseWalk = nil;   -- last real WalkSpeed the game asked for
speedLockOn = false;  -- are we currently pinning WalkSpeed to 0

local function rememberBaseWalk(hum)
    local v = hum.WalkSpeed;
    if type(v) == "number" and v > 0 then
        -- only remembered while we are NOT holding it at 0, otherwise our own
        -- zero would become the "real" speed and the ratio ceiling would collapse
        if not speedLockOn then
            speedBaseWalk = v;
        end;
        return speedBaseWalk or v;
    end;
    -- the game can legitimately report 0 (seated / dead); fall back to the last
    -- known good value so the boost still has a sane ceiling
    return speedBaseWalk or 16;
end

local function setSpeedLock(hum, on)
    if on then
        if not speedLockOn then
            local v = hum.WalkSpeed;
            speedBaseWalk = (type(v) == "number" and v > 0) and v or (speedBaseWalk or 16);
            speedLockOn = true;
        end;
        if hum.WalkSpeed ~= 0 then
            pcall(function() hum.WalkSpeed = 0; end);
        end;
    elseif speedLockOn then
        speedLockOn = false;
        if type(speedBaseWalk) == "number" and speedBaseWalk > 0 then
            pcall(function() hum.WalkSpeed = speedBaseWalk; end);
        end;
    end;
end

-- The game's Movement module rewrites WalkSpeed whenever the sprint state flips
-- (WalkSpeed + RunSpeed). applySpeedBoost already calls setSpeedLock on every
-- frame, which re-asserts the 0 the moment the game writes over it, so no extra
-- listener is needed here.

-- linear ramp with a rate, so a change of direction or a release eases instead
-- of snapping (the previous formula only ramped UP, never back down)
local function rampToward(cur, goal, rate, dt)
    local diff = goal - cur;
    local step = rate * dt;
    if diff > step then return cur + step; end;
    if diff < -step then return cur - step; end;
    return goal;
end

-- SPEED BOOST
-- CFrame only: the RootPart is nudged along the move direction every frame. The
-- boost ramps up and back down rather than snapping to full speed, which removes
-- the position spikes that look most like cheating.
speedRamp = 0;  -- current boosted speed, ramped in / out

function applySpeedBoost(dt)
    dt = dt or 0;
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local hrp = char and char:FindFirstChild("HumanoidRootPart");

    if not getgenv().wh_speed_on then
        -- hand movement back to the game
        speedRamp = 0;
        if hum then
            rememberBaseWalk(hum);
            setSpeedLock(hum, false);
        end;
        return;
    end;
    if not (hum and hrp) then return; end;

    -- a seated character must not be boosted, and a dead one has no state to move
    if hum.Sit or hum.Health <= 0 then
        speedRamp = 0;
        return;
    end;

    local base = rememberBaseWalk(hum);
    -- stop the game from moving us ourselves, now that the real base is cached
    setSpeedLock(hum, true);

    local dir = hum.MoveDirection; -- already world space / camera relative
    local method = getgenv().wh_speed_method or "Velocity";
    local target = getgenv().wh_speed or 45;
    local accel = math.max(getgenv().wh_speed_accel or 8, 0.5);
    -- never aim for more than a multiple of the character's REAL WalkSpeed (the
    -- cached base, not the 0 we just pinned), scaled down if the server has been
    -- correcting us
    -- The WalkSpeed-ratio ceiling is a SAFETY cap for the velocity method, which
    -- directly and have no such limit, so clamping them to (WalkSpeed x ratio)
    -- made the Boost Speed slider a no-op: with WalkSpeed 16 and ratio 2 the
    -- ceiling was always 32 st/s no matter what the slider said.
    -- value directly.
    -- The CFrame boost reads the Boost Speed slider directly, so the
    -- number the user sets is the number they get.
    -- A separate hard ceiling in studs/s is available via wh_speed_cap.
    -- (0 = no limit). Previously it was base WalkSpeed x a multiplier, which
    -- silently capped Velocity to about 32 st/s regardless of the slider.
    local cap = getgenv().wh_speed_cap or 0;
    if type(cap) == "number" and cap > 0 and target > cap then target = cap; end;
    if target < 0 then target = 0; end;

    local moving = dir.Magnitude > 0.05;
    if not moving then
    end;

    -- ramp toward the target while a key is held, and bleed back to 0 when it is
    -- released, so letting go actually stops the boost instead of sliding on
    local goal = moving and target or 0;
    local rate = (moving and target or math.max(speedRamp, 1)) * accel;
    speedRamp = rampToward(speedRamp, goal, rate, dt);

    -- CFrame only: nudge the RootPart along the move direction every frame.
    -- dir.Unit is only safe once a real direction exists, otherwise the boost
    -- would fling the character in an arbitrary direction while standing still.
    if not moving then return; end;
    local step = speedRamp * dt;
    pcall(function() hrp.CFrame = hrp.CFrame + dir.Unit * step; end);
end

-- JUMP HACK: on take-off, replace the upward velocity with our own. Roblox jumps
-- are velocity driven, so this is what actually raises the jump; the small CFrame
-- nudge guarantees clearance even on a frame where the floor check lags.
local jumpArmed = true;
local function applyJumpBoost()
    if not getgenv().wh_jump or getgenv().wh_fly then
        jumpArmed = true;
        return;
    end;
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if not (hum and hrp) then return; end;
    local state = hum:GetState();
    local grounded = state == Enum.HumanoidStateType.Landed
        or state == Enum.HumanoidStateType.Running
        or hum.FloorMaterial ~= Enum.Material.Air;
    local wants = UIS:IsKeyDown(Enum.KeyCode.Space);
    if wants and grounded and jumpArmed then
        jumpArmed = false;
        local p = getgenv().wh_jump_power or 95;
        local v = hrp.AssemblyLinearVelocity;
        pcall(function()
            hrp.AssemblyLinearVelocity = Vector3.new(v.X, p, v.Z);
            hrp.CFrame = hrp.CFrame + Vector3.new(0, 0.6, 0);
        end);
    elseif grounded and not wants then
        jumpArmed = true; -- re-arm on landing so the next press fires again
    end;
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
-- Manual mode: the compass heading the body is locked to.
--   0 = north (-Z), 90 = east (+X), 180 = south, 270 = west.
manualYawCompass = 0;
MANUAL_YAW_STEP = 45;   -- degrees per arrow press

-- Arrow keys nudge the heading. Only active while Manual mode is selected, and
-- never while the user is typing (gpe), so the chat box is unaffected.
table.insert(Connections, UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return; end;
    if (getgenv().wh_fake_mode or "Custom") ~= "Manual" then return; end;
    if not getgenv().wh_fake_rot then return; end;
    local k = input.KeyCode;
    local d;
    if k == Enum.KeyCode.Up then d = 0;
    elseif k == Enum.KeyCode.Right then d = 90;
    elseif k == Enum.KeyCode.Down then d = 180;
    elseif k == Enum.KeyCode.Left then d = 270;
    else return; end;
    manualYawCompass = (math.floor(manualYawCompass + 0.5) + d) % 360;
end))
local fakeNextRandom = 0;
local fakeRand = { p = 0, y = 0, r = 0 };
local fakeJitterYaw = 0;
local fakeNextJitter = 0;
jitter2Side = 1;      -- Jitter2: which side of the view the body is on (+1 / -1)

local function fakeAngles(dt)
    local mode = getgenv().wh_fake_mode or "Custom";
    if mode == "Manual" then
        -- Manual builds its own world-aligned base frame further down, so the
        -- yaw offset here is zero: the heading is already baked into the base.
        return 0, 0, 0;
    end;
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
    if mode == "Jitter2" then
        -- Flips the body between the two SIDES of wherever the camera is looking.
        -- The base frame used downstream already faces the camera, so a yaw of
        -- +90 or -90 puts the body a right angle to it - east on one tick, west
        -- on the next - and the pair follows the camera as you turn.
        local now = os.clock();
        if now >= fakeNextJitter then
            fakeNextJitter = now + math.max(getgenv().wh_jitter_interval or 0.15, 0.02);
            jitter2Side = -jitter2Side;
        end;
        return 0, jitter2Side * 90, 0;
    end;
    if mode == "Jitter" then
        -- pitch/roll come from the sliders, but yaw is re-rolled every interval so
        -- the body keeps snapping to a new facing
        local now = os.clock();
        if now >= fakeNextJitter then
            fakeNextJitter = now + math.max(getgenv().wh_jitter_interval or 0.15, 0.02);
            fakeJitterYaw = math.random(-180, 180);
        end;
        return getgenv().wh_fake_pitch or 0, fakeJitterYaw, getgenv().wh_fake_roll or 0;
    end;
    return getgenv().wh_fake_pitch or 0, getgenv().wh_fake_yaw or 0, getgenv().wh_fake_roll or 0;
end

local function applyFakeRotation(dt)
    if not fakeRotationActive() then return; end;
    -- SafeShoot: for a moment after a round leaves the barrel, drop the override
    -- and let the body face naturally. A rotated body swings the muzzle ray back
    -- through our own hitbox, which is what makes shots land on us.
    if getgenv().wh_safeshoot and (os.clock() - lastShotAt) < (getgenv().wh_safeshoot_time or 0.3) then
        local c0 = plr.Character;
        local h0 = c0 and c0:FindFirstChildOfClass("Humanoid");
        local r0 = c0 and c0:FindFirstChild("HumanoidRootPart");
        if h0 and r0 and cam then
            -- snap the body straight to a natural facing INSTANTLY rather than
            -- letting AutoRotate ease it back, which would leave you mid-turn
            -- while the round is in the air
            h0.AutoRotate = false;
            local pos0 = r0.CFrame.Position;
            local look0 = cam.CFrame.LookVector;
            local flat0 = Vector3.new(look0.X, 0, look0.Z);
            if flat0.Magnitude > 0.001 then
                pcall(function() r0.CFrame = CFrame.lookAt(pos0, pos0 + flat0.Unit); end);
            end;
        end;
        return;
    end;
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if not (hum and hrp) then return; end;
    hum.AutoRotate = false;
    local pos = hrp.CFrame.Position;
    -- base facing: normally where the camera looks, but "target based" aims the
    -- body at whatever silent aim is locked onto. Combine that with a yaw of 180
    -- and you are visibly turned AWAY from the enemy you are shooting at.
    local mode = getgenv().wh_fake_mode or "Custom";
    local base;
    if mode == "Manual" then
        -- ignore the camera entirely: build the frame straight from the chosen
        -- compass heading. CFrame.lookAt uses -Z as its forward axis, so a yaw of
        -- 0 already faces north and +90 turns to face east.
        -- CFrame.Angles rotates CLOCKWISE about +Y as seen from above, so a
        -- positive yaw of 90 points at WEST, not east. The compass value is
        -- therefore negated so 90 really means east.
        local rad = -math.rad(manualYawCompass);
        base = CFrame.new(pos) * CFrame.Angles(0, rad, 0);
    else
        local flat;
        if getgenv().wh_fake_target_based and last.part then
            local to = last.part.Position - pos;
            flat = Vector3.new(to.X, 0, to.Z);
        else
            local look = cam.CFrame.LookVector;
            flat = Vector3.new(look.X, 0, look.Z);
        end;
        if flat.Magnitude < 0.001 then return; end;
        base = CFrame.lookAt(pos, pos + flat.Unit);
    end;
    local fp, fy, fr = fakeAngles(dt);
    -- Manual already encodes its heading in the base frame, so it must not be
    -- offset again here.
    local off = mode == "Manual" and CFrame.new()
        or CFrame.Angles(math.rad(fp), math.rad(fy), math.rad(fr));
    pcall(function() hrp.CFrame = base * off; end);
end
--================================================================
--  EXTENDED TOOL / INTERACTION RANGE
--
--  Every ProximityPrompt in this place ships with MaxActivationDistance = 8
--  studs, so nothing can be looted, harvested or opened from further away.
--  The game's PromptHandler reads that property to decide whether to show and
--  accept a prompt, so raising it is what actually extends reach.
--
--  Three things this had to get right:
--    * the cache table must be the one declared below. It previously read a
--      leftover name from a removed feature, which indexed nil and threw on
--      every prompt, every call - the feature simply never worked.
--    * prompts are cached in a list instead of walking all ~100k descendants
--      once a second, which was enough to stutter.
--    * reach is only ever pushed OUT. Forcing every prompt to one exact value
--      shrank the ones the game gave a longer range (vaults, doors) and broke
--      them.
--================================================================
reachOriginals = setmetatable({}, { __mode = "k" });
reachList = {};
reachLastSweep = 0;
REACH_SWEEP_INTERVAL = 1;

function patchReach(prompt)
    if reachOriginals[prompt] == nil then
        pcall(function()
            reachOriginals[prompt] = prompt.MaxActivationDistance;
        end);
    end;
    local want = getgenv().wh_reach_distance or 40;
    pcall(function()
        if prompt.MaxActivationDistance < want then
            prompt.MaxActivationDistance = want;
        end;
    end);
end

function restoreReach()
    for prompt, dist in next, reachOriginals do
        if prompt and prompt.Parent then
            pcall(function() prompt.MaxActivationDistance = dist; end);
        end;
    end;
    table.clear(reachOriginals);
    table.clear(reachList);
end

function applyReach()
    if not getgenv().wh_reach_on then
        restoreReach(); -- idempotent
        return;
    end;
    local now = os.clock();
    if reachLastSweep and (now - reachLastSweep) < REACH_SWEEP_INTERVAL then return; end;
    reachLastSweep = now;
    -- prune dead entries and re-assert, so a prompt that had its distance
    -- written back by the game is corrected again
    for i = #reachList, 1, -1 do
        local p = reachList[i];
        if p and p.Parent then
            patchReach(p);
        else
            table.remove(reachList, i);
        end;
    end;
    -- seed once; later arrivals come through DescendantAdded
    if #reachList == 0 then
        pcall(function()
            for _, inst in next, Workspace:GetDescendants() do
                if inst:IsA("ProximityPrompt") then
                    reachOriginals[inst] = inst.MaxActivationDistance;
                    table.insert(reachList, inst);
                end;
            end;
        end);
    end;
end

table.insert(Connections, Workspace.DescendantAdded:Connect(function(inst)
    if Running and getgenv().wh_reach_on then
        if inst:IsA("ProximityPrompt") then
            table.insert(reachList, inst);
            patchReach(inst);
        elseif inst:IsA("BasePart") then
            pcall(function()
                for _, child in next, inst:GetChildren() do
                    if child:IsA("ProximityPrompt") then
                        table.insert(reachList, child);
                        patchReach(child);
                    end;
                end;
            end);
        end;
    end;
end));

--================================================================
--  RESPAWN AT DEATH LOCATION
--
--  The game has no client-side respawn: Died only raises the DeathScreen UI and
--  the actual respawn (including the move to a SpawnLocation) happens on the
--  server. So this cannot stop the spawn - it records where you died and moves
--  you back afterwards. The move is RETRIED for a few seconds because the server
--  places the character after CharacterAdded fires, so a single attempt loses
--  that race and the server simply puts us back on the spawn.
--================================================================
deathSpot = nil;

-- Move the character to a CFrame, re-asserting it for a while so it wins the
-- race against the server's own spawn placement. Stops as soon as we are there.
function moveToCFrame(target, tries, interval)
    tries = tries or 40;
    interval = interval or 0.1;
    task.spawn(function()
        for _ = 1, tries do
            if not Running then return; end;
            local c = plr.Character;
            local hum = c and c:FindFirstChildOfClass("Humanoid");
            local root = c and c:FindFirstChild("HumanoidRootPart");
            if hum and root and hum.Health > 0 then
                if (root.CFrame.Position - target.Position).Magnitude < 4 then
                    return; -- arrived
                end;
                pcall(function() root.CFrame = target; end);
            end;
            task.wait(interval);
        end;
    end);
end


function recordDeathSpot()
    local char = plr.Character;
    local hrp = char and char:FindFirstChild("HumanoidRootPart");
    if not hrp then return; end;
    deathSpot = hrp.CFrame;
end

--================================================================
--  AUTO EQUIP DEFAULT LOADOUT  +  INSTANT RESPAWN
--
--  The game already owns a "starter kit" request, and it is a RemoteFunction:
--      ReplicatedStorage.Events.EventsFunction.AttemptStarterKit:InvokeServer("Default")
--  confirmed in the place (AttemptStarterKit is listed under EventsFunction as a
--  RemoteFunction, alongside AttemptSpawn / RequestAmmo).
--
--  So there is no need to clone tools client side at all - the server hands back
--  the default kit itself. This just fires that request when you die.
--
--  Instant spawn: Player.RespawnTime is server owned and cannot be lowered from
--  here. Calling LoadCharacter ourselves once the death registers respawns
--  immediately instead of waiting out the server's timer.
--================================================================
function requestDefaultLoadout()
    local ok, rf = pcall(function()
        return RS.Events.EventsFunction:WaitForChild("AttemptStarterKit", 10);
    end);
    if not ok or not rf or not rf:IsA("RemoteFunction") then return false; end;
    local fired = pcall(function() rf:InvokeServer("Default"); end);
    return fired;
end

function onDeathAutoRespawn()
    if not getgenv().wh_autoloadout then return; end;
    -- let the death register before respawning, so we do not fight the sequence
    task.delay(0.35, function()
        if not Running then return; end;
        if getgenv().wh_autoloadout then pcall(function() plr:LoadCharacter(); end); end;
    end);
    -- the server needs the new character up before it can grant the kit
    task.spawn(function()
        for _ = 1, 60 do
            if not Running then return; end;
            if not getgenv().wh_autoloadout then return; end;
            local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid");
            if hum and hum.Health > 0 then
                if requestDefaultLoadout() then return; end;
            end;
            task.wait(0.1);
        end;
    end);
end

-- Wire death up. This has to be attached to EVERY character, because the game
-- respawns by creating a new one; missing this is why the feature looked dead.
table.insert(Connections, plr.CharacterAdded:Connect(function(char)
    local hum = char:WaitForChild("Humanoid", 15);
    if not hum then return; end;
    hum.Died:Connect(function()
        -- remember where we died BEFORE anything else moves us
        recordDeathSpot();
        -- instant respawn + default loadout
        onDeathAutoRespawn();
    end);
    -- if we died before this handler ran, go back now
    if getgenv().wh_respawn_death and deathSpot then
        local target = deathSpot;
        deathSpot = nil;
        task.defer(function() moveToCFrame(target, 40, 0.1); end);
    end;
end));

--================================================================
--  AUTO RELOAD
--
--  BehaviourGunClient reloads an empty magazine with exactly this message:
--      ReplicatedStorage.Events.EventsReplication.CommunicateGun:FireServer("Reload")
--  (seen in the gun client where it handles the out-of-ammo case). Sending the
--  same message is what makes the server perform the reload, so the animation,
--  ammo and cooldown all stay the game's own.
--
--  One reload is fired per magazine: the flag is latched when the count reaches
--  zero and only cleared once the magazine is actually refilled, so holding fire
--  on an empty gun cannot spam the remote.
--================================================================

-- Find the tool whose magazine we should watch.
--
-- getEquippedTool only accepts an IsA("Tool") or a Model tagged "Tool". That
-- matches how the game's own BehaviourGunClient picks the tool, but if either
-- check misses (a Model without the tag yet, a nested holder, the attribute
-- being set on something else) the reload silently never fires. So this falls
-- back to a plain scan for anything actually carrying the ammo attribute, which
-- is what the value is ultimately read from.
function findAmmoTool()
    local char = plr.Character;
    if not char then return nil; end;
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("Tool") or (c:IsA("Model") and c:HasTag("Tool")) then
            if c:GetAttribute("State_Ammo_Client") ~= nil then return c; end;
            return c;
        end;
    end;
    for _, d in ipairs(char:GetDescendants()) do
        if d:GetAttribute("State_Ammo_Client") ~= nil then return d; end;
    end;
    return nil;
end

-- Current magazine count, or nil when it cannot be read. Kept in one place so
-- the reload logic and the on-screen readout can never disagree.
function currentAmmo()
    local tool = findAmmoTool();
    if not tool then return nil, nil; end;
    local v = tool:GetAttribute("State_Ammo_Client");
    if type(v) ~= "number" then return nil, tool; end;
    return v, tool;
end


--================================================================
--  WEATHER
--
--  The game's Weather module (Modules/Client/ModulesPre/ClientScripts_Visual)
--  reads the current weather from an ATTRIBUTE on the Lighting service:
--      local Weather = Lighting:GetAttribute("Weather")
--  It re-reads it every RenderStepped AND listens on
--  Lighting:GetAttributeChangedSignal("Weather"), so writing the attribute is
--  all that is needed - the module then applies the matching config on its own
--  (Day/Night blending, Atmosphere density, rain and thunder particles).
--
--  The four values it branches on, read straight out of that module:
--      "Clear" | "Rain" | "LightningStorm" | "BloodMoon"
--
--  "Off" leaves the attribute untouched so the server's own weather applies.
--================================================================
WEATHER_VALUES = { "Off", "Clear", "Rain", "LightningStorm", "BloodMoon" };

function setWeather()
    local want = getgenv().wh_weather or "Off";
    if want == "Off" then return; end;
    pcall(function()
        local cur = Lighting:GetAttribute("Weather");
        -- only write on a real change, otherwise we would fight the server's own
        -- weather updates every single frame
        if cur ~= want then
            Lighting:SetAttribute("Weather", want);
        end;
    end);
end

function restoreWeather()
    -- hand the attribute back to the server by clearing our value
    pcall(function() Lighting:SetAttribute("Weather", nil); end);
end

--================================================================
--  LOG INFO  +  GUN INFO
--
--  Log info raises a Library toast for three things:
--    * a player leaving the server (Players.PlayerRemoving)
--    * you starting a reload (the held tool's State_Reloading flipping on)
--    * a player entering or leaving the nearby radius
--  The nearby check runs once a second and only announces when the SET of nearby
--  players changes, so it does not spam while you walk around.
--
--  Gun info draws one line of screen text under the FOV circle with the live
--  stats of the weapon in your hands.
--================================================================
nearSeen = {};
logInfoTickAt = 0;
wasReloading = false;
gunInfoText = nil;

function logInfoSay(text)
    pcall(function() Library:Notify(text, 5); end);
end

table.insert(Connections, Players.PlayerRemoving:Connect(function(p)
    if not getgenv().wh_log_leave then return; end;
    if p == plr then return; end;
    logInfoSay(("%s left the server"):format(p.DisplayName or p.Name));
end));

function updateNearby()
    local range = getgenv().wh_log_near_m or 100;
    local me = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart");
    if not me then return; end;
    local here = {};
    if getgenv().wh_log_near then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= plr and p.Character then
                local h = p.Character:FindFirstChildOfClass("Humanoid");
                local r = p.Character:FindFirstChild("HumanoidRootPart");
                if h and r and h.Health > 0
                    and (r.Position - me.Position).Magnitude <= range then
                    here[p] = true;
                end;
            end;
        end;
    end;
    for p in pairs(here) do
        if not nearSeen[p] then
            logInfoSay(("%s is within %d m"):format(p.DisplayName or p.Name, range));
        end;
    end;
    for p in pairs(nearSeen) do
        if not here[p] then
            logInfoSay(("%s moved out of range"):format(p.DisplayName or p.Name));
        end;
    end;
    nearSeen = here;
end

function applyLogInfo()
    local now = os.clock();
    if now < logInfoTickAt then return; end;
    logInfoTickAt = now + 1;
    updateNearby();
    if getgenv().wh_log_reload then
        local tool = getEquippedTool();
        local reloading = tool and tool:GetAttribute("State_Reloading") == true;
        if reloading and not wasReloading and tool then
            logInfoSay(("%s is reloading"):format(tool.Name));
        end;
        wasReloading = reloading or false;
    end;
end

-- A point 100 studs in front of the camera, so the line sits under the FOV circle.
function gunInfoAnchor()
    if not cam then return nil; end;
    return cam.CFrame.Position + cam.CFrame.LookVector * 100;
end

function applyGunInfo()
    if not getgenv().wh_gun_info then
        if gunInfoText then gunInfoText.Visible = false; end;
        return;
    end;
    local tool = getEquippedTool();
    local anchor = gunInfoAnchor();
    if not tool or not anchor then
        if gunInfoText then gunInfoText.Visible = false; end;
        return;
    end;
    local cfg = liveConfigs[tool];
    local ammo = tool:GetAttribute("State_Ammo_Client");
    local mode = tostring(tool:GetAttribute("State_Firemode") or "?");
    local dmg = "-";
    if cfg and type(cfg.ProjectileDamage) == "table" then
        dmg = cfg.ProjectileDamage.Head or cfg.ProjectileDamage.Torso
            or cfg.ProjectileDamage[1] or "-";
    end;
    local line = ("%s | %s | %s st | %s rpm | %s dmg | %s/%s"):format(
        tool.Name, mode,
        tostring(cfg and cfg.ProjectileMaxRange or "-"),
        tostring(cfg and cfg.RPM or "-"), tostring(dmg),
        ammo ~= nil and tostring(math.floor(ammo)) or "?",
        tostring(cfg and cfg.AmmoSize or "-"));
    if not gunInfoText and hasDrawing then
        gunInfoText = createObj("Text", {
            Centered = true, Size = 15, Outline = true, Font = 2, Visible = false,
            TextColor3 = Color3.fromRGB(235, 235, 240),
            TextStrokeTransparency = 0.35,
        });
    end;
    if not gunInfoText then return; end;
    gunInfoText.Text = line;
    local vp, onScreen = cam:WorldToViewportPoint(anchor);
    if onScreen and vp.Z > 0 then
        gunInfoText.Position = Vector2.new(vp.X, vp.Y + 6);
        gunInfoText.Visible = true;
    else
        gunInfoText.Visible = false;
    end;
end

--================================================================
--  ONE TAP ANIMS
--
--  Makes every animation (reload, jump, fire, tool swings) look like it is
--  running at a low framerate - around 15 fps - so each animation advances in
--  visible discrete jumps instead of smoothly.
--
--  How it works: every track the Animator is playing is PAUSED and its
--  TimePosition is advanced by hand, one step of 1/fps at a time. Pausing first
--  matters - a playing track advances on its own, so its position would drift
--  between our writes and the motion would still look smooth.
--
--  Tracks are released and set back to playing when the toggle goes off, and on
--  teardown, so animations are never left frozen.
--================================================================
onetapPaused = setmetatable({}, { __mode = "k" });
onetapAcc = 0;

function releaseOnetap()
    for track in pairs(onetapPaused) do
        if track.Parent then
            pcall(function()
                track.TimePosition = track.TimePosition;
                track.PlaybackSpeed = track.PlaybackSpeed;
                track:Play(track.TimePosition);
            end);
        end;
    end;
    table.clear(onetapPaused);
    onetapAcc = 0;
end

function applyOnetapAnims(dt)
    if not getgenv().wh_onetap_anims then
        if next(onetapPaused) ~= nil then releaseOnetap(); end;
        return;
    end;
    local char = plr.Character;
    local anim = char and char:FindFirstChildOfClass("Animator");
    if not anim then return; end;

    local fps = math.clamp(getgenv().wh_onetap_fps or 15, 1, 60);
    local step = 1 / fps;
    onetapAcc = (onetapAcc or 0) + (dt or 0);
    if onetapAcc < step then return; end;
    -- discard the overshoot so the choppiness does not drift over time
    onetapAcc = onetapAcc % step;

    local ok, tracks = pcall(function() return anim:GetPlayingAnimationTracks(); end);
    if not ok or type(tracks) ~= "table" then return; end;
    for _, track in ipairs(tracks) do
        -- looped animations must stay looping, everything else plays once
        if not onetapPaused[track] then
            onetapPaused[track] = true;
            pcall(function() track:Pause(); end);
        end;
        pcall(function() track.TimePosition = track.TimePosition + step; end);
    end;
end

--================================================================
--  FAKE ROTATION: WEAPON-ONLY
--
--  Weapons and melee tools are told apart by the same marker the game itself
--  uses: BehaviourGunClient keys everything off the "State_Firemode" attribute
--  (FiremodeEnvConstructors are loaded from it), while melee tools like the
--  pickaxe and axe run BehaviourMeleeClient and never set it.
--
--  Rotating the body while swinging a pickaxe looks wrong and desyncs the swing
--  animation from the arm, so with "weapons only" on the rotation is suspended
--  automatically whenever a non-weapon tool is held, and comes straight back when
--  a weapon (or nothing) is held again. The toggle in the menu is left exactly as
--  the user set it - only the applied state changes.
--================================================================
function holdingWeapon()
    local tool = getEquippedTool();
    if not tool then return false; end;
    -- a fire mode is the defining marker of a gun; melee tools have none
    local fm = tool:GetAttribute("State_Firemode");
    if type(fm) == "string" and fm ~= "" then return true; end;
    -- fall back to the config name if the attribute has not replicated yet
    local name = string.lower(tostring(gunName(tool) or ""));
    local WEAPON_WORDS = {
        ak47 = true, ak76 = true, m16 = true, m4 = true, rpk = true, sks = true,
        m1911 = true, glock = true, n99 = true, revolver = true, rpg = true,
        shotgun = true, sawn = true, spas12 = true, aa12 = true, p90 = true,
        tommy = true, uzi = true, ppsh = true, ssmg = true, xm112 = true,
        crossbow = true, musket = true, hunting = true, cycler = true,
        pump = true, rifle = true, gun = true, pistol = true,
    };
    for key in pairs(WEAPON_WORDS) do
        if string.find(name, key, 1, true) then return true; end;
    end;
    return false;
end

-- The value the rest of the script should trust.
function fakeRotationActive()
    if not getgenv().wh_fake_rot then return false; end;
    if getgenv().wh_fake_rot_weapon_only == false then return true; end;
    -- empty handed counts as "no tool in the way"
    local tool = getEquippedTool();
    if not tool then return true; end;
    return holdingWeapon();
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
-- The game's Weather module runs an UpdateTime loop that writes
-- Lighting.ClockTime every frame and tweens Brightness / Ambient /
-- OutdoorAmbient whenever the weather changes. So setting those properties once
-- was pointless: the next frame the game put its own value straight back, which
-- is why ambient and the time changer appeared to do nothing.
--
-- setmetatable lets us refuse writes while a control is enabled, so our value
-- is the one that survives. The original setter is kept and used when the toggle
-- is off (or by the game itself) so nothing is permanently broken.
lightLocks = {};

function installLightLock()
    if lightLocks.__installed then return; end;
    lightLocks.__installed = true;
    pcall(function()
        local mt = getmetatable(Lighting) or {};
        local index = mt.__index;
        if type(index) ~= "function" then index = function(_, k) return rawget(Lighting, k); end; end;
        mt.__index = function(self, key)
            local lock = lightLocks[key];
            if lock and lock.value ~= nil then return lock.value; end;
            return index(self, key);
        end;
        mt.__newindex = function(self, key, value)
            local lock = lightLocks[key];
            if lock and lock.held then
                -- the game is writing while we hold this control: ignore it
                lock.value = value;
                return;
            end;
            rawset(self, key, value);
        end;
        setmetatable(Lighting, mt);
    end);
end

function holdLight(key, value)
    installLightLock();
    local lock = lightLocks[key];
    if not lock then
        lock = { value = nil, held = false, orig = nil };
        pcall(function() lock.orig = Lighting[key]; end);
        lightLocks[key] = lock;
    end;
    lock.value = value;
    lock.held = true;
    pcall(function() rawset(Lighting, key, value); end);
end

function releaseLight(key)
    local lock = lightLocks[key];
    if not lock then return; end;
    lock.held = false;
    lock.value = nil;
    if lock.orig ~= nil then
        pcall(function() rawset(Lighting, key, lock.orig); end);
    end;
end

function setLight(key, value)
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
    for key in pairs(lightLocks) do
        if key ~= "__installed" then releaseLight(key); end;
    end;
    for k in next, touched do
        local v = lightOriginals[k];
        if v ~= nil then pcall(function() Lighting[k] = v; end); end;
    end;
    table.clear(lightOriginals);
    table.clear(touched);
end

local atmoDensity; -- original Atmosphere density
-- Lighting.Ambient / Brightness are easy to set but barely visible under a bright
-- daytime sky, so the same controls also drive real post effects on the camera,
-- which always show.


--================================================================
--  FULLBRIGHT
--
--  Ported from additional/fullbright.lua, which is the version that actually
--  works on this game.
--
--  The game's Weather module rewrites Lighting every frame from its own
--  Day/Night configs, so any value simply assigned gets stomped on before it is
--  ever drawn. The fix is to watch the properties instead of fighting them on a
--  timer: every time the game CHANGES one, the change signal fires and the
--  values are re-applied immediately.
--
--  That is event driven, so it costs nothing per frame, and it wins the race every
--  time rather than sometimes. Brightness is 2 rather than 3 to match the place's
--  own value and avoid blowing out the image, and FogEnd is pushed out at the
--  same time so the scene reads clearly.
--================================================================
fbConns = {};
fbOriginals = nil;

local FB_PROPS = { "Ambient", "OutdoorAmbient", "Brightness", "FogEnd", "GlobalShadows" };

function fbEnforce()
    Lighting.Ambient = Color3.fromRGB(255, 255, 255);
    Lighting.OutdoorAmbient = Color3.fromRGB(255, 255, 255);
    Lighting.Brightness = 2;
    Lighting.FogEnd = 1e10;
    Lighting.GlobalShadows = false;
end

function fbDisconnect()
    for _, c in ipairs(fbConns) do pcall(function() c:Disconnect(); end); end;
    table.clear(fbConns);
end

function fbRestore()
    fbDisconnect();
    if not fbOriginals then return; end;
    pcall(function() Lighting.Ambient = fbOriginals.Ambient; end);
    pcall(function() Lighting.OutdoorAmbient = fbOriginals.OutdoorAmbient; end);
    pcall(function() Lighting.Brightness = fbOriginals.Brightness; end);
    pcall(function() Lighting.FogEnd = fbOriginals.FogEnd; end);
    pcall(function() Lighting.GlobalShadows = fbOriginals.GlobalShadows; end);
    fbOriginals = nil;
end

function applyFullbright()
    if not getgenv().wh_fullbright then
        fbRestore(); -- idempotent
        return;
    end;
    -- already installed: the signals themselves keep re-applying
    if #fbConns > 0 then return; end;
    pcall(function()
        fbOriginals = {
            Ambient = Lighting.Ambient,
            OutdoorAmbient = Lighting.OutdoorAmbient,
            Brightness = Lighting.Brightness,
            FogEnd = Lighting.FogEnd,
            GlobalShadows = Lighting.GlobalShadows,
        };
    end);
    fbEnforce();
    for _, prop in ipairs(FB_PROPS) do
        pcall(function()
            table.insert(fbConns,
                Lighting:GetPropertyChangedSignal(prop):Connect(fbEnforce));
        end);
    end;
end

function applyLighting()
    -- No Fog
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

    -- No Grass.
    --
    -- Taken from additional/onlyvisual.lua, which is the working reference for
    -- this game. Grass here is terrain DECORATION, not a set of Parts, and the
    -- switch is:
    --     sethiddenproperty(Terrain, "Decoration", false)
    -- The previous attempt wrote GrassHeight / GrassLength (which do nothing in
    -- this place) and also walked every descendant in Workspace each frame, which
    -- is what cost the 30 fps.
    if getgenv().wh_nograss then
        local terr = Workspace:FindFirstChildOfClass("Terrain");
        if terr then
            if type(sethiddenproperty) == "function" then
                pcall(sethiddenproperty, terr, "Decoration", false);
            end;
            pcall(function() terr.Decoration = false; end);
        end;
        local grassObj = Workspace:FindFirstChild("Grass");
        if grassObj then
            pcall(function() grassObj.GrassHeight = 0; end);
            pcall(function() grassObj.GrassSize = 0; end);
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
--  FALL DAMAGE REMOVAL
--
--  Ragdoll.lua polls GameConfiguration.MovementSettings.FallHeight (85 studs)
--  every Heartbeat:
--      Y >= FallHeight  -> plays the landing / wind sound
--      Y < -FallHeight  -> Humanoid:ChangeState(Ragdoll), GettingUp disabled
--  Raising the threshold out of reach disables both; clearing the ragdoll flags
--  stops a server-driven ragdoll; clamping downward velocity means a landing is
--  never hard in the first place.
--================================================================
fallCfgOriginal = nil;
fallOriginalsDone = false;

function captureFallConfig()
    if fallOriginalsDone then return; end;
    pcall(function()
        local cfg = require(findModuleByName("GameConfiguration"));
        if type(cfg) == "table" and type(cfg.MovementSettings) == "table" then
            fallCfgOriginal = cfg.MovementSettings.FallHeight;
            fallOriginalsDone = true;
        end;
    end);
end

function applyNoFallDamage()
    local on = getgenv().wh_no_fall == true;
    local char = plr.Character;
    local hum = char and char:FindFirstChildOfClass("Humanoid");
    local hrp = char and char:FindFirstChild("HumanoidRootPart");

    if on then
        captureFallConfig();
        pcall(function()
            local cfg = require(findModuleByName("GameConfiguration"));
            if type(cfg) == "table" and type(cfg.MovementSettings) == "table"
                and cfg.MovementSettings.FallHeight ~= 1e9 then
                cfg.MovementSettings.FallHeight = 1e9;
            end;
        end);
    elseif fallOriginalsDone then
        pcall(function()
            local cfg = require(findModuleByName("GameConfiguration"));
            if type(cfg) == "table" and type(cfg.MovementSettings) == "table"
                and fallCfgOriginal ~= nil then
                cfg.MovementSettings.FallHeight = fallCfgOriginal;
            end;
        end);
    end;

    if not (hum and hrp) then return; end;
    if not on then return; end;

    pcall(function()
        if hum:GetAttribute("IsRagdolled") then hum:SetAttribute("IsRagdolled", false); end;
        if char:GetAttribute("IsRagdolled_Client") then
            char:SetAttribute("IsRagdolled_Client", false);
        end;
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running); end);
    end);
    local v = hrp.AssemblyLinearVelocity;
    local limit = -(getgenv().wh_fall_speed or 60);
    if v.Y < limit then
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
    o.item = createObj("Text", { Size = 12, Center = true, Outline = true,
        OutlineColor = Color3.new(0, 0, 0), Visible = false, ZIndex = 3 });
    o.loot = createObj("Text", { Size = 11, Center = true, Outline = true,
        OutlineColor = Color3.new(0, 0, 0), Visible = false, ZIndex = 3 });
    return o;
end

local function freeEsp(o)
    for _, l in ipairs(o.lines) do if l then pcall(function() l:Remove(); end); end; end;
    for _, k in ipairs({ "name", "dist", "item", "loot", "hpBg", "hp" }) do
        if o[k] then pcall(function() o[k]:Remove(); end); end;
    end;
end

local function hideEsp(o)
    for _, l in ipairs(o.lines) do if l then l.Visible = false; end; end;
    for _, k in ipairs({ "name", "dist", "item", "hpBg", "hp" }) do
        if o[k] then o[k].Visible = false; end;
    end;
end

-- the item a player is visibly carrying: their equipped Tool (named by its
-- ItemConfig attribute when the game sets one), falling back to any child that
-- advertises ItemConfig
local function equippedItemName(model)
    for _, c in ipairs(model:GetChildren()) do
        if c:IsA("Tool") then
            local cfg = c:GetAttribute("ItemConfig");
            if type(cfg) == "string" and cfg ~= "" then return cfg; end;
            return c.Name;
        end;
    end;
    for _, c in ipairs(model:GetChildren()) do
        local cfg = c:GetAttribute("ItemConfig");
        if type(cfg) == "string" and cfg ~= "" then return cfg; end;
    end;
    return nil;
end

-- Body parts are ignored; anything else on the character that carries an
-- ItemConfig attribute, or whose name looks like gear (the game welds helmets,
-- armour and backpacks onto the model: "ArmorWeld" / "HatAttachment"), is loot.
local BODY_PARTS = {
    Head = true, HumanoidRootPart = true, Neck = true, Root = true,
    Torso = true, UpperTorso = true, LowerTorso = true,
    ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true,
    LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
    RightUpperArm = true, RightLowerArm = true, RightHand = true,
    LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
    RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
};
-- Only backpacks: a dead player's belongings are dropped as a bag, so this is
-- the loot line. Gear a living player still wears is NOT listed.
local GEAR_WORDS = { "backpack", "pack" };

local function visibleGear(model)
    local out, seen = {}, {};
    local function push(n)
        if type(n) ~= "string" or n == "" or seen[n] then return; end;
        seen[n] = true;
        out[#out + 1] = n;
    end;
    for _, c in ipairs(model:GetChildren()) do
        local cfg = c:GetAttribute("ItemConfig");
        if c:IsA("Tool") then
            push((type(cfg) == "string" and cfg ~= "") and cfg or c.Name);
        elseif type(cfg) == "string" and cfg ~= "" then
            push(cfg);
        elseif not BODY_PARTS[c.Name] then
            local low = string.lower(c.Name);
            for _, w in ipairs(GEAR_WORDS) do
                if string.find(low, w, 1, true) then
                    push(c.Name);
                    break;
                end;
            end;
        end;
    end;
    return out;
end

local function drawEsp(model, forceColor)
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

    local col = forceColor or espColorFor(model);
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
            o.name.Text = displayNameOf(model);
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

    -- item finder: label the player with what they are holding
    if o.item then
        o.item.Visible = false;
        if getgenv().wh_item_finder then
            local sel = getgenv().wh_item_search;
            if type(sel) == "string" then sel = { [sel] = true }; end;
            if type(sel) ~= "table" then sel = { Any = true }; end;
            local held = equippedItemName(model);
            if held then
                local hl = string.lower(held);
                local show = false;
                -- Linoria Multi gives { ["ItemName"] = true }, but tolerate an
                -- array or a plain string too rather than silently matching none
                for k, v in next, sel do
                    local name = type(k) == "string" and k
                        or (type(v) == "string" and v or nil);
                    if name == "Any" then
                        show = true;
                        break;
                    end;
                    if name and name ~= "" and string.find(hl, string.lower(name), 1, true) then
                        show = true;
                        break;
                    end;
                end;
                if show then
                    o.item.Text = held;
                    o.item.Position = Vector2.new(cx, hy + 16);
                    o.item.Color = getgenv().wh_item_color;
                    o.item.Visible = true;
                end;
            end;
        end;
    end

    -- loot / gear list
    if o.loot then
        o.loot.Visible = false;
        if getgenv().wh_esp_pack then
            local items = visibleGear(model);
            if #items > 0 then
                local cap = math.max(getgenv().wh_esp_pack_max or 3, 1);
                local shown = {};
                for i = 1, math.min(#items, cap) do shown[#shown + 1] = items[i]; end;
                if #items > cap then shown[#shown + 1] = "+" .. (#items - cap); end;
                o.loot.Text = table.concat(shown, ", ");
                o.loot.Position = Vector2.new(cx, hy + ((o.item and o.item.Visible) and 30 or 16));
                o.loot.Color = getgenv().wh_esp_pack_color;
                o.loot.Visible = true;
            end;
        end;
    end
end


--================================================================
--  BACKPACK ESP  (world drops)
--  A dead player's belongings are dropped as Loot.<ItemName>.ProxPart under
--  workspace.Spawned.MouseIgnoreFolder.Loot - it is NOT a child of the body, so
--  this has to scan the world for it. Only backpacks are labelled, and markers
--  are de-duplicated by instance AND position (the folder nests both a wrapper
--  and the item, which used to draw every bag twice).
--================================================================
local packPool = {};

local function backpackFolder()
    local node = Workspace:FindFirstChild("Spawned");
    node = node and node:FindFirstChild("MouseIgnoreFolder");
    node = node and node:FindFirstChild("Loot");
    return node;
end

-- One marker per TOP-LEVEL entry in the Loot folder. The old recursive walk
-- picked up nested duplicates (a bag containing another bag) and drew each of
-- them, which is what made every backpack appear twice.
local function collectPackMarkers(folder)
    local out = {};
    for _, item in ipairs(folder:GetChildren()) do
        local prox = item:FindFirstChild("ProxPart", true);
        if prox and prox:IsA("BasePart") then
            out[#out + 1] = { prox = prox, item = item };
        end;
    end;
    return out;
end

local function newPackObj()
    local o = { lines = {} };
    for i = 1, 4 do
        o.lines[i] = createObj("Line", { Thickness = 1, Visible = false, ZIndex = 2 });
    end;
    o.text = createObj("Text", { Size = 12, Center = true, Outline = true,
        OutlineColor = Color3.new(0, 0, 0), Visible = false, ZIndex = 3 });
    return o;
end

local function hidePack(o)
    for _, l in ipairs(o.lines) do if l then l.Visible = false; end; end;
    if o.text then o.text.Visible = false; end;
end

local function freePack(o)
    for _, l in ipairs(o.lines) do if l then pcall(function() l:Remove(); end); end; end;
    if o.text then pcall(function() o.text:Remove(); end); end;
end

local function updateBackpackEsp()
    if not hasDrawing then return; end;
    local folder = backpackFolder();
    if not getgenv().wh_esp_pack or not folder then
        for _, o in next, packPool do hidePack(o); end;
        return;
    end;
    local col = getgenv().wh_esp_pack_color or Color3.new(1, 1, 0);
    local view = cam.ViewportSize;
    local origin = cam.CFrame.Position;
    local limit = (getgenv().wh_esp_pack_dist or 0) * STUDS_PER_METER;
    local seen = {};
    for _, entry in ipairs(collectPackMarkers(folder)) do
        local prox, item = entry.prox, entry.item;
        local label = (item and item.Name) or "Backpack";
        -- a drop that has been picked up / streamed out is no longer under the
        -- folder, and a destroyed part can report a bogus position - that is what
        -- was drawing bags in the sky and under the world
        if not prox:IsDescendantOf(folder) then continue end;
        local pos = prox.Position;
        if not (isFinite(pos.X) and isFinite(pos.Y) and isFinite(pos.Z)) then continue end;
        if pos.Magnitude > 20000 then continue end;
        if limit > 0 and (pos - origin).Magnitude > limit then continue end;
        if string.find(string.lower(label), "pack", 1, true) then
            local vp = cam:WorldToViewportPoint(pos);
            local s = toScreen(vp);
            local key = item or prox;
            -- Z > 0 means the point is in front of the camera; behind it the
            -- projection mirrors, which drew the box reversed
            if vp.Z > 0 and isFiniteVec2(s) and s.X > -50 and s.Y > -50
                and s.X < view.X + 50 and s.Y < view.Y + 50 then
                seen[key] = true;
                local o = packPool[key];
                if not o then o = newPackObj(); packPool[key] = o; end;
                local x, y, r = s.X, s.Y, 4;
                local pts = {
                    Vector2.new(x - r, y - r), Vector2.new(x + r, y - r),
                    Vector2.new(x + r, y + r), Vector2.new(x - r, y + r),
                };
                for i = 1, 4 do
                    local ln = o.lines[i];
                    if ln then
                        ln.From = pts[i];
                        ln.To = pts[(i % 4) + 1];
                        ln.Color = col;
                        ln.Visible = true;
                    end;
                end;
                if o.text then
                    o.text.Text = label;
                    o.text.Position = Vector2.new(x, y - 10);
                    o.text.Color = col;
                    o.text.Visible = true;
                end;
            else
                local o = packPool[key];
                if o then hidePack(o); end;
            end;
        end;
    end;
    for item, o in next, packPool do
        if not seen[item] or not item.Parent or not item:IsDescendantOf(folder) then
            freePack(o);
            packPool[item] = nil;
        end;
    end;
end

local function updateEsp()
    if not hasDrawing then return; end;
    if not getgenv().wh_esp then
        for _, o in next, espPool do hideEsp(o); end;
        return;
    end;
    local origin = cam.CFrame.Position;
    -- three independent range limits: players, npcs, loot
    local playerStuds = (getgenv().wh_esp_max_dist or 0) * STUDS_PER_METER;
    local npcStuds = (getgenv().wh_esp_npc_dist or 0) * STUDS_PER_METER;
    local seen = {};

    local function consider(model, limit)
        if model == plr.Character then return; end;
        local hum = model:FindFirstChildOfClass("Humanoid");
        if not hum then return; end;
        -- dead bodies are drawn by the corpse pass instead, so the live list stays
        -- clean and the toggle actually controls something
        if hum.Health <= 0 then return; end;
        local root = hum.RootPart or model.PrimaryPart;
        if not root then return; end;
        if limit > 0 and (root.Position - origin).Magnitude > limit then return; end;
        seen[model] = true;
        drawEsp(model);
    end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= plr and p.Character then consider(p.Character, playerStuds); end;
    end;
    if getgenv().wh_esp_npcs then
        for model in next, npcCache do
            if typeof(model) == "Instance" and model.Parent then consider(model, npcStuds); end;
        end;
    end;
    -- corpses: dead players, drawn in their own colour
    if getgenv().wh_esp_corpses then
        for _, p in ipairs(Players:GetPlayers()) do
            local c = p.Character;
            if c and c ~= plr.Character then
                local h = c:FindFirstChildOfClass("Humanoid");
                if h and h.Health <= 0 then
                    local root = h.RootPart or c.PrimaryPart;
                    if root and (playerStuds == 0 or (root.Position - origin).Magnitude <= playerStuds) then
                        seen[c] = true;
                        drawEsp(c, getgenv().wh_esp_corpse_color);
                    end;
                end;
            end;
        end;
    end;
    if getgenv().wh_esp_horses then
        for m in next, horseModels() do
            if npcStuds == 0 or (m:GetPivot().Position - origin).Magnitude <= npcStuds then
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
--  FAKE CAMERA ANGLE
--
--  The game reports our view to the server itself:
--      Events.EventsObserver.CommunicateCamera:FireServer("My CCF", cam.CFrame)
--  PlayerCharacter.lua only does that when the SERVER asks ("Send CCF"), on a
--  0.1s loop, and stops on "Stop Sending CCF".
--
--  The old implementation only wrapped the remote\'s FireServer method. That had
--  two problems:
--    * hookfunction on an Instance method is unreliable - it frequently fails
--      silently, leaving the camera untouched;
--    * the game only ever sends when the server requests it, so the fake angle
--      was sent rarely and the server kept its own view of us most of the time.
--
--  Instead we TALK to the server ourselves on a fixed interval. That needs no
--  hook at all, so it cannot silently fail, and the server always holds the
--  pitched view. Our own camera is never modified - only the value the server
--  is told about.
--
--  Direction is selectable: Down (ground) or Up (sky). Only the CFrame WE send
--  is altered, so the head/viewmodel on our screen stays exactly as it is.
--================================================================
fakeCamRemote = nil;
fakeCamNextAt = 0;
FAKE_CAM_INTERVAL = 0.1;

function getFakeCamRemote()
    if fakeCamRemote and fakeCamRemote.Parent then return fakeCamRemote; end;
    local ok, rem = pcall(function()
        local e = RS:FindFirstChild("Events");
        local obs = e and e:FindFirstChild("EventsObserver");
        return obs and obs:FindFirstChild("CommunicateCamera");
    end);
    if ok and type(rem) == "Instance" then
        fakeCamRemote = rem;
        return rem;
    end;
    return nil;
end

-- The CFrame the server should believe we are looking from.
function fakeCamCFrame()
    if not cam then return nil; end;
    local pitch = getgenv().wh_fake_cam_pitch or 45;
    local dir = (getgenv().wh_fake_cam_dir == "Up") and -1 or 1;
    -- pitch the LOOK direction only; the eye position is left exactly where it
    -- is, so other players still see us in the correct place
    return cam.CFrame * CFrame.Angles(math.rad(pitch) * dir, 0, 0);
end

function applyFakeCam()
    if not getgenv().wh_fake_cam then return; end;
    local rem = getFakeCamRemote();
    if not rem then return; end;
    local now = os.clock();
    if now < fakeCamNextAt then return; end;
    fakeCamNextAt = now + FAKE_CAM_INTERVAL;
    local cf = fakeCamCFrame();
    if not cf then return; end;
    -- exactly the message the game itself sends
    pcall(function() rem:FireServer("My CCF", cf); end);
end

-- Keep the cached remote resolved so the very first toggle works immediately,
-- rather than waiting for the first tick to find it.
task.spawn(function()
    for _ = 1, 30 do
        if not Running then break; end;
        if getFakeCamRemote() then break; end;
        task.wait(0.5);
    end;
end);


--================================================================
--  AIM HUD (Drawing)
--================================================================
local fovCircle = hasDrawing and createObj("Circle", {
    Thickness = getgenv().wh_fov_thickness or 3, NumSides = 64,
    Radius = getgenv().wh_fov_size,
    Filled = false, Visible = false,
}) or nil;

local tracer = hasDrawing and createObj("Line", { Thickness = 1.5, Visible = false }) or nil;


function updateHud(targetPart, dt)
    if not hasDrawing then return; end;
    local center = centerPoint();
    if fovCircle then
        fovCircle.Position = center;
        fovCircle.Radius = getgenv().wh_fov_size or 150;
        fovCircle.Color = getgenv().wh_fov_color;
        fovCircle.Thickness = getgenv().wh_fov_thickness or 3;
        fovCircle.Visible = (getgenv().wh_fov_toggle and getgenv().wh_silent_aim) or false;
    end

    if tracer then
        if getgenv().wh_tracers and targetPart then
            -- point at where we are ACTUALLY aiming (the lead/prediction point),
            -- not the raw body position
            local vp = cam:WorldToViewportPoint(last.pos or targetPart.Position);
            local scr = toScreen(vp);
            local view = cam.ViewportSize;
            local span = (scr - center).Magnitude;
            local maxSpan = (view.X + view.Y) * 1.5;
            -- Z > 0 means the target is in front of the camera. Without this a
            -- point BEHIND the camera projects mirrored, which drew the tracer
            -- shooting off to the wrong side of the screen.
            if vp.Z > 0 and isFiniteVec2(scr) and scr.X > -view.X and scr.X < view.X * 2
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

Library = loadRemote("Library.lua");
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
    Combat = Window:AddTab("Combat"),
    Visuals = Window:AddTab("Visuals"),
    Character = Window:AddTab("Character"),
    Config = Window:AddTab("Config"),
};


--================================================================
--  TAB: AIM
--================================================================
SA = Tabs.Combat:AddLeftGroupbox("Aim");

LOGI = Tabs.Combat:AddLeftGroupbox("Log Info");

LOGI:AddToggle("VSH_LogLeave", {
    Text = "Player Left",
    Default = getgenv().wh_log_leave,
    Tooltip = "Notifies when a player leaves the server",
    Callback = function(v) getgenv().wh_log_leave = v; end;
});

LOGI:AddToggle("VSH_LogReload", {
    Text = "Reloading",
    Default = getgenv().wh_log_reload,
    Tooltip = "Notifies when you start a reload",
    Callback = function(v) getgenv().wh_log_reload = v; end;
});

LOGI:AddToggle("VSH_LogNear", {
    Text = "Nearby Players",
    Default = getgenv().wh_log_near,
    Tooltip = "Notifies when a player enters or leaves the range below",
    Callback = function(v) getgenv().wh_log_near = v; end;
});

LOGI:AddSlider("VSH_LogNearM", {
    Text = "Notify Range",
    Default = getgenv().wh_log_near_m,
    Min = 10,
    Max = 500,
    Rounding = 0,
    Suffix = " m",
    Callback = function(v) getgenv().wh_log_near_m = v; end;
});

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

AimUnseenToggle = SA:AddToggle("VSH_AimUnseen", {
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

SA:AddSlider("VSH_AutoPulse", {
    Text = "Semi Click Rate",
    Default = getgenv().wh_autoshoot_pulse,
    Min = 0.1,
    Max = 2,
    Rounding = 2,
    Suffix = " s",
    Tooltip = "Gap between trigger pulls for semi / pump / bolt weapons. "
        .. "Full-auto weapons fire at the gun's own RPM instead.",
    Callback = function(v) getgenv().wh_autoshoot_pulse = v; end;
});

fireInputLabel = SA:AddLabel("fire: unresolved");   -- shows VIM or remote path


SA:AddToggle("VSH_TargetScavs", {
    Text = "Target Scavs",
    Default = getgenv().wh_target_scavs,
    Tooltip = "Also aim at armed NPCs - anything carrying a Tool that is not a player",
    Callback = function(v) getgenv().wh_target_scavs = v; end,
});

SA:AddToggle("VSH_TargetBears", {
    Text = "Target Bears",
    Default = getgenv().wh_target_bears,
    Callback = function(v) getgenv().wh_target_bears = v; end;
});

SA:AddToggle("VSH_TargetHorses", {
    Text = "Target Horses",
    Default = getgenv().wh_target_horses,
    Tooltip = "Also aim at horses and unicorns (they are mounts, so off by default)",
    Callback = function(v) getgenv().wh_target_horses = v; end;
});

SA:AddToggle("VSH_IgnoreTeam", {
    Text = "Ignore Team",
    Default = getgenv().wh_ignore_team,
    Tooltip = "Never target anyone on your team",
    Callback = function(v) getgenv().wh_ignore_team = v; end;
});

SA:AddToggle("VSH_IgnoreFriends", {
    Text = "Ignore Friends",
    Default = getgenv().wh_ignore_friends,
    Callback = function(v) getgenv().wh_ignore_friends = v; end;
});

VIS = Tabs.Visuals:AddRightGroupbox("Aim Box");

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
GUN = Tabs.Combat:AddLeftGroupbox("Weapon");

GUN:AddToggle("VSH_GunInfo", {
    Text = "Gun Info",
    Default = getgenv().wh_gun_info,
    Tooltip = "Draws the held weapon's fire mode, max range, RPM, damage and "
        .. "magazine as a line of text under the FOV circle",
    Callback = function(v) getgenv().wh_gun_info = v; end;
});

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

GUN:AddToggle("VSH_ForceAuto", {
    Text = "Force Auto (every gun)",
    Default = getgenv().wh_force_auto,
    Tooltip = "Every weapon keeps firing while the mouse is held, even Semi/Pump",
    Callback = function(v) getgenv().wh_force_auto = v; end;
});

GUN:AddToggle("VSH_ForceHit", {
    Text = "Force Hit (any range)",
    Default = getgenv().wh_force_hit,
    Tooltip = "Removes ProjectileMaxRange so shots register at any distance",
    Callback = function(v) getgenv().wh_force_hit = v; end;
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



local WCHARM = Tabs.Combat:AddLeftGroupbox("Weapon Skin");

WCHARM:AddToggle("VSH_CharmW", {
    Text = "Weapon Charm",
    Default = getgenv().wh_charm_w,
    Tooltip = "Changes the material/colour of every part of the weapon you are holding",
    Callback = function(v) getgenv().wh_charm_w = v; end;
});

WCHARM:AddDropdown("VSH_CharmWMat", {
    Text = "Weapon Material",
    Values = {
        "ForceField", "Neon", "Glass", "DiamondPlate", "SmoothPlastic", "Plastic",
        "Metal", "Wood", "WoodPlanks", "Slate", "Rock", "Concrete", "Cobblestone",
        "Brick", "Marble", "Granite", "Sandstone", "Sand", "Ice", "Glacier",
        "Fabric", "Leather", "CorrodedMetal", "Rust", "Lava", "Water", "Mud",
    },
    Default = getgenv().wh_charm_w_mat,
    AllowNull = false,
    Callback = function(v)
        getgenv().wh_charm_w_mat = v;
        restoreWeaponCharm();
        applyWeaponCharm();
    end;
});

addColorPicker(WCHARM, "VSH_CharmWColor", {
    Title = "Weapon Color",
    Default = getgenv().wh_charm_w_color,
    Callback = function(c) getgenv().wh_charm_w_color = c; end;
});

local SND = Tabs.Combat:AddRightGroupbox("Sounds");

SND:AddToggle("VSH_SndHit", {
    Text = "Hit Sound",
    Default = getgenv().wh_snd_hit,
    Callback = function(v) getgenv().wh_snd_hit = v; end;
});

SND:AddDropdown("VSH_SndHitPreset", {
    Text = "Hit Sound",
    Values = hitPresetValues,
    Default = getgenv().wh_snd_hit_preset,
    AllowNull = false,
    Tooltip = "Presets from additional/hitsounds.lua",
    Callback = function(v)
        getgenv().wh_snd_hit_preset = v;
        local id = HIT_SOUNDS[v];
        if id then getgenv().wh_snd_hit_id = id; end;
    end;
});

SND:AddInput("VSH_SndHitId", {
    Text = "Hit Sound ID",
    Placeholder = "rbxassetid://...",
    Default = getgenv().wh_snd_hit_id,
    Callback = function(v) getgenv().wh_snd_hit_id = tostring(v or ""); end;
});

SND:AddButton("Preview Hit Sound", function()
    playOneShot(getgenv().wh_snd_hit_id, nil, getgenv().wh_snd_vol or 1);
end);

SND:AddSlider("VSH_SndVol", {
    Text = "Volume",
    Default = getgenv().wh_snd_vol,
    Min = 0,
    Max = 5,
    Rounding = 2,
    Callback = function(v) getgenv().wh_snd_vol = v; end;
});



FIXBOX = Tabs.Combat:AddRightGroupbox("Repair");

FIXBOX:AddToggle("VSH_AutoFix", {
    Text = "Auto Fix Weapon",
    Default = getgenv().wh_auto_fix,
    Tooltip = "Clears a stuck firing flag automatically (gun in hand but won't fire)",
    Callback = function(v) getgenv().wh_auto_fix = v; end,
});

FIXBOX:AddButton("Fix Weapon Now", function()
    fixWeapon("button");
end);


LOGS = Tabs.Combat:AddLeftGroupbox("Logs");

LOGS:AddToggle("VSH_HitLogs", {
    Text = "Hit Logs",
    Default = getgenv().wh_hitlogs,
    Tooltip = "Notifies when a shot hits, kills or misses",
    Callback = function(v) getgenv().wh_hitlogs = v; end;
});

LOGS:AddToggle("VSH_HitLogsMiss", {
    Text = "Log Misses",
    Default = getgenv().wh_hitlogs_miss,
    Tooltip = "Also report shots that dealt no damage",
    Callback = function(v) getgenv().wh_hitlogs_miss = v; end;
});

LOGS:AddToggle("VSH_HitLogsBullet", {
    Text = "One Log Per Bullet",
    Default = getgenv().wh_hitlogs_bullet,
    Tooltip = "Logs every pellet separately (off = one line per trigger pull)",
    Callback = function(v) getgenv().wh_hitlogs_bullet = v; end;
});

LOGS:AddSlider("VSH_HitLogsCd", {
    Text = "Popup Cooldown",
    Default = getgenv().wh_hitlogs_cd,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Suffix = " s",
    Tooltip = "Throttles the on-screen popup; the console always prints every line",
    Callback = function(v) getgenv().wh_hitlogs_cd = v; end;
});


INFO = Tabs.Combat:AddRightGroupbox("Status");
gunStatusLabel = INFO:AddLabel("waiting for weapon configs...");

--================================================================
--  TAB: ESP
--================================================================
ESPG = Tabs.Visuals:AddLeftGroupbox("Players");

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

ESPG:AddSlider("VSH_TrailLife", {
    Text = "Trail Lifetime",
    Default = getgenv().wh_tracer_life,
    Min = 0.5,
    Max = 30,
    Rounding = 1,
    Suffix = " s",
    Callback = function(v) getgenv().wh_tracer_life = v; end;
});

addColorPicker(ESPG, "VSH_TrailColor", {
    Title = "Trail Color",
    Default = getgenv().wh_tracer_seg_color,
    Callback = function(c) getgenv().wh_tracer_seg_color = c; end;
});

ESPG:AddToggle("VSH_EspPack", {
    Text = "Backpack ESP",
    Default = getgenv().wh_esp_pack,
    Tooltip = "Labels each player / body with the backpack they carry (backpacks only)",
    Callback = function(v) getgenv().wh_esp_pack = v; end;
});

addColorPicker(ESPG, "VSH_PackColor", {
    Title = "Backpack Color",
    Default = getgenv().wh_esp_pack_color,
    Callback = function(c) getgenv().wh_esp_pack_color = c; end;
});

ESPG:AddToggle("VSH_EspCorpses", {
    Text = "Dead Bodies",
    Default = getgenv().wh_esp_corpses,
    Tooltip = "Shows dead players / bodies in their own colour",
    Callback = function(v) getgenv().wh_esp_corpses = v; end;
});

addColorPicker(ESPG, "VSH_CorpseColor", {
    Title = "Corpse Color",
    Default = getgenv().wh_esp_corpse_color,
    Callback = function(c) getgenv().wh_esp_corpse_color = c; end;
});

ESPG:AddToggle("VSH_EspHorses", {
    Text = "Horses",
    Default = getgenv().wh_esp_horses,
    Tooltip = "Show horses / unicorns (CollectionService tags)",
    Callback = function(v) getgenv().wh_esp_horses = v; end,
});

ESPG:AddSlider("VSH_EspNpcRange", {
    Text = "NPC / Horse Range",
    Default = getgenv().wh_esp_npc_dist,
    Min = 0,
    Max = 2000,
    Rounding = 0,
    Suffix = " m",
    Tooltip = "0 = unlimited",
    Callback = function(v) getgenv().wh_esp_npc_dist = v; end;
});

ESPG:AddSlider("VSH_EspPackRange", {
    Text = "Loot Range",
    Default = getgenv().wh_esp_pack_dist,
    Min = 0,
    Max = 2000,
    Rounding = 0,
    Suffix = " m",
    Tooltip = "0 = unlimited",
    Callback = function(v) getgenv().wh_esp_pack_dist = v; end;
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

ESPV = Tabs.Visuals:AddRightGroupbox("Colors");
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
MOVE = Tabs.Character:AddLeftGroupbox("Speed");

MOVE:AddToggle("VSH_Speed", {
    Text = "CFrame Speed Boost",
    Default = getgenv().wh_speed_on,
    Tooltip = "Moves you with CFrame or velocity instead of WalkSpeed (the game's own movement is switched off while this is on)",
    Callback = function(v) getgenv().wh_speed_on = v; end,
});

speedSlider = MOVE:AddSlider("VSH_SpeedAmount", {
    Text = "Boost Speed",
    Default = getgenv().wh_speed,
    Min = 0,
    Max = 500,
    Rounding = 0,
    Suffix = " st/s",
    Tooltip = "CFrame boost speed in studs per second",
    Callback = function(v) getgenv().wh_speed = v; end,
});

MOVE:AddSlider("VSH_SpeedCap", {
    Text = "Hard Speed Cap",
    Default = getgenv().wh_speed_cap,
    Min = 0,
    Max = 500,
    Rounding = 0,
    Suffix = " st/s",
    Tooltip = "Optional ceiling for the boost. 0 = no limit, so the Boost Speed "
        .. "slider above is used exactly as set.",
    Callback = function(v) getgenv().wh_speed_cap = v; end,
});

MOVE:AddSlider("VSH_SpeedAccel", {
    Text = "Boost Ramp",
    Default = getgenv().wh_speed_accel,
    Min = 0.5,
    Max = 40,
    Rounding = 1,
    Suffix = "x",
    Tooltip = "Lower = the boost fades in gradually (smoother, harder to detect)",
    Callback = function(v) getgenv().wh_speed_accel = v; end;
});

MOVE:AddToggle("VSH_RbAdaptive", {
    Text = "Auto-Lower Speed",
    Default = getgenv().wh_rb_adaptive,
    Tooltip = "Every rubberband detected takes one stud off the speed slider above. "
        .. "The slider moves with it, so the number you see is the real one.",
    Callback = function(v) getgenv().wh_rb_adaptive = v; end;
});

MOVE:AddSlider("VSH_SpeedFloor", {
    Text = "Auto-Lower Floor",
    Default = getgenv().wh_speed_floor,
    Min = 0,
    Max = 500,
    Rounding = 0,
    Suffix = " st/s",
    Tooltip = "Auto-lower will not take the speed below this",
    Callback = function(v) getgenv().wh_speed_floor = v; end;
});


ONE = Tabs.Character:AddLeftGroupbox("Anims");

ONE:AddToggle("VSH_OnetapAnims", {
    Text = "One Tap Anims",
    Default = getgenv().wh_onetap_anims,
    Tooltip = "Plays every animation at a low framerate so reloads, jumps and "
        .. "swings advance in visible steps instead of smoothly.",
    Callback = function(v)
        getgenv().wh_onetap_anims = v;
        if not v then releaseOnetap(); end;
    end;
});

ONE:AddSlider("VSH_OnetapFps", {
    Text = "Anim FPS",
    Default = getgenv().wh_onetap_fps,
    Min = 1,
    Max = 30,
    Rounding = 0,
    Suffix = " fps",
    Tooltip = "Lower = chunkier. 15 looks like a low-fps recording.",
    Callback = function(v) getgenv().wh_onetap_fps = v; end;
});

local JUMP = Tabs.Character:AddLeftGroupbox("Jump");

JUMP:AddToggle("VSH_Jump", {
    Text = "Super Jump",
    Default = getgenv().wh_jump,
    Tooltip = "Replaces the take-off velocity with your own (ignored while flying)",
    Callback = function(v) getgenv().wh_jump = v; end;
});

JUMP:AddSlider("VSH_JumpPower", {
    Text = "Jump Power",
    Default = getgenv().wh_jump_power,
    Min = 40,
    Max = 250,
    Rounding = 0,
    Suffix = " st/s",
    Callback = function(v) getgenv().wh_jump_power = v; end;
});

FLY = Tabs.Character:AddLeftGroupbox("Fly");

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


FALL = Tabs.Character:AddLeftGroupbox("Falls");

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

PHYSX = Tabs.Character:AddRightGroupbox("Physics");

PHYSX:AddToggle("VSH_Gravity", {
    Text = "Custom Gravity",
    Default = getgenv().wh_gravity_on,
    Tooltip = "Overrides workspace.Gravity. The game kicks Code 3 when gravity "
        .. "changes, so the Kick shield is engaged automatically.",
    Callback = function(v)
        getgenv().wh_gravity_on = v;
        applyGravityAndPhysics();
    end;
});

PHYSX:AddSlider("VSH_GravityValue", {
    Text = "Gravity",
    Default = getgenv().wh_gravity,
    Min = 0,
    Max = 1000,
    Rounding = 1,
    Tooltip = "This place ships with 196.2. Lower = floaty, higher = fast falls.",
    Callback = function(v)
        getgenv().wh_gravity = v;
        applyGravityAndPhysics();
    end;
});

PHYSX:AddSlider("VSH_PhysFps", {
    Text = "GetRealPhysicsFPS()",
    Default = getgenv().wh_phys_fps,
    Min = 1,
    Max = 120,
    Rounding = 0,
    Suffix = " fps",
    Tooltip = "What workspace:GetRealPhysicsFPS() reports to the game. Its watchdog "
        .. "kicks Code 5 at 65 or above, so stay under 65 unless the Kick shield is on.",
    Callback = function(v)
        getgenv().wh_phys_fps = v;
        ensureKickShield();
    end;
});


RBMON = Tabs.Character:AddRightGroupbox("Rubberband");

RBMON:AddToggle("VSH_RbLogs", {
    Text = "Detect Rubberband",
    Default = getgenv().wh_rb_logs,
    Tooltip = "Warns when the server moves you back further than expected",
    Callback = function(v) getgenv().wh_rb_logs = v; end;
});

RBMON:AddToggle("VSH_RbNotify", {
    Text = "Popup Notification",
    Default = getgenv().wh_rb_notify,
    Tooltip = "Shows a Library toast at the top of the screen when a snap is detected",
    Callback = function(v) getgenv().wh_rb_notify = v; end;
});

RBMON:AddSlider("VSH_RbNotifyTime", {
    Text = "Popup Duration",
    Default = getgenv().wh_rb_notify_time,
    Min = 1,
    Max = 20,
    Rounding = 1,
    Suffix = " s",
    Callback = function(v) getgenv().wh_rb_notify_time = v; end;
});

RBMON:AddSlider("VSH_RbThreshold", {
    Text = "Snap Threshold",
    Default = getgenv().wh_rb_threshold,
    Min = 2,
    Max = 30,
    Rounding = 0,
    Suffix = " st",
    Callback = function(v) getgenv().wh_rb_threshold = v; end;
});

rbStatusLabel = RBMON:AddLabel("no snaps yet");

RBMON:AddButton("Reset Counter", function()
    rbCount = 0;
        rbLastInfo = "none yet";
    if rbStatusLabel then rbStatusLabel:SetText("no snaps yet"); end;
end);

REACH = Tabs.Character:AddRightGroupbox("Reach");

REACH:AddToggle("VSH_Reach", {
    Text = "Extended Tool Range",
    Default = getgenv().wh_reach_on,
    Tooltip = "Raises every proximity prompt's MaxActivationDistance, so loot, "
        .. "harvest nodes, workbenches and doors can be used from much further away. "
        .. "This place ships them all at 8 studs.",
    Callback = function(v)
        getgenv().wh_reach_on = v;
        applyReach();
    end;
});

REACH:AddSlider("VSH_ReachDistance", {
    Text = "Reach",
    Default = getgenv().wh_reach_distance,
    Min = 8,
    Max = 200,
    Rounding = 0,
    Suffix = " st",
    Tooltip = "New MaxActivationDistance. The game default is 8.",
    Callback = function(v)
        getgenv().wh_reach_distance = v;
        applyReach();
    end;
});


TOOLSPAM = Tabs.Character:AddRightGroupbox("Tools");

TOOLSPAM:AddSlider("VSH_ToolFast", {
    Text = "No Tool Delay",
    Default = getgenv().wh_tool_fast_rate,
    Min = 1,
    Max = 15,
    Rounding = 1,
    Suffix = "x",
    Tooltip = "Scales the whole swing on harvesting tools (pickaxe, axe, hatchet): "
        .. "cooldown and duration down, animation speed up, so the swing stays "
        .. "complete but happens faster. 1x = the game's own rate.",
    Callback = function(v)
        getgenv().wh_tool_fast_rate = v;
        if v > 1 then patchMeleeItemConfigs(); end;
    end;
});


LOADOUT = Tabs.Character:AddRightGroupbox("Loadout");

LOADOUT:AddToggle("VSH_AutoLoadout", {
    Text = "Auto equip default loadout",
    Default = getgenv().wh_autoloadout,
    Tooltip = "On death, respawns you immediately and asks the game for the default "
        .. "starter kit (AttemptStarterKit \"Default\").",
    Callback = function(v) getgenv().wh_autoloadout = v; end;
});

RESPAWN = Tabs.Character:AddRightGroupbox("Respawn");

RESPAWN:AddToggle("VSH_RespawnDeath", {
    Text = "Respawn Where I Died",
    Default = getgenv().wh_respawn_death,
    Tooltip = "Remembers where you died and moves you back after the game respawns "
        .. "you at a spawn point. Retried for a couple of seconds.",
    Callback = function(v)
        getgenv().wh_respawn_death = v;
        if not v then deathSpot = nil; end;
    end;
});


RIDE = Tabs.Character:AddRightGroupbox("Riding");

RIDE:AddToggle("VSH_ShootRiding", {
    Text = "Shoot While Riding",
    Default = getgenv().wh_shoot_riding,
    Tooltip = "Re-parents a gun onto the character so the seated state stops blocking it",
    Callback = function(v) getgenv().wh_shoot_riding = v; end,
});


--================================================================
--  TAB: RENDER
--================================================================
CAML = Tabs.Visuals:AddLeftGroupbox("FOV");

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

FAKE = Tabs.Combat:AddRightGroupbox("Rotation");

FAKE:AddToggle("VSH_FakeRot", {
    Text = "Fake Rotation",
    Default = getgenv().wh_fake_rot,
    Tooltip = "Others see your body turned; your camera and aim stay normal",
    Callback = function(v) getgenv().wh_fake_rot = v; end,
});

FAKE:AddToggle("VSH_FakeRotWeaponOnly", {
    Text = "Weapons Only",
    Default = getgenv().wh_fake_rot_weapon_only,
    Tooltip = "Suspends fake rotation automatically while a melee tool (pickaxe, "
        .. "axe, hatchet) is held, and resumes it when you pull a weapon. Your "
        .. "menu choice is remembered either way.",
    Callback = function(v) getgenv().wh_fake_rot_weapon_only = v; end;
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
    Values = { "Custom", "Spin", "Random", "Jitter", "Jitter2", "Manual" },
    Default = getgenv().wh_fake_mode,
    AllowNull = false,
    Tooltip = "Custom = sliders | Spin = continuous yaw | Random = re-rolls all | "
		.. "Jitter = random yaw | Jitter2 = flips the body between east and west of "
		.. "wherever you are looking | Manual = arrow keys pick a compass heading",
    Callback = function(v) getgenv().wh_fake_mode = v; end,
});

FAKE:AddSlider("VSH_SpinSpeed", {
    Text = "Spin Speed",
    Default = getgenv().wh_fake_spin_speed,
    Min = 10,
    Max = 7200,
    Rounding = 0,
    Suffix = " deg/s",
    Tooltip = "Degrees per second the body spins in Spin mode",
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

FAKE:AddSlider("VSH_JitterInt", {
    Text = "Jitter Every",
    Default = getgenv().wh_jitter_interval,
    Min = 0.02,
    Max = 2,
    Rounding = 2,
    Suffix = " s",
    Tooltip = "How often the yaw is re-rolled in Jitter mode",
    Callback = function(v) getgenv().wh_jitter_interval = v; end;
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

local CHARM = Tabs.Character:AddLeftGroupbox("Body");


CHARM:AddToggle("VSH_Charm", {
    Text = "Body Charm",
    Default = getgenv().wh_charm,
    Tooltip = "Changes the material/colour of the selected body parts",
    Callback = function(v) getgenv().wh_charm = v; end;
});

CHARM:AddDropdown("VSH_CharmParts", {
    Text = "Parts",
    Values = { "Head", "Hair", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Weapon" },
    Default = "Head",
    Multi = true,
    AllowNull = false,
    Tooltip = "Only the selected groups are affected",
    Callback = function(v) getgenv().wh_charm_parts = v; end;
});

CHARM:AddDropdown("VSH_CharmMat", {
    Text = "Material",
    Values = {
        "ForceField", "Neon", "Glass", "DiamondPlate", "SmoothPlastic", "Plastic",
        "Metal", "Wood", "WoodPlanks", "Slate", "Rock", "Concrete", "Cobblestone",
        "Brick", "Marble", "Granite", "Sandstone", "Sand", "Ice", "Glacier",
        "Fabric", "Leather", "CorrodedMetal", "Rust", "Lava", "Water", "Mud",
    },
    Default = getgenv().wh_charm_mat,
    AllowNull = false,
    Callback = function(v)
        getgenv().wh_charm_mat = v;
        restoreCharm(); -- re-read originals against the new material
        applyCharm();
    end;
});

addColorPicker(CHARM, "VSH_CharmColor", {
    Title = "Charm Color",
    Default = getgenv().wh_charm_color,
    Callback = function(c) getgenv().wh_charm_color = c; end;
});

FAKE:AddToggle("VSH_FakeCam", {
    Text = "Fake Camera Angle",
    Default = getgenv().wh_fake_cam,
    Tooltip = "The server is told you are looking at the ground (or sky). "
        .. "Your own camera, head and viewmodel are untouched.",
    Callback = function(v) getgenv().wh_fake_cam = v; end;
});

FAKE:AddDropdown("VSH_FakeCamDir", {
    Text = "Fake Looking",
    Values = { "Down", "Up" },
    Default = getgenv().wh_fake_cam_dir,
    AllowNull = false,
    Tooltip = "Down = as if looking at the ground, Up = as if looking at the sky",
    Callback = function(v) getgenv().wh_fake_cam_dir = v; end;
});

FAKE:AddSlider("VSH_FakeCamPitch", {
    Text = "Camera Pitch",
    Default = getgenv().wh_fake_cam_pitch,
    Min = -90,
    Max = 90,
    Rounding = 0,
    Suffix = " deg",
    Callback = function(v) getgenv().wh_fake_cam_pitch = v; end;
});

FAKE:AddToggle("VSH_SafeShoot", {
    Text = "SafeShoot",
    Default = getgenv().wh_safeshoot,
    Tooltip = "Drops the fake rotation for a moment around each shot so the muzzle ray cannot hit you",
    Callback = function(v) getgenv().wh_safeshoot = v; end;
});

FAKE:AddSlider("VSH_SafeShootTime", {
    Text = "SafeShoot Window",
    Default = getgenv().wh_safeshoot_time,
    Min = 0.05,
    Max = 1,
    Rounding = 2,
    Suffix = " s",
    Callback = function(v) getgenv().wh_safeshoot_time = v; end;
});


--================================================================
--  TAB: LIGHTING
--================================================================
LIGHT = Tabs.Visuals:AddLeftGroupbox("Lighting");

LIGHT:AddToggle("VSH_NoFog", {
    Text = "No Fog",
    Default = getgenv().wh_nofog,
    Tooltip = "Pushes FogEnd out and drops Atmosphere density to 0",
    Callback = function(v) getgenv().wh_nofog = v; end;
});

LIGHT:AddToggle("VSH_Fullbright", {
    Text = "Fullbright",
    Default = getgenv().wh_fullbright,
    Tooltip = "Re-applies white ambient, brightness 2, no shadows and pushed-out fog "
        .. "every time the game's weather system changes them, so it always wins.",
    Callback = function(v) getgenv().wh_fullbright = v; end;
});


LIGHT:AddToggle("VSH_NoGrass", {
    Text = "No Grass",
    Default = getgenv().wh_nograss,
    Tooltip = "Removes grass from the terrain",
    Callback = function(v) getgenv().wh_nograss = v; end;
});

LIGHT:AddDropdown("VSH_Weather", {
    Text = "Weather",
    Values = WEATHER_VALUES,
    Default = getgenv().wh_weather,
    AllowNull = false,
    Tooltip = "Sets the game's own weather. Off = whatever the server says. "
        .. "Clear / Rain / LightningStorm / BloodMoon.",
    Callback = function(v)
        getgenv().wh_weather = v;
        if v == "Off" then restoreWeather(); end;
    end;
});

LIGHT:AddButton("Reset Lighting", function() resetLighting(); end);

CLOCKLABEL = Tabs.Visuals:AddRightGroupbox("Status");
clockLabel = CLOCKLABEL:AddLabel("fog off / bright off / grass on");

--================================================================
--  TAB: CONFIG
--================================================================
MENU = Tabs.Config:AddLeftGroupbox("Menu");
MENU:AddButton("Toggle UI", function() Library:Toggle(); end);
MENU:AddButton("Unload", function()
    stop("menu");
    pcall(function() Library:Unload(); end);
end);
MENU:AddToggle("VSH_NoKick", {
    Text = "Block Client Kick",
    Default = getgenv().wh_no_kick,
    Tooltip = "Stops the game's client-side anti-cheat kicking you (Code 2/3/5)",
    Callback = function(v) getgenv().wh_no_kick = v; end;
});


STATUS_BOX = Tabs.Config:AddRightGroupbox("Diagnostics");
diagLabel = STATUS_BOX:AddLabel("hook: pending");


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
-- Each per-frame update runs in its OWN pcall. Previously they shared one, so a
-- single failure (e.g. a nil helper) aborted the rest of the frame - which is how
-- one broken feature silently killed ESP, the HUD and fake rotation together.
local function safeStep(name, fn, ...)
    local ok, err = pcall(fn, ...);
    if not ok then
        HookStatus.renderErrors = HookStatus.renderErrors + 1;
        lastStepError = tostring(name) .. ": " .. tostring(err);
        if tracer then tracer.Visible = false; end; -- never leave a stale line
    end;
end

table.insert(Connections, RunService.RenderStepped:Connect(function(dt)
    if not Running then return; end;
    frameId = frameId + 1;

    local part;
    safeStep("target", function() part = currentTarget(); end);
    safeStep("hud", updateHud, part, dt);
    safeStep("autoshoot", applyAutoshoot);
    safeStep("esp", updateEsp);
    safeStep("backpackEsp", updateBackpackEsp);
    safeStep("fov", applyFov);
    safeStep("speedBoost", applySpeedBoost, dt);
    safeStep("rubberband", detectRubberband, dt);
    safeStep("logInfo", applyLogInfo);
    safeStep("gunInfo", applyGunInfo);
    safeStep("reach", applyReach);
    safeStep("jumpBoost", applyJumpBoost);
    safeStep("fly", applyFly, dt);
    safeStep("lighting", applyLighting);
    safeStep("fullbright", applyFullbright);
    safeStep("onetap", applyOnetapAnims, dt);
    safeStep("weather", setWeather);
    safeStep("fakeCam", applyFakeCam);
    safeStep("gravityPhysics", applyGravityAndPhysics);
    safeStep("shields", refreshShields);
    safeStep("fallDamage", applyNoFallDamage);
    safeStep("bodyCharm", applyCharm);
    safeStep("weaponCharm", applyWeaponCharm);

    -- fake rotation rebuilds the facing every frame; hand AutoRotate back as soon
    -- as it is switched off
    if fakeRotationActive() then
        safeStep("fakeRotation", applyFakeRotation, dt);
        fakeRotWasOn = true;
    elseif fakeRotWasOn then
        fakeRotWasOn = false;
        safeStep("autoRotateRestore", restoreAutoRotate);
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
            local _, wantGap = shotDelays(wt);
            -- ammo is read from the SAME helper the auto reload uses, so this
            -- readout and the reload logic can never disagree
            local ammoNow = currentAmmo();
            gunStatusLabel:SetText(string.format(
                "%s | fm %s | ammo %s/%s | spd %s | sprd %s | rpm %s | gap %.0fms",
                wt and wt.Name or "none",
                tostring(wt and wt:GetAttribute("State_Firemode")),
                ammoNow ~= nil and tostring(math.floor(ammoNow)) or "?",
                lc and tostring(lc.AmmoSize) or "-",
                lc and tostring(lc.ProjectileVelocity) or "-",
                lc and tostring(lc.ProjectileSpread) or "-",
                lc and tostring(lc.RPM) or "-",
                wantGap * 1000));
            fireInputLabel:SetText(string.format("fire: %s%s",
                getGunFireRemote() and "gun remote" or "no remote",
                autoshootHolding and " | firing" or ""));
        end);
        if manualHeadingLabel then
            local names = { [0] = "North", [45] = "North-East", [90] = "East",
                [135] = "South-East", [180] = "South", [225] = "South-West",
                [270] = "West", [315] = "North-West" };
            manualHeadingLabel:SetText(string.format("Manual facing: %s (%d deg)",
                names[math.floor(manualYawCompass + 0.5) % 360] or "?", manualYawCompass));
        end;
        if rbStatusLabel then
            rbStatusLabel:SetText(rbLastInfo);
        end;
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
    for _, o in next, packPool do freePack(o); end;
    clearTrails();
    -- give WalkSpeed back before we go, otherwise the boost toggle being off
    -- would still leave the player walking at 0 until the next sprint change
    pcall(function()
        local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid");
        if hum then setSpeedLock(hum, false); end;
    end);
    pcall(restoreReach);
    pcall(releaseOnetap);
    pcall(fbRestore);
    restoreCharm();
    restoreWeaponCharm();
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

