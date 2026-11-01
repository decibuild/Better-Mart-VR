-- Makes the held tools follow the right controller.
--
-- The scanner (BP_Scannette_C) and wrench (BP_Reparator_C) hang from the
-- camera manager's root (TransformComponent0), which in VR turns with the
-- hand but pivots around the head. Their root is attached to the right hand
-- with UEVR's motion controller hook, which sets its world transform to the
-- hand's grip position and aim rotation times the inverse of the state's
-- rotation offset, every frame (UObjectHook::tick_attachments). The root's
-- own turn relative to the camera (the wrench's is yaw -90) goes into that
-- rotation offset, so the tool keeps its layout relative to the aim, and the
-- game's own animations of the parts (set relative to the root) stay right.
-- The parts are then shifted so a grip point sits on the hand.
--
-- The mop (BP_Balaie_C) hangs from the player's capsule, and the game puts
-- its head (Object_7, with the Sphere that cleans) back at a fixed spot
-- relative to the mop every frame. So it isn't attached: each frame the
-- whole mop is turned so its handle runs from the hand down along the aim,
-- tilted toward the floor, and moved so the top of the handle is in the
-- hand. The hand's world pose comes from an invisible marker that UEVR keeps
-- on the hand.

local api = uevr.api
local functions = uevr.params.functions

local ATTACH = true
local RIGHT_HAND = 1

-- Per tool class:
--   scale:         multiplies the main mesh's size (the scanner is sized 2x
--                  to look right ~70 cm from the camera)
--   grip_from_end: hold the mesh on its long axis this far (cm) in from its
--                  end nearest you, so it extends outward
--   lower:         hold the tool this far (cm) lower in the hand, along the
--                  hand's up, so the hand sits higher on its grip (the
--                  scanner's pivot is at the bottom of its handle)
--   mop:           hold like a mop (see above): tilt is degrees below the
--                  aim, grip_from_top is how far down the handle the hand is
local TOOLS = {
    BP_Scannette_C = { scale = 0.5, lower = 7.0 },
    BP_Reparator_C = { grip_from_end = 6.0 },
    BP_Balaie_C = { mop = true, head = "Object_7", spinner = "Object_8", tilt = 45.0, grip_from_top = 10.0 },
}
-- Tools hanging from the player's capsule rather than the camera
local CAPSULE_TOOLS = { BP_Balaie_C = true }
-- Never tools, even if hung from the camera (held_box.lua handles boxes)
local NOT_TOOLS = { Box_Openable_C = true }

-- Tools whose button is also jump (X scans a pallet with the scanner): no
-- jumping while one is out. The character's JumpMaxCount is set to 0, so the
-- game's own jump check refuses, and put back when the tool is put away.
local NO_JUMP_TOOLS = { BP_Scannette_C = true }
local saved_jumps = nil -- { pawn address, original JumpMaxCount } while blocked

local scene_c, mesh_c, kml, hit_result
local set_up = {}  -- root address -> { grip = point in mesh space, or nil }
local mop_handles = {} -- actor address -> handle mesh component
local hand_marker = nil
local mops = {}          -- this frame's mops: { pawn, actor, root, tool }
local step = "init"
local failed = false
local logged_errors = {}

local function log(msg)
    functions.log_info("[held_tools] " .. msg)
end

local function name_of(obj)
    if obj == nil then
        return "none"
    end
    return obj:get_fname():to_string()
end

local function class_name(obj)
    return name_of(obj:get_class())
end

local function rot_str(r)
    return string.format("(pitch %.1f, yaw %.1f, roll %.1f)", r.Pitch, r.Yaw, r.Roll)
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
local function cross(a, b)
    return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end

-- Axes for a direction: x along it, z as close to `up` as allowed, y from
-- those two. Built the same way everywhere, so mapping between two such
-- frames is a proper turn.
local function frame(x, up)
    x = norm(x)
    local z = sub(up, mul(x, dot(up, x)))
    if len(z) < 1e-3 then
        z = vec(1, 0, 0)
        z = sub(z, mul(x, dot(z, x)))
    end
    z = norm(z)
    return { x = x, y = cross(z, x), z = z }
end

-- Rotate v about unit axis k by angle (radians), Rodrigues' formula; with
-- k = a x b it turns a toward b
local function rotate_about(v, k, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return add(add(mul(v, c), mul(cross(k, v), s)), mul(k, dot(k, v) * (1.0 - c)))
end

-- The mop's root heading relative to the aim's (the game lays the mop with
-- its root at yaw -90 to the player)
local MOP_HEAD_YAW = -90.0

local function mesh_name(comp)
    for _, prop in ipairs({ "StaticMesh", "SkeletalMeshAsset", "SkeletalMesh" }) do
        local ok, mesh = pcall(function() return comp[prop] end)
        if ok and mesh ~= nil then
            return name_of(mesh)
        end
    end
    return nil
end

local function is_visible(comp)
    local ok, v = pcall(function() return comp:IsVisible() end)
    return ok and v == true
end

local function main_mesh(actor)
    for _, c in ipairs(actor:K2_GetComponentsByClass(mesh_c) or {}) do
        if is_visible(c) and mesh_name(c) ~= nil then
            return c
        end
    end
    return nil
end

local function find_part(actor, name)
    for _, c in ipairs(actor:K2_GetComponentsByClass(scene_c) or {}) do
        if name_of(c) == name then
            return c
        end
    end
    return nil
end

local function children(root)
    local list = {}
    for i = 0, root:GetNumChildrenComponents() - 1 do
        local child = root:GetChildComponent(i)
        if child ~= nil then
            table.insert(list, child)
        end
    end
    return list
end

-- A static mesh's longest axis: its two ends' centres in the mesh's own
-- space (low end first), its length scaled, the bounds, and which axis
local function long_axis(mesh)
    local b = mesh.StaticMesh:GetBounds()
    local o, e, s = b.Origin, b.BoxExtent, mesh.RelativeScale3D
    local axes = {
        { e.X * s.X, vec(e.X, 0, 0), "X" },
        { e.Y * s.Y, vec(0, e.Y, 0), "Y" },
        { e.Z * s.Z, vec(0, 0, e.Z), "Z" },
    }
    table.sort(axes, function(a, b) return a[1] > b[1] end)
    local half = axes[1][2]
    local origin = vec(o.X, o.Y, o.Z)
    return sub(origin, half), add(origin, half), axes[1][1] * 2.0, b, axes[1][3]
end

-- A point in a component's own space, in the world
local function to_world(comp, p)
    local s = comp:K2_GetComponentScale()
    local scaled = vec(p.X * s.X, p.Y * s.Y, p.Z * s.Z)
    return add(comp:K2_GetComponentLocation(), kml:GreaterGreater_VectorRotator(scaled, comp:K2_GetComponentRotation()))
end

local function scale_tool(actor, tool)
    if tool.scale == nil then
        return
    end
    local mesh = main_mesh(actor)
    if mesh == nil then
        log(class_name(actor) .. ": no visible mesh to scale")
        return
    end
    local s = mesh.RelativeScale3D
    mesh:SetRelativeScale3D(vec(s.X * tool.scale, s.Y * tool.scale, s.Z * tool.scale))
end

-- The point on the mesh's long axis grip_from_end in from the end nearest
-- you (backward along the aim), in the mesh's own space
local function grip_point(actor, root, tool)
    local mesh = main_mesh(actor)
    local a, b = long_axis(mesh)
    -- The aim in the mesh's space: the root is the aim turned by the root's
    -- relative turn, so the aim is the root's X turned back
    local turn = root.RelativeRotation
    local aim_root = kml:LessLess_VectorRotator(vec(1, 0, 0), turn)
    local aim = kml:LessLess_VectorRotator(aim_root, mesh.RelativeRotation)
    local near, far = a, b
    if dot(b, aim) < dot(a, aim) then
        near, far = b, a
    end
    local s = mesh.RelativeScale3D
    local axis_scale = len(vec((far.X - near.X) * s.X, (far.Y - near.Y) * s.Y, (far.Z - near.Z) * s.Z)) / len(sub(far, near))
    return add(near, mul(norm(sub(far, near)), tool.grip_from_end / axis_scale))
end

-- Put the root's turn into UEVR's rotation offset. UEVR applies hand *
-- inverse(offset), and reads a Vector3f as (pitch, yaw, roll) in radians,
-- UE style (glm::yawPitchRoll(-y, x, -z)). Only a yaw turn is handled; the
-- inverse of a yaw is its negative.
local function turn_offset(actor, root, state)
    local turn = root.RelativeRotation
    if math.abs(turn.Pitch) > 0.1 or math.abs(turn.Roll) > 0.1 then
        log(class_name(actor) .. ": root turn " .. rot_str(turn) .. " has pitch or roll; only its yaw is kept")
    end
    if math.abs(turn.Yaw) < 0.1 then
        return
    end
    state:set_rotation_offset(Vector3f.new(0.0, math.rad(-turn.Yaw), 0.0))
end

local function attach_to_hand(comp)
    local state = UEVR_UObjectHook.get_or_add_motion_controller_state(comp)
    if state == nil then
        error("no motion controller state")
    end
    state:set_hand(RIGHT_HAND)
    state:set_permanent(true)
    return state
end

-- Shift the root's children so the grip point (or the main mesh's pivot)
-- sits on the root, which UEVR keeps on the hand. Runs every frame, as the
-- game animates parts.
local function place_grip(actor, root, grip, lower)
    local mesh = main_mesh(actor)
    if mesh == nil then
        return
    end
    local p = grip and to_world(mesh, grip) or mesh:K2_GetComponentLocation()
    local d = kml:LessLess_VectorRotator(sub(p, root:K2_GetComponentLocation()), root:K2_GetComponentRotation())
    -- The target is `lower` below the hand, so the offset from it is that
    -- much higher
    d = vec(d.X, d.Y, d.Z + (lower or 0.0))
    if math.abs(d.X) + math.abs(d.Y) + math.abs(d.Z) < 1.0 then
        return -- already in place (within 1 cm)
    end

    for _, child in ipairs(children(root)) do
        local rel = child.RelativeLocation
        child:K2_SetRelativeLocation(vec(rel.X - d.X, rel.Y - d.Y, rel.Z - d.Z), false, hit_result, true)
    end
end

-- An invisible part on the player that UEVR keeps on the right hand, to
-- know where the hand is in the world (as of the last frame)
local function marker(pawn)
    if hand_marker ~= nil and UEVR_UObjectHook.exists(hand_marker) then
        return hand_marker
    end
    hand_marker = api:add_component_by_class(pawn, scene_c)
    if hand_marker == nil then
        error("couldn't add the hand marker")
    end
    attach_to_hand(hand_marker)
    return hand_marker
end

-- The mop's handle: its longest mesh
local function mop_handle(actor)
    local addr = actor:get_address()
    if mop_handles[addr] ~= nil and UEVR_UObjectHook.exists(mop_handles[addr]) then
        return mop_handles[addr]
    end
    local best, best_len = nil, 0
    for _, c in ipairs(actor:K2_GetComponentsByClass(mesh_c) or {}) do
        local ok, _, _, length = pcall(long_axis, c)
        if ok and length > best_len then
            best, best_len = c, length
        end
    end
    mop_handles[addr] = best
    return best
end

-- The mop's shape in its root's frame, measured once when it appears (the
-- game re-places the head relative to the root every frame, always the
-- same): the handle's direction (head to top) as a turn, and the grip
-- point on the handle. Placing the mop from this alone, rather than from
-- where the game last left its parts, can't feed back into itself.
local function mop_shape(actor, root, tool)
    local head = find_part(actor, tool.head)
    local handle = mop_handle(actor)
    if head == nil or handle == nil then
        error("no head or handle")
    end
    local a, b, _, _, axis = long_axis(handle)
    local wa, wb = to_world(handle, a), to_world(handle, b)
    local h = head:K2_GetComponentLocation()
    local top = len(sub(wa, h)) > len(sub(wb, h)) and wa or wb
    -- Which way along the handle's own axis its top is
    local top_sign = len(sub(wb, h)) >= len(sub(wa, h)) and 1.0 or -1.0
    local rl, rr = root:K2_GetComponentLocation(), root:K2_GetComponentRotation()
    local head_r = kml:LessLess_VectorRotator(sub(h, rl), rr)
    local top_r = kml:LessLess_VectorRotator(sub(top, rl), rr)
    local grip_r = add(top_r, mul(norm(sub(head_r, top_r)), tool.grip_from_top))
    return { grip = grip_r, head = head, handle = handle, axis = axis, top_sign = top_sign }
end

-- The grip point on the handle as it is now in the world: grip_from_top
-- down from the handle's end farthest from the head
local function measured_grip(shape, tool)
    local a, b = long_axis(shape.handle)
    local wa, wb = to_world(shape.handle, a), to_world(shape.handle, b)
    local h = shape.head:K2_GetComponentLocation()
    local top = len(sub(wa, h)) > len(sub(wb, h)) and wa or wb
    return add(top, mul(norm(sub(h, top)), tool.grip_from_top))
end

-- Turn and move the whole mop so its handle runs from the hand down along
-- the aim, tilted toward the floor, with the hand grip_from_top down it
local function hold_mop(pawn, root, tool, shape)
    local m = marker(pawn)
    local hand = m:K2_GetComponentLocation()
    local aim = norm(kml:Conv_RotatorToVector(m:K2_GetComponentRotation()))

    -- Tilt the aim down: toward "down" as seen from the hand's aim
    local up = vec(0, 0, 1)
    local hand_up = sub(up, mul(aim, dot(up, aim)))
    if len(hand_up) < 1e-3 then
        hand_up = vec(1, 0, 0)
    end
    hand_up = norm(hand_up)
    local t = math.rad(tool.tilt)
    local down_handle = add(mul(aim, math.cos(t)), mul(hand_up, -math.sin(t))) -- hand to head

    -- The game moves the handle relative to the head every frame (the angle
    -- between them changed from sample to sample), so the mop isn't rigid:
    -- turning the whole mop to aim the handle fought the game and spun the
    -- head. Instead, after the game's update, set the two parts directly.
    local wanted = norm(mul(down_handle, -1)) -- head to hand

    -- 1. The head flat, turned with the aim's heading as the game lays it
    local heading = math.deg(math.atan(aim.Y, aim.X))
    root:K2_SetWorldRotation(kml:MakeRotator(0.0, 0.0, heading + MOP_HEAD_YAW), false, hit_result, true)

    -- 2. The handle's own long axis from the head toward the hand
    local along = mul(wanted, shape.top_sign)
    local side = norm(cross(up, wanted))
    local turn
    if shape.axis == "X" then
        turn = kml:MakeRotFromXZ(along, up)
    elseif shape.axis == "Y" then
        turn = kml:MakeRotFromYZ(along, up)
    else
        turn = kml:MakeRotFromZX(along, side)
    end
    shape.handle:K2_SetWorldRotation(turn, false, hit_result, true)

    -- Move: the grip point, as measured on the handle now, onto the hand
    -- (as version 9 did, which followed the hand correctly)
    local grip = measured_grip(shape, tool)
    root:K2_SetWorldLocation(add(root:K2_GetComponentLocation(), sub(hand, grip)), false, hit_result, true)
end

-- Tool roots hanging from a component: { root, actor, tool }
local function tools_on(parent, only_classes, skip_owner)
    local found = {}
    for _, child in ipairs(children(parent)) do
        local owner = nil
        pcall(function() owner = child:GetOwner() end)
        if owner ~= nil and owner:get_address() ~= skip_owner:get_address() then
            local cls = class_name(owner)
            if (only_classes == nil or only_classes[cls]) and not NOT_TOOLS[cls] then
                table.insert(found, { root = child, actor = owner, tool = TOOLS[cls] or {} })
            end
        end
    end
    return found
end

local function set_up_tool(pawn, actor, root, tool)
    if tool.mop then
        marker(pawn)
        return { shape = mop_shape(actor, root, tool) }
    end
    scale_tool(actor, tool)
    local grip = nil
    if tool.grip_from_end ~= nil then
        local ok, g = pcall(grip_point, actor, root, tool)
        if ok then
            grip = g
        else
            log("couldn't measure " .. class_name(actor) .. ": " .. tostring(g))
        end
    end
    local state = attach_to_hand(root)
    turn_offset(actor, root, state)
    return { grip = grip }
end

local function block_jump(pawn, block)
    if block then
        if saved_jumps ~= nil and saved_jumps.pawn == pawn:get_address() then
            if pawn.JumpMaxCount ~= 0 then
                pawn.JumpMaxCount = 0 -- the game set it back
            end
            return
        end
        saved_jumps = { pawn = pawn:get_address(), count = pawn.JumpMaxCount }
        pawn.JumpMaxCount = 0
    elseif saved_jumps ~= nil then
        if saved_jumps.pawn == pawn:get_address() then
            pawn.JumpMaxCount = saved_jumps.count
        end
        saved_jumps = nil
    end
end

local function check(pawn, controller, delta)
    local cam = controller.PlayerCameraManager
    mops = {}
    step = "list held"
    local held = tools_on(cam:K2_GetRootComponent(), nil, cam)
    for _, h in ipairs(tools_on(pawn:K2_GetRootComponent(), CAPSULE_TOOLS, pawn)) do
        table.insert(held, h)
    end

    local no_jump = false
    for _, h in ipairs(held) do
        if NO_JUMP_TOOLS[class_name(h.actor)] and is_visible(h.root) then
            no_jump = true
        end
    end
    step = "block jump"
    local ok_j, err_j = pcall(block_jump, pawn, no_jump)
    if not ok_j and not logged_errors["jump: " .. tostring(err_j)] then
        logged_errors["jump: " .. tostring(err_j)] = true
        log("couldn't change jumping: " .. tostring(err_j))
    end

    for _, h in ipairs(held) do
        local root, actor, tool = h.root, h.actor, h.tool

        if ATTACH then
            local addr = root:get_address()
            if set_up[addr] == nil then
                step = "set up " .. class_name(actor)
                local ok, info = pcall(set_up_tool, pawn, actor, root, tool)
                if not ok then
                    log("couldn't set up " .. class_name(actor) .. ": " .. tostring(info))
                end
                set_up[addr] = ok and info or { failed = true } -- one try each
            end
            if not set_up[addr].failed then
                step = "place " .. class_name(actor)
                if tool.mop then
                    -- Moved later in the frame, once the game has moved the
                    -- player and UEVR has put the marker on the hand
                    table.insert(mops, { pawn = pawn, root = root, tool = tool, shape = set_up[addr].shape })
                else
                    place_grip(actor, root, set_up[addr].grip, tool.lower)
                end
            end
        end
    end
end

local ok, err = pcall(function()
    scene_c = api:find_uobject("Class /Script/Engine.SceneComponent")
    mesh_c = api:find_uobject("Class /Script/Engine.StaticMeshComponent")
    kml = api:find_uobject("Class /Script/Engine.KismetMathLibrary"):get_class_default_object()
    hit_result = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
end)
if not ok then
    log("init error: " .. tostring(err))
    failed = true
end

-- Every frame, so a newly selected tool is moved before it's seen at the camera
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if failed then
        return
    end
    local ok, err = pcall(function()
        local controller = api:get_player_controller(0)
        local pawn = api:get_local_pawn(0)
        if controller == nil or pawn == nil then
            return
        end
        check(pawn, controller, delta)
    end)
    if not ok then
        local key = step .. ": " .. tostring(err)
        if not logged_errors[key] then
            logged_errors[key] = true
            log("error at '" .. key .. "'")
        end
    end
end)

-- The mop is placed where UEVR places its attachments: after the game has
-- moved everything this frame, and after UEVR has put the hand marker on
-- the hand (it does that before the second view's stereo offset, so this
-- runs after it)
uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if failed or view_index % 2 ~= 1 then
        return
    end
    for _, m in ipairs(mops) do
        local ok, err = pcall(function()
            if not UEVR_UObjectHook.exists(m.root) then
                return
            end
            step = "hold mop"
            hold_mop(m.pawn, m.root, m.tool, m.shape)
        end)
        if not ok then
            local key = step .. ": " .. tostring(err)
            if not logged_errors[key] then
                logged_errors[key] = true
                log("error at '" .. key .. "'")
            end
        end
    end
end)

-- Don't leave jumping off if the scripts are reloaded with the scanner out
uevr.sdk.callbacks.on_script_reset(function()
    pcall(function()
        local pawn = api:get_local_pawn(0)
        if pawn ~= nil then
            block_jump(pawn, false)
        end
    end)
end)

log("script loaded")
