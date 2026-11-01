-- Makes a carried box follow the right hand, held by its right side.
--
-- Every box in the game is one Blueprint, Box_Openable (the many box looks
-- are just meshes; from the game's pak file list). How the game carries it
-- isn't known yet (it isn't hung from the camera like the scanner), so a box
-- counts as carried when either:
--   - it's attached to a part of the player or the camera, or
--   - a variable on the player, the controller or one of the player's
--     Blueprint components points at it, and it's seen moving with the
--     camera (so a box you're merely looking at doesn't jump to the hand).
-- While carried, it's placed each frame after the game's update (as the mop
-- is), just ahead of the hand, keeping the turn it had relative to the camera
-- when picked up. When it stops being carried it's left alone, and the game
-- puts it down at the player's feet (the game's own design, as in flat play).

local api = uevr.api
local functions = uevr.params.functions

local FOLLOW = true -- false: don't move the box
local BOX_CLASS = "BlueprintGeneratedClass /Game/_BP/Box_system/Box_Openable.Box_Openable_C"
local RIGHT_HAND = 1
-- The box's centre this far ahead of the hand along the aim, so it pivots
-- on the hand (version 1 held its near side at the hand, which put a big
-- box's centre ~40 cm out, swinging around the hand much as the game's
-- hold swings around the head)
local HOLD_AHEAD = 20.0       -- cm (10 close, 20 too far on 2026-10-31, 15 chosen; back to 20 for a retry 2026-11-01)
-- The right hand holds the box's right side: the box is moved left (along
-- the hand's right axis) by half its width plus this gap, so its right side
-- sits against the hand. HOLD_AHEAD still moves it forward along the aim.
local SIDE_GRIP = false      -- true held boxes too far left (user, 2026-10-31)
local SIDE_GAP = 2.0          -- cm between the hand and the box's right side
local SCAN_INTERVAL = 0.25    -- seconds between searches for a carried box
local NEAR_RANGE = 300.0      -- cm from the camera to look for an attached box
local CONFIRM_FRAMES = 3      -- frames a referenced box must move with the camera

local scene_c, actor_c, actor_comp_c, mesh_c, kml, hit_result
local box_c = nil
local since_class_try = 99.0
local hand_marker = nil
local held = nil       -- { box, how, holder, prop, rel_fwd, rel_up, arm }
local candidate = nil  -- { box, holder, prop, frames, last_rel, last_world }
local since_scan = 0.0
local props_cache = {} -- class address -> list of object property names
local logged_errors = {}
local step = "init"

local function log(msg)
    functions.log_info("[held_box] " .. msg)
end

local function name_of(obj)
    if obj == nil then return "none" end
    return obj:get_fname():to_string()
end

local function class_name(obj)
    return name_of(obj:get_class())
end

local function vec(x, y, z) return Vector3d.new(x, y, z) end
local function add(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
local function sub(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function mul(a, k) return vec(a.X * k, a.Y * k, a.Z * k) end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a)
    local l = len(a)
    return l > 1e-6 and mul(a, 1.0 / l) or vec(1, 0, 0)
end
local function same(a, b)
    return a ~= nil and b ~= nil and a:get_address() == b:get_address()
end

local function log_error(key)
    if not logged_errors[key] then
        logged_errors[key] = true
        log("error at '" .. key .. "'")
    end
end

-- Object variables of a class and its parents (cached per class)
local function object_props(obj)
    local cls = obj:get_class()
    local key = cls:get_address()
    if props_cache[key] ~= nil then
        return props_cache[key]
    end
    local names = {}
    local c = cls
    while c ~= nil do
        local p = c:get_child_properties()
        while p ~= nil do
            local ok, kind = pcall(function() return p:get_class():get_fname():to_string() end)
            if ok and kind == "ObjectProperty" then
                table.insert(names, p:get_fname():to_string())
            end
            p = p:get_next()
        end
        c = c:get_super_struct()
    end
    props_cache[key] = names
    return names
end

-- The player, the controller, and the player's Blueprint components
local function holders(pawn, controller)
    local list = { pawn, controller }
    local ok, comps = pcall(function() return pawn:K2_GetComponentsByClass(actor_comp_c) end)
    if ok and comps ~= nil then
        for _, c in ipairs(comps) do
            local ok_n, full = pcall(function() return c:get_class():get_full_name() end)
            if ok_n and full:find("/Game/", 1, true) then
                table.insert(list, c)
            end
        end
    end
    return list
end

local function read(holder, prop)
    local ok, v = pcall(function() return holder[prop] end)
    if ok then return v end
    return nil
end

local function is_box(v)
    if v == nil then return false end
    local ok, r = pcall(function() return v:is_a(box_c) end)
    return ok and r == true
end

-- Scans the holders' variables: returns the first box found (with where)
local function scan_variables(list)
    for _, holder in ipairs(list) do
        for _, prop in ipairs(object_props(holder)) do
            local v = read(holder, prop)
            if is_box(v) then
                return { box = v, holder = holder, prop = prop }
            end
        end
    end
    return nil
end

local function attach_info(box)
    local root = box:K2_GetRootComponent()
    local parent = nil
    pcall(function() parent = root:GetAttachParent() end)
    if parent == nil then
        return nil, nil
    end
    local owner = nil
    pcall(function() owner = parent:GetOwner() end)
    return parent, owner
end

-- The box's biggest visible mesh
local function box_mesh(box)
    local best, best_size = nil, -1
    for _, c in ipairs(box:K2_GetComponentsByClass(mesh_c) or {}) do
        local ok, size = pcall(function()
            if not c:IsVisible() or c.StaticMesh == nil then return -1 end
            local e = c.StaticMesh:GetBounds().BoxExtent
            local s = c:K2_GetComponentScale()
            return e.X * s.X * e.Y * s.Y * e.Z * s.Z
        end)
        if ok and size > best_size then
            best, best_size = c, size
        end
    end
    return best
end

-- The box's centre and its half depth along a direction, in the world
local function box_shape(box, dir)
    local mesh = box_mesh(box)
    if mesh == nil then
        return box:K2_GetActorLocation(), 15.0
    end
    local b = mesh.StaticMesh:GetBounds()
    local o, e = b.Origin, b.BoxExtent
    local s = mesh:K2_GetComponentScale()
    local r = mesh:K2_GetComponentRotation()
    local centre = add(mesh:K2_GetComponentLocation(), kml:GreaterGreater_VectorRotator(vec(o.X * s.X, o.Y * s.Y, o.Z * s.Z), r))
    local half = math.abs(dot(dir, mesh:GetForwardVector())) * e.X * s.X
        + math.abs(dot(dir, mesh:GetRightVector())) * e.Y * s.Y
        + math.abs(dot(dir, mesh:GetUpVector())) * e.Z * s.Z
    return centre, half
end

local function marker(pawn)
    if hand_marker ~= nil and UEVR_UObjectHook.exists(hand_marker) then
        return hand_marker
    end
    hand_marker = api:add_component_by_class(pawn, scene_c)
    if hand_marker == nil then
        error("couldn't add the hand marker")
    end
    local state = UEVR_UObjectHook.get_or_add_motion_controller_state(hand_marker)
    state:set_hand(RIGHT_HAND)
    state:set_permanent(true)
    return hand_marker
end

local function camera_root(controller)
    return controller.PlayerCameraManager:K2_GetRootComponent()
end

-- Start carrying: remember the box's turn relative to the camera
local function take(box, how, holder, prop, controller, pawn)
    local cam = camera_root(controller)
    local cr = cam:K2_GetComponentRotation()
    local root = box:K2_GetRootComponent()
    local fwd = kml:LessLess_VectorRotator(root:GetForwardVector(), cr)
    local up = kml:LessLess_VectorRotator(root:GetUpVector(), cr)
    held = { box = box, how = how, holder = holder, prop = prop, rel_fwd = fwd, rel_up = up }
    candidate = nil
    pcall(marker, pawn)
end

-- Stop carrying; the game puts the box down (at the player's feet, as in
-- flat play)
local function release()
    held = nil
end

-- Is the box still carried?
local function still_held(pawn, controller, cam_actor)
    if not UEVR_UObjectHook.exists(held.box) then
        return false, "box gone"
    end
    if held.how == "attached" then
        local _, owner = attach_info(held.box)
        if not (same(owner, pawn) or same(owner, cam_actor)) then
            return false, "no longer attached to the player"
        end
        return true
    end
    if not same(read(held.holder, held.prop), held.box) then
        return false, class_name(held.holder) .. "." .. held.prop .. " no longer points at it"
    end
    return true
end

-- A referenced box counts as carried once it holds its place relative to
-- the camera over a few frames in which a still box would have shifted
local function confirm(controller)
    local cam = camera_root(controller)
    local cl, cr = cam:K2_GetComponentLocation(), cam:K2_GetComponentRotation()
    local p = candidate.box:K2_GetActorLocation()
    local rel = kml:LessLess_VectorRotator(sub(p, cl), cr)
    if candidate.last_rel ~= nil then
        local still_rel = kml:LessLess_VectorRotator(sub(candidate.last_world, cl), cr)
        local expected = len(sub(still_rel, candidate.last_rel)) -- a box at rest
        local actual = len(sub(rel, candidate.last_rel))
        if expected > 3.0 then
            if actual < 1.0 then
                candidate.frames = candidate.frames + 1
            else
                candidate.frames = 0
            end
        end
    end
    candidate.last_rel, candidate.last_world = rel, p
    return candidate.frames >= CONFIRM_FRAMES
end

local function tick(engine, delta)
    if box_c == nil then
        since_class_try = since_class_try + delta
        if since_class_try < 2.0 then return end
        since_class_try = 0.0
        box_c = api:find_uobject(BOX_CLASS)
        if box_c == nil then return end
    end

    local controller = api:get_player_controller(0)
    local pawn = api:get_local_pawn(0)
    if controller == nil or pawn == nil then return end
    local cam_actor = controller.PlayerCameraManager

    if held ~= nil then
        step = "check held"
        if not still_held(pawn, controller, cam_actor) then
            release()
        end
    end

    since_scan = since_scan + delta
    if since_scan >= SCAN_INTERVAL then
        since_scan = 0.0
        step = "scan variables"
        local found = scan_variables(holders(pawn, controller))

        if held == nil then
            step = "find attached"
            -- A box attached to the player or camera
            local cam_loc = camera_root(controller):K2_GetComponentLocation()
            for _, b in ipairs(UEVR_UObjectHook.get_objects_by_class(box_c, false)) do
                local ok, p = pcall(function() return b:K2_GetActorLocation() end)
                if ok and len(sub(p, cam_loc)) < NEAR_RANGE then
                    local _, owner = attach_info(b)
                    if same(owner, pawn) or same(owner, cam_actor) then
                        take(b, "attached", nil, nil, controller, pawn)
                        break
                    end
                end
            end
            -- A box a variable points at
            if held == nil and found ~= nil and (candidate == nil or not same(candidate.box, found.box)) then
                candidate = { box = found.box, holder = found.holder, prop = found.prop, frames = 0 }
            elseif found == nil then
                candidate = nil
            end
        end
    end

    if held == nil and candidate ~= nil then
        step = "confirm"
        if not UEVR_UObjectHook.exists(candidate.box) then
            candidate = nil
        elseif confirm(controller) then
            take(candidate.box, "variable " .. class_name(candidate.holder) .. "." .. candidate.prop,
                candidate.holder, candidate.prop, controller, pawn)
        end
    end
end

-- Just ahead of the hand, turned with it as it was with the camera
local function place()
    if held == nil or not FOLLOW or hand_marker == nil or not UEVR_UObjectHook.exists(held.box) then
        return
    end
    local hand = hand_marker:K2_GetComponentLocation()
    local hr = hand_marker:K2_GetComponentRotation()
    local aim = norm(kml:Conv_RotatorToVector(hr))
    local fwd = kml:GreaterGreater_VectorRotator(held.rel_fwd, hr)
    local up = kml:GreaterGreater_VectorRotator(held.rel_up, hr)
    local rot = kml:MakeRotFromXZ(fwd, up)

    local root = held.box:K2_GetRootComponent()
    local right = norm(kml:GetRightVector(hr))
    local centre, half_width = box_shape(held.box, right)
    -- Where the centre sits relative to the root, in the root's frame
    local c_local = kml:LessLess_VectorRotator(sub(centre, root:K2_GetComponentLocation()), root:K2_GetComponentRotation())
    local target = add(hand, mul(aim, HOLD_AHEAD))
    if SIDE_GRIP then
        target = sub(target, mul(right, half_width + SIDE_GAP))
    end
    local loc = sub(target, kml:GreaterGreater_VectorRotator(c_local, rot))
    root:K2_SetWorldLocationAndRotation(loc, rot, false, hit_result, true)
end

local ok, err = pcall(function()
    scene_c = api:find_uobject("Class /Script/Engine.SceneComponent")
    actor_c = api:find_uobject("Class /Script/Engine.Actor")
    actor_comp_c = api:find_uobject("Class /Script/Engine.ActorComponent")
    mesh_c = api:find_uobject("Class /Script/Engine.StaticMeshComponent")
    kml = api:find_uobject("Class /Script/Engine.KismetMathLibrary"):get_class_default_object()
    hit_result = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
end)
if not ok then
    log("init error: " .. tostring(err))
    return
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local ok, err = pcall(tick, engine, delta)
    if not ok then
        log_error(step .. ": " .. tostring(err))
    end
end)

-- After the game's update and after UEVR has put the marker on the hand
-- (before the second view), as for the mop
uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if view_index % 2 ~= 1 then
        return
    end
    local ok, err = pcall(place)
    if not ok then
        log_error("place: " .. tostring(err))
    end
end)

log("script loaded")
