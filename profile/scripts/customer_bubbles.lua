-- Customer thought bubbles in the world instead of on the HUD.
--
-- Confirmed from the log (2026-10-31): each customer (AI_CustomerNew_C) has a
-- WidgetComponent "ReactionW" (widget WChild_BubbleReview_C, 450 x 100, 120 cm
-- above its CollisionCylinder) in Screen space, hidden until the customer
-- reacts. Screen-space widgets are drawn on the 2D UI layer, which UEVR shows
-- on its flat panel: hence confined to the HUD area and tiny far away.
--
-- Versions 1 and 2 switched ReactionW itself to world space. It stopped
-- drawing on the HUD but never drew in the world: version 2's log showed the
-- game showing bubbles with a material but "render target none". A widget
-- component only gets its world-space renderer when it's registered in world
-- space; switching the setting afterwards doesn't create one, and Lua can't
-- re-register a component.
--
-- Version 3: ReactionW is still switched to world space (so it stops drawing
-- on the HUD, and draws nothing). A new WidgetComponent is added to the
-- customer, set to world space BEFORE it's registered (deferred
-- add_component_by_class, then the actor's FinishAddComponent), and given the
-- game's own bubble widget, so it shows whatever the game puts in it. Each
-- frame it copies ReactionW's visibility, faces the camera and is sized by
-- distance.
--
-- Everything is put back on script reset.

local api = uevr.api
local functions = uevr.params.functions

local CONVERT = true
-- Size in world space: cm per widget pixel at 1 m away. Like the aim dot, the
-- size grows with the square root of distance (a fixed physical size gets
-- tiny far away; a fixed on-screen size looks huge in VR).
-- v5: up close was great (bubble about 47 cm wide at 2 m) and ~90 cm at 10 m
-- looked right, both with the game's own shrink still on. With that shrink
-- undone, 0.075 and 0.5 gave about 47 cm at 2 m, 105 cm at 10 m, 130 cm at 15 m.
-- v7: good at the till, too small far away. 0.066 and 0.65 keep about 47 cm
-- at 2 m and give about 133 cm at 10 m, 173 cm at 15 m, 202 cm at 20 m.
local CM_PER_PIXEL = 0.066
-- How fast it grows with distance: size ~ distance ^ DISTANCE_GROWTH.
-- 1.0 would keep a fixed on-screen size.
local DISTANCE_GROWTH = 0.65
local MIN_DISTANCE = 100.0 -- cm; no shrinking closer than this
-- v3 sat at the game's spot (120 cm above the capsule centre) and looked
-- behind the customer's head: lift it and bring it toward you
local RAISE = 20.0 -- cm up (30 was a little high)
local TOWARD_YOU = 30.0 -- cm toward the camera
-- Settings copied from the game's bubble onto the copy before it's registered
local COPY_PROPS = { "BlendMode", "bApplyGammaCorrection", "OpacityFromTexture", "TranslucentMaterial",
    "TranslucentMaterial_OneSided", "OpaqueMaterial", "OpaqueMaterial_OneSided", "MaskedMaterial",
    "MaskedMaterial_OneSided", "TimingPolicy", "bUseInvalidationInWorldSpace", "TickWhenOffscreen" }
-- The game shrinks the bubble's contents with distance through the render
-- scale of one inner widget, Border_36 (v5 log: 0.14 at 17 m, 0.29 at 14 m,
-- 0.53 at 9.5 m, 0.86 at 3 m). Overlay_24 (the root) also changes scale (0.7
-- with opacity 0 between pops: each thought shows for about 5 s).
-- History: v6/v7 reset Border_36 to 1 every frame, but the game re-shrinks it
-- on some frames, so the bubble flicked between two sizes. v8 hooked
-- SetRenderScale/SetRenderTransform to undo each call and the game crashed
-- two minutes in (likely the hooks: every widget scale change in the game went
-- through Lua). v9 scaled the bubble widget by the inverse instead, but the
-- game takes Border_36 to exactly 0 beyond about 8 m (its bubble draw
-- distance), which can't be undone that way: far bubbles weren't drawn.
-- Version 10 resets Border_36 to 1 every frame again, and fixes v6's flicker
-- with tick order: the copy lives on the player and the customer (actor, its
-- components and its AI controller) is made to tick after the copy, so each
-- frame goes: our reset -> the copy draws -> the game re-shrinks (undone next
-- frame before the draw). The scale lines count how often the game re-shrank.
-- v10 result: the tick order didn't help; the game still re-shrank Border_36
-- on about half the frames (every other frame), so the bubble still doubled.
-- Version 11 (SELECTIVE_REDRAW): the copy only redraws when asked
-- (bManuallyRedraw) and keeps its last picture otherwise. It's asked to
-- redraw on the frame after a game re-shrink (just reset to full size, and the
-- game most likely leaves it alone this frame), so it should always show a
-- full-size picture, updated about 45 times a second. If more than
-- MAX_SKIPPED_FRAMES pass without a redraw, it redraws anyway.
local UNDO_GAME_SHRINK = true
local SHRINK_WIDGET = "Border_36"
-- Off since v12: the game's shrink comes from a timer (CheckDistance, read
-- from the widget's Blueprint in the pak), and timers run after the copy has
-- drawn for the frame, so redrawing every frame shows the full-size reset.
local SELECTIVE_REDRAW = false
-- v12: the "draw distance" is the game's bubble material
-- (Widget3DPassThroughOpacity, read from the pak): it fades out between
-- MinDistance 800 and MaxDistance 900 cm (dithered). It only acts in world
-- space, so flat play never sees it. These are set on each copy's material
-- instance instead.
local FADE_MIN_DISTANCE = 100000.0 -- cm
local FADE_MAX_DISTANCE = 100100.0 -- cm
local MAX_SKIPPED_FRAMES = 3
local scale_2d = nil -- reused Vector2D
local SCAN_INTERVAL = 1.0 -- seconds
local OWNER_PREFIX = "AI_Customer" -- owner classes whose widgets are moved
local LOG_MAX = 30 -- error lines

local widget_comp_c, actor_comp_c, kml, hit_result
local tracked = {} -- ReactionW address -> { game, copy, owner, owner_name, widget, state }
local seen = {} -- address -> true (already checked)
local logs = 0
local since_scan = SCAN_INTERVAL
local logged_errors = {}
local step = "init"

local function log(msg)
    functions.log_info("[customer_bubbles] " .. msg)
end

local function log_limited(msg)
    if logs < LOG_MAX then
        logs = logs + 1
        log(msg)
    end
end

local function log_error(key)
    if not logged_errors[key] then
        logged_errors[key] = true
        log("error at '" .. key .. "'")
    end
end

local function name_of(obj)
    if obj == nil then return "none" end
    local ok, n = pcall(function() return obj:get_fname():to_string() end)
    return ok and n or "?"
end

local function class_name(obj)
    if obj == nil then return "none" end
    local ok, n = pcall(function() return obj:get_class():get_fname():to_string() end)
    return ok and n or "?"
end

local function vec(x, y, z) return Vector3d.new(x, y, z) end

local function get(obj, fn)
    local ok, v = pcall(fn, obj)
    if ok then return v end
    return nil
end

local function try(label, fn)
    local ok, err = pcall(fn)
    if not ok then log_limited(label .. " failed: " .. tostring(err)) end
    return ok
end

-- New world-space widget component on the customer, showing the game's widget
local function make_copy(owner, game, widget)
    local copy = api:add_component_by_class(owner, widget_comp_c, true) -- deferred: not registered yet
    if copy == nil then
        log_limited("couldn't add a widget component to " .. name_of(owner))
        return nil
    end
    try("SetWidgetSpace", function() copy:SetWidgetSpace(0) end)
    -- DrawSize is an IntPoint (SetDrawSize wants a Vector2D): set the fields
    try("DrawSize", function()
        copy.DrawSize.X = game.DrawSize.X
        copy.DrawSize.Y = game.DrawSize.Y
    end)
    try("SetPivot", function() copy:SetPivot(game.Pivot) end)
    try("SetTwoSided", function() copy:SetTwoSided(true) end)
    -- Take the game's look settings (v3 got the default masked material: the
    -- text came out light instead of black). Set before registering, which
    -- picks the material.
    for _, p in ipairs(COPY_PROPS) do
        local ok, v = pcall(function() return game[p] end)
        if ok and v ~= nil then
            pcall(function() copy[p] = v end)
        end
    end
    for _, p in ipairs({ "TintColorAndOpacity", "BackgroundColor" }) do
        pcall(function()
            for _, f in ipairs({ "R", "G", "B", "A" }) do copy[p][f] = game[p][f] end
        end)
    end
    try("SetCollisionEnabled", function() copy:SetCollisionEnabled(0) end)
    try("SetGenerateOverlapEvents", function() copy:SetGenerateOverlapEvents(false) end)
    try("SetWidget", function() copy:SetWidget(widget) end)
    -- Only redraw when asked (see SELECTIVE_REDRAW); keeps the last picture
    if SELECTIVE_REDRAW then
        try("bManuallyRedraw", function() copy.bManuallyRedraw = true end)
    end
    -- The game's bubble uses its own material (MID_Widget3DPassThroughOpacity,
    -- an override, not one of the blend-mode slots); v4's masked material
    -- drew the black text cyan
    try("SetMaterial", function()
        local m = game:GetMaterial(0)
        if m ~= nil then
            copy:SetMaterial(0, m)
        end
    end)
    -- Manual attachment: not attached to the host; placed in the world each frame
    local finished = try("FinishAddComponent", function()
        owner:FinishAddComponent(copy, true, game:GetRelativeTransform())
    end)
    if not finished then
        try("K2_DestroyComponent", function() copy:K2_DestroyComponent(copy) end)
        return nil
    end
    return copy
end

-- Make the customer, its components and its AI controller tick after the
-- copy, so the copy draws before the game re-shrinks Border_36 each frame
-- Push the material's distance fade out of the way on the copy's material
-- instance (re-applied if the component makes a new one)
local function set_fade(t)
    local mid = get(t.copy, function(c) return c:GetMaterialInstance() end)
    if mid == nil then return end
    local a = mid:get_address()
    if t.fade_mid == a then return end
    local ok, err = pcall(function()
        mid:SetScalarParameterValue("MinDistance", FADE_MIN_DISTANCE)
        mid:SetScalarParameterValue("MaxDistance", FADE_MAX_DISTANCE)
    end)
    if ok then
        t.fade_mid = a
    else
        log_error("couldn't change the bubble material's fade: " .. tostring(err))
    end
end

local function order_ticks(customer, copy)
    local n = 0
    if try("customer tick order", function() customer:AddTickPrerequisiteComponent(copy) end) then n = n + 1 end
    local comps = get(customer, function(c) return c:K2_GetComponentsByClass(actor_comp_c) end)
    if type(comps) == "table" then
        for _, c in ipairs(comps) do
            if pcall(function() c:AddTickPrerequisiteComponent(copy) end) then n = n + 1 end
        end
    end
    local ctrl = get(customer, function(c) return c:GetController() end)
    if ctrl ~= nil and pcall(function() ctrl:AddTickPrerequisiteComponent(copy) end) then n = n + 1 end
    return n
end

local function convert(game, owner)
    local widget = get(game, function(c) return c:GetUserWidgetObject() end)
    if widget == nil then return end
    game:SetWidgetSpace(0) -- stops it drawing on the HUD
    -- Re-set the widget now so the game's component sets up its (never drawn)
    -- window straight away, before the copy takes the widget
    pcall(function()
        game:SetWidget(nil)
        game:SetWidget(widget)
    end)
    -- The copy lives on the player, not the customer: a customer's own
    -- components may already be set to tick after it, which would make the
    -- tick order below a loop
    local host = api:get_local_pawn(0)
    if host == nil then return end
    local copy = make_copy(host, game, widget)
    if copy ~= nil then order_ticks(owner, copy) end
    tracked[game:get_address()] = { game = game, copy = copy, owner = owner, owner_name = name_of(owner), widget = widget,
        frames = 0, reshrunk = 0, redraws = 0, since_redraw = 0 }
end

local function scan()
    for _, comp in ipairs(UEVR_UObjectHook.get_objects_by_class(widget_comp_c, false)) do
        local a = comp:get_address()
        if not seen[a] then
            local owner = get(comp, function(c) return c:GetOwner() end)
            if owner ~= nil then -- unowned ones are Blueprint templates; check again later
                seen[a] = true
                if CONVERT and class_name(owner):sub(1, #OWNER_PREFIX) == OWNER_PREFIX
                    and get(comp, function(c) return c:GetWidgetSpace() end) == 1 then
                    convert(comp, owner)
                end
            end
        end
    end
end

-- Render scale (x, y) of a widget, or nil
local function render_scale(w)
    if w == nil then return nil end
    local ok, x, y = pcall(function() return w.RenderTransform.Scale.X, w.RenderTransform.Scale.Y end)
    if ok then return x, y end
    return nil
end

local function root_of(widget)
    return get(widget, function(w) return w.WidgetTree.RootWidget end)
end

-- The inner widget the game shrinks (found by name, cached)
local function find_named(w, name, depth)
    if w == nil then return nil end
    if name_of(w) == name then return w end
    if depth >= 4 then return nil end
    local kids = get(w, function(v) return v:GetAllChildren() end)
    if type(kids) == "table" then
        for _, k in ipairs(kids) do
            local f = find_named(k, name, depth + 1)
            if f ~= nil then return f end
        end
    end
    return nil
end

local logged_scale_error = false

-- Border_36's render scale as the game left it, then set back to 1. With the
-- tick order (order_ticks) the copy draws before the game re-shrinks it.
local function hold_full_size(t)
    if t.shrinker == nil then
        t.shrinker = find_named(root_of(t.widget), SHRINK_WIDGET, 0)
        if t.shrinker == nil then return 1.0 end
    end
    local x = render_scale(t.shrinker) or 1.0
    if scale_2d ~= nil and math.abs(x - 1.0) > 0.001 then
        local ok, err = pcall(function()
            scale_2d.X = 1.0
            scale_2d.Y = 1.0
            t.shrinker:SetRenderScale(scale_2d)
        end)
        if not ok and not logged_scale_error then
            logged_scale_error = true
            log("couldn't set " .. SHRINK_WIDGET .. " back to full size: " .. tostring(err))
        end
    end
    return x
end

local function drop(a, t)
    tracked[a] = nil
    if t.copy ~= nil then
        pcall(function()
            t.copy:SetWidget(nil)
            t.copy:K2_DestroyComponent(t.copy)
        end)
    end
end

local function place_one(a, t, cam_loc)
    local ok, loc = pcall(function() return t.game:K2_GetComponentLocation() end)
    if not ok or loc == nil or (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then
        drop(a, t) -- customer gone (the copy is on the player, so remove it)
        return
    end
    if t.copy == nil then return end
    local copy = t.copy
    set_fade(t)
    local vis = get(t.game, function(c) return c:IsVisible() end) == true
    copy:SetVisibility(vis, false)

    loc = vec(loc.X, loc.Y, loc.Z + RAISE)
    local dx, dy, dz = cam_loc.X - loc.X, cam_loc.Y - loc.Y, cam_loc.Z - loc.Z
    local raw = math.sqrt(dx * dx + dy * dy + dz * dz)
    local dist = math.max(raw, MIN_DISTANCE)
    local s = CM_PER_PIXEL * (dist / 100.0) ^ DISTANCE_GROWTH
    local gs = 1.0
    if UNDO_GAME_SHRINK and vis then
        gs = hold_full_size(t)
        t.frames = t.frames + 1
        local game_set = math.abs(gs - 1.0) > 0.001
        if game_set then t.reshrunk = t.reshrunk + 1 end
        -- The game re-shrinks on about every other frame. If it did last
        -- frame, it most likely won't this frame: draw now (full size, just
        -- reset). Otherwise keep the last picture, unless it's getting old
        -- (the pattern broke) or the bubble just appeared.
        if SELECTIVE_REDRAW then
            t.since_redraw = t.since_redraw + 1
            if game_set or t.since_redraw > MAX_SKIPPED_FRAMES or t.frames == 1 then
                local ok_r, err_r = pcall(function() copy:RequestRedraw() end)
                if ok_r then
                    t.redraws = t.redraws + 1
                    t.since_redraw = 0
                else
                    log_error("RequestRedraw: " .. tostring(err_r))
                end
            end
        end
    end
    copy:SetWorldScale3D(vec(s, s, s))

    if not vis then
        t.since_redraw = MAX_SKIPPED_FRAMES + 1 -- redraw as soon as it shows again
    end

    local rot = kml:FindLookAtRotation(loc, cam_loc)
    if raw > 1.0 then
        local k = math.min(TOWARD_YOU, raw * 0.5) / raw
        loc = vec(loc.X + dx * k, loc.Y + dy * k, loc.Z + dz * k)
    end
    copy:K2_SetWorldLocationAndRotation(loc, rot, false, hit_result, true)
end

-- Copy the game's visibility, face the camera and size by distance, every
-- frame
local function place(cam_loc)
    for a, t in pairs(tracked) do
        local ok, err = pcall(place_one, a, t, cam_loc)
        if not ok then
            log_error("place " .. t.owner_name .. ": " .. tostring(err))
            drop(a, t) -- e.g. the player was replaced and took the copy with it
            -- let the next scan give this customer a new copy
            pcall(function() t.game:SetWidgetSpace(1) end)
            seen[a] = nil
        end
    end
end

local function tick(delta)
    local controller = api:get_player_controller(0)
    if controller == nil then return end

    since_scan = since_scan + delta
    if since_scan >= SCAN_INTERVAL then
        since_scan = 0.0
        step = "scan"
        scan()
    end

    if CONVERT and next(tracked) ~= nil then
        step = "place"
        local cam_loc = controller.PlayerCameraManager:GetCameraLocation()
        place(cam_loc)
    end
end

local function restore()
    for _, t in pairs(tracked) do
        pcall(function()
            if t.copy ~= nil then
                t.copy:SetWidget(nil)
                t.copy:K2_DestroyComponent(t.copy)
            end
            pcall(function() if scale_2d then scale_2d.X = 1.0; scale_2d.Y = 1.0; t.widget:SetRenderScale(scale_2d) end end)
            t.game:SetWidgetSpace(1)
            t.game:SetWidget(nil)
            t.game:SetWidget(t.widget)
        end)
    end
    tracked = {}
end

local ok, err = pcall(function()
    widget_comp_c = api:find_uobject("Class /Script/UMG.WidgetComponent")
    actor_comp_c = api:find_uobject("Class /Script/Engine.ActorComponent")
    kml = api:find_uobject("Class /Script/Engine.KismetMathLibrary"):get_class_default_object()
    hit_result = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
    local ok_2d, err_2d = pcall(function()
        scale_2d = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Vector2D"))
        scale_2d.X = 1.0
        scale_2d.Y = 1.0
    end)
    if not ok_2d then
        scale_2d = nil
        log("couldn't make a Vector2D; not undoing the game's shrink: " .. tostring(err_2d))
    end
    if widget_comp_c == nil then error("no WidgetComponent class") end
end)
if not ok then
    log("init error: " .. tostring(err))
    return
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local ok, err = pcall(tick, delta)
    if not ok then
        log_error(step .. ": " .. tostring(err))
    end
end)

uevr.sdk.callbacks.on_script_reset(function()
    restore()
end)

log(string.format("script loaded, version 12 (CONVERT %s, %.3f cm per pixel at 1 m, growth %.2f, raise %.0f, toward you %.0f)", tostring(CONVERT), CM_PER_PIXEL, DISTANCE_GROWTH, RAISE, TOWARD_YOU))
