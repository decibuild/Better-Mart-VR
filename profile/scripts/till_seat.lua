-- At the till (sitting at a register, BP_CashOutNEW_C):
--
-- 1. Moves the seated view back and up. Sitting lowers the camera's mount
--    (SpringArm1) from 170 to 140 cm, right over the counter, so pointing
--    into the till needs a steep wrist angle. While sitting, the player's
--    Camera (on the end of SpringArm1) is moved SEAT_BACK cm further from the
--    till and SEAT_UP cm higher, which moves the view and the aim's origin
--    together. Put back when you stand.
--    (Version 1 moved SpringArm1, but the game resets it to (0, 0, 140)
--    every frame while you turn, after this script runs, so the view
--    snapped back in while turning.)
--
-- 2. Standing up with B only works while aiming at the register. When B is
--    pressed while sitting and you're still sitting STAND_DELAY later, this
--    calls the game's stand-up itself: Player_Comp_C.RemoveSitting, then the
--    register's "Enlever joueur sur caisse" if that wasn't enough.

local api = uevr.api
local vr = uevr.params.vr
local functions = uevr.params.functions

local SEAT_BACK = 20.0 -- cm away from the till (25 felt a little far)
local SEAT_UP = 0.0    -- cm higher (10 was too high)
local AUTO_STAND = true
local STAND_DELAY = 0.3 -- seconds after B before stepping in
local REGISTER_CLASS = "BP_CashOutNEW_C"
local CANDIDATES = {
    { holder = "Player_Comp_C", fn = "RemoveSitting" },
    { holder = "register", fn = "Enlever joueur sur caisse" },
}

local kml, scene_c, actor_c, actor_comp_c, hit_result
local seated = nil -- { camera, arm, rel0 = {x, y, z}, back = {x, y}, register, last, resets }
local was_sitting = false
local b_action = nil
local b_was_down = false
local stand_try = nil -- { t, step } after a B press while sitting
local logged_errors = {}

local function log(msg)
    functions.log_info("[till_seat] " .. msg)
end

local function name_of(obj)
    if obj == nil then return "none" end
    return obj:get_fname():to_string()
end

local function vec(x, y, z) return Vector3d.new(x, y, z) end

local function find_part(pawn, name)
    for _, c in ipairs(pawn:K2_GetComponentsByClass(scene_c) or {}) do
        if name_of(c) == name then
            return c
        end
    end
    return nil
end

local function player_comp(pawn)
    for _, c in ipairs(pawn:K2_GetComponentsByClass(actor_comp_c) or {}) do
        if name_of(c:get_class()) == "Player_Comp_C" then
            return c
        end
    end
    return nil
end

local function is_sitting(pawn)
    local ok, v = pcall(function() return pawn.Sitting end)
    return ok and v == true
end

-- The register nearest the player
local function nearest_register(pawn)
    local pl = pawn:K2_GetActorLocation()
    local best, best_d = nil, nil
    for _, a in ipairs(UEVR_UObjectHook.get_objects_by_class(actor_c, false)) do
        local ok, cls = pcall(function() return a:get_class():get_fname():to_string() end)
        if ok and cls == REGISTER_CLASS then
            local p = a:K2_GetActorLocation()
            local d = (p.X - pl.X) ^ 2 + (p.Y - pl.Y) ^ 2
            if best_d == nil or d < best_d then
                best, best_d = a, d
            end
        end
    end
    return best
end

-- Seated view ---------------------------------------------------------

local function sit(pawn)
    local camera = find_part(pawn, "Camera")
    local arm = find_part(pawn, "SpringArm1")
    if camera == nil or arm == nil then
        log("no Camera/SpringArm1 on the player; leaving the view alone")
        return
    end
    local r = camera.RelativeLocation
    local rel0 = { x = r.X, y = r.Y, z = r.Z } -- copied: property reads are live

    -- Away from the till: from the register to the player, level. Falls back
    -- to the player's backward direction if no register is found.
    local pl = pawn:K2_GetActorLocation()
    local dx, dy
    local register = nearest_register(pawn)
    if register ~= nil then
        -- Along the register's right axis, away from it: the chair faces
        -- along that axis. The seat is diagonal from the register's origin
        -- (-40 forward, +40 right), so the straight line put the view to the
        -- left of the chair (version 2), and picking the nearer axis (version
        -- 3) was a coin toss between the two.
        local p = register:K2_GetActorLocation()
        local tx, ty = pl.X - p.X, pl.Y - p.Y
        local f, r = register:GetActorForwardVector(), register:GetActorRightVector()
        local along_f, along_r = tx * f.X + ty * f.Y, tx * r.X + ty * r.Y
        local sgn = along_r >= 0 and 1 or -1
        dx, dy = r.X * sgn, r.Y * sgn
    else
        local f = pawn:GetActorForwardVector()
        dx, dy = -f.X, -f.Y
    end
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-3 then
        log("player is on top of the register; leaving the view alone")
        return
    end
    seated = { camera = camera, arm = arm, rel0 = rel0, back = { x = dx / len, y = dy / len }, register = register, last = nil }
end

-- Every frame while sitting. The player (and so SpringArm1 and its end)
-- turns with the aim even when seated, so the offset is worked out again in
-- the arm end's current frame, keeping the view in the same place in the
-- world.
local function hold_seat()
    if seated == nil or not UEVR_UObjectHook.exists(seated.camera) then
        return
    end
    local camera = seated.camera
    local r = camera.RelativeLocation

    -- The game moved the camera itself: take that as the new base
    if seated.last ~= nil and math.abs(r.X - seated.last.x) + math.abs(r.Y - seated.last.y) + math.abs(r.Z - seated.last.z) > 1.0 then
        seated.rel0 = { x = r.X, y = r.Y, z = r.Z }
    end

    local world = vec(seated.back.x * SEAT_BACK, seated.back.y * SEAT_BACK, SEAT_UP)
    local ok, socket_rot = pcall(function() return seated.arm:GetSocketRotation("SpringEndpoint") end)
    if not ok or socket_rot == nil then
        socket_rot = seated.arm:K2_GetComponentRotation()
    end
    local off = kml:LessLess_VectorRotator(world, socket_rot)
    local w = { x = seated.rel0.x + off.X, y = seated.rel0.y + off.Y, z = seated.rel0.z + off.Z }
    camera:K2_SetRelativeLocation(vec(w.x, w.y, w.z), false, hit_result, true)
    seated.last = w
end

local function stand()
    if seated == nil then
        return
    end
    if UEVR_UObjectHook.exists(seated.camera) then
        local r0 = seated.rel0
        seated.camera:K2_SetRelativeLocation(vec(r0.x, r0.y, r0.z), false, hit_result, true)
    end
    seated = nil
end

-- Standing up with B ---------------------------------------------------------

-- B as the game sees it: it reads B as "RightClick" and sets
-- Player_Comp_C."RightClick Pressed" while it's held. (Version 2 read the
-- VR action, which missed every press in one session, probably because the
-- action handle was looked up before UEVR had set it up and kept as 0.)
local function b_down(pawn)
    local comp = player_comp(pawn)
    if comp ~= nil then
        local ok, v = pcall(function() return comp["RightClick Pressed"] end)
        if ok and v == true then
            return true
        end
    end
    if b_action == nil or b_action == 0 then
        b_action = vr.get_action_handle("/actions/default/in/BButtonRight")
    end
    return b_action ~= nil and b_action ~= 0 and vr.is_action_active(b_action, vr.get_right_joystick_source()) == true
end

local function read(obj, prop)
    local ok, v = pcall(function() return obj[prop] end)
    if not ok then return "?" end
    if v == nil then return "none" end
    local ok_n, n = pcall(function() return v:get_fname():to_string() end)
    return ok_n and n or tostring(v)
end

local function call_candidate(pawn, c)
    local obj = nil
    if c.holder == "Player_Comp_C" then
        obj = player_comp(pawn)
    elseif c.holder == "register" then
        obj = (seated and seated.register) or nearest_register(pawn)
    end
    if obj == nil then
        log("no " .. c.holder .. " to call " .. c.fn .. " on")
        return
    end
    local ok, err = pcall(function() return obj[c.fn](obj) end)
    if not ok then
        log(string.format("calling %s.%s failed: %s", c.holder, c.fn, tostring(err)))
    end
end

local function watch_b(pawn, controller, delta, sat_last_frame)
    local down = b_down(pawn)
    -- Sitting is checked as of the last frame: when B works, the game stands
    -- you up in the same frame, before this sees the press
    if down and not b_was_down and sat_last_frame then
        local comp = player_comp(pawn)
        local hovered = read(controller, "Hovered Actor")
        local hover_bp = comp and read(comp, "Hover BP") or "?"
        -- B is the game's right click, which may do something else when
        -- aimed at an item or money; only step in when aimed at nothing
        local aimed_at_nothing = hovered == "none" and (hover_bp == "none" or hover_bp == "?")
        stand_try = { t = 0.0, step = 0, skip = not aimed_at_nothing }
    end
    b_was_down = down

    if stand_try == nil then
        return
    end
    stand_try.t = stand_try.t + delta
    if not is_sitting(pawn) then
        stand_try = nil
        return
    end
    if not AUTO_STAND or stand_try.skip then
        if stand_try.t > 1.5 then
            stand_try = nil
        end
        return
    end
    -- Still sitting: try the next candidate every STAND_DELAY
    if stand_try.t >= STAND_DELAY * (stand_try.step + 1) then
        stand_try.step = stand_try.step + 1
        local c = CANDIDATES[stand_try.step]
        if c == nil then
            stand_try = nil
            return
        end
        call_candidate(pawn, c)
    end
end

-- Main --------------------------------------------------------------------

local ok, err = pcall(function()
    kml = api:find_uobject("Class /Script/Engine.KismetMathLibrary"):get_class_default_object()
    scene_c = api:find_uobject("Class /Script/Engine.SceneComponent")
    actor_c = api:find_uobject("Class /Script/Engine.Actor")
    actor_comp_c = api:find_uobject("Class /Script/Engine.ActorComponent")
    hit_result = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
end)
if not ok then
    log("init error: " .. tostring(err))
    return
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local ok, err = pcall(function()
        local pawn = api:get_local_pawn(0)
        local controller = api:get_player_controller(0)
        if pawn == nil or controller == nil then return end

        local sat_last_frame = was_sitting
        local sitting = is_sitting(pawn)
        if sitting and not was_sitting then
            sit(pawn)
        elseif not sitting and was_sitting then
            stand()
        end
        if sitting then
            hold_seat()
        end
        was_sitting = sitting

        local ok_b, err_b = pcall(watch_b, pawn, controller, delta, sat_last_frame)
        if not ok_b and not logged_errors["b: " .. tostring(err_b)] then
            logged_errors["b: " .. tostring(err_b)] = true
            log("error with B: " .. tostring(err_b))
        end
    end)
    if not ok and not logged_errors[tostring(err)] then
        logged_errors[tostring(err)] = true
        log("error: " .. tostring(err))
    end
end)

uevr.sdk.callbacks.on_script_reset(function()
    pcall(stand)
end)

log("script loaded")
