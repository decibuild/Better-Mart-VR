-- Shows a small dot where the game's aim lands, so you can see what the
-- right controller is pointing at, and hides the game's centre reticle (which
-- stays fixed in your view and no longer matches your aim). The dot is hidden
-- while a menu or the 2D screen is up.

local api = uevr.api
local functions = uevr.params.functions

local MAX_DISTANCE = 5000.0 -- cm
-- Dot diameter in cm at 1m away. It grows with the square root of distance:
-- keeping the same on-screen size reads as "huge" far away in VR, while a
-- fixed physical size vanishes.
local DOT_SIZE = 1.2
local DOT_COLOR = { R = 1.0, G = 1.0, B = 1.0 } -- white

local RETICLE_SCAN_INTERVAL = 5.0 -- seconds

local dot = nil
local dot_pawn = nil
local failed = false
local step = "init"

local reticles = {}
local seen_images = {}
local logged_scan_error = false
local logged_tint_error = false
local since_scan = RETICLE_SCAN_INTERVAL

local ksl, kml, ksl_string, gameplay_statics, hit_result, sweep_result, no_color
local sbl, zero_2d, user_widget_c

local function log(msg)
    functions.log_info("[controller_pointer] " .. msg)
end

local function find_static(name)
    local c = api:find_uobject(name)
    if c == nil then
        error("missing " .. name)
    end
    return c:get_class_default_object()
end

local function init()
    ksl = find_static("Class /Script/Engine.KismetSystemLibrary")
    kml = find_static("Class /Script/Engine.KismetMathLibrary")
    ksl_string = find_static("Class /Script/Engine.KismetStringLibrary")
    local hit_c = api:find_uobject("ScriptStruct /Script/Engine.HitResult")
    hit_result = StructObject.new(hit_c)
    sweep_result = StructObject.new(hit_c)
    no_color = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
    gameplay_statics = find_static("Class /Script/Engine.GameplayStatics")
    sbl = find_static("Class /Script/UMG.SlateBlueprintLibrary")
    zero_2d = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Vector2D"))
    user_widget_c = api:find_uobject("Class /Script/UMG.UserWidget")
end

local function find_mesh()
    for _, name in ipairs({ "StaticMesh /Engine/BasicShapes/Sphere.Sphere", "StaticMesh /Engine/BasicShapes/Cube.Cube" }) do
        local mesh = api:find_uobject(name)
        if mesh ~= nil then
            return mesh
        end
    end
    return nil
end

-- An unlit or emissive engine material shows the same brightness everywhere;
-- a lit one goes dark in shadow
local function find_bright_material()
    local mat_c = api:find_uobject("Class /Script/Engine.Material")
    for _, m in ipairs(UEVR_UObjectHook.get_objects_by_class(mat_c, false)) do
        local name = m:get_full_name()
        if name:find("/Engine/") and (name:find("Emissive") or name:find("Unlit")) then
            return m
        end
    end
    return nil
end

local function color_dot(comp)
    local mat = find_bright_material()
    local mid = comp:CreateDynamicMaterialInstance(0, mat, ksl_string:Conv_StringToName("PointerDot"))
    if mid == nil then
        log("couldn't create dot material, leaving default")
        return
    end

    local color = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
    color.R = DOT_COLOR.R
    color.G = DOT_COLOR.G
    color.B = DOT_COLOR.B
    color.A = 1.0
    -- Set whichever of these the material happens to have
    for _, param in ipairs({ "Color", "BaseColor", "EmissiveColor", "Emissive", "Tint" }) do
        mid:SetVectorParameterValue(ksl_string:Conv_StringToName(param), color)
    end
end

local function create_dot(pawn)
    local mesh = find_mesh()
    if mesh == nil then
        error("no sphere or cube mesh loaded")
    end

    local comp = api:add_component_by_class(pawn, api:find_uobject("Class /Script/Engine.StaticMeshComponent"))
    if comp == nil then
        error("failed to add dot component")
    end

    -- Movable, so the engine knows it moves every frame and TSR doesn't smear it
    comp:SetMobility(2)
    comp:SetStaticMesh(mesh)
    comp:SetCollisionEnabled(0)
    comp:SetCastShadow(false)
    local ok, err = pcall(color_dot, comp)
    if not ok then
        log("dot colour error: " .. tostring(err))
    end
    return comp
end

local function texture_name(img)
    local ok, res = pcall(function() return img.Brush.ResourceObject end)
    if ok and res ~= nil then
        return res:get_fname():to_string()
    end
    return "none"
end

-- The reticle is layered (a filled dot, plus a ring that grows and shrinks
-- over things you can use), and the layers have no useful names. What they
-- share is sitting dead centre on screen during play, so find them by position.
local RETICLE_HUD_WIDGETS = { WB_Gameplay_UI_C = true }
local RETICLE_CENTRE_TOLERANCE = 0.03 -- fraction of the screen
local RETICLE_MAX_HEIGHT = 0.25       -- fraction of the screen height

-- The outermost widget containing this one (e.g. WB_Gameplay_UI_C)
local function top_user_widget(widget)
    local top = nil
    local obj = widget:get_outer()
    while obj ~= nil do
        if obj:is_a(user_widget_c) then
            top = obj
        end
        obj = obj:get_outer()
    end
    return top
end

-- Top-left corner and size in desktop pixels, from the last frame's layout
local function abs_rect(widget)
    local geom = widget:GetCachedGeometry()
    local pos = sbl:LocalToAbsolute(geom, zero_2d)
    local size = sbl:GetAbsoluteSize(geom)
    return pos.X, pos.Y, size.X, size.Y
end

-- Centre and height of a widget as fractions of the full-screen widget holding it
local function screen_position(widget, top)
    local x, y, w, h = abs_rect(widget)
    local tx, ty, tw, th = abs_rect(top)
    if w <= 0 or h <= 0 or tw <= 0 or th <= 0 then
        return nil
    end
    return (x + w / 2 - tx) / tw, (y + h / 2 - ty) / th, h / th
end

-- The filled centre dot; found by name in an earlier session
local RETICLE_TEXTURES = { SphereW = true }

-- Find HUD images sitting dead centre and remember them
local function scan_for_reticle()
    local image_c = api:find_uobject("Class /Script/UMG.Image")
    for _, img in ipairs(UEVR_UObjectHook.get_objects_by_class(image_c, false)) do
        local addr = img:get_address()
        if not seen_images[addr] and img:get_full_name():find("Transient") then
            local ok, err = pcall(function()
                local top = top_user_widget(img)
                if top == nil or not top:IsInViewport() then
                    return
                end
                -- The reticle is part of the gameplay HUD; centred images in
                -- other widgets (the rewards menu's "+" icons, item previews)
                -- aren't it
                if not RETICLE_HUD_WIDGETS[top:get_class():get_fname():to_string()] then
                    seen_images[addr] = true
                    return
                end

                local texture = texture_name(img)
                local cx, cy, h = screen_position(img, top)
                if cx == nil then
                    if RETICLE_TEXTURES[texture] then
                        seen_images[addr] = true
                        table.insert(reticles, img)
                    end
                    return
                end

                local centred = math.abs(cx - 0.5) <= RETICLE_CENTRE_TOLERANCE
                    and math.abs(cy - 0.5) <= RETICLE_CENTRE_TOLERANCE and h <= RETICLE_MAX_HEIGHT
                if centred or RETICLE_TEXTURES[texture] then
                    seen_images[addr] = true
                    table.insert(reticles, img)
                end
            end)
            if not ok and not logged_scan_error then
                logged_scan_error = true
                log("reticle position check error: " .. tostring(err))
            end
        end
    end
end

-- The game turns the reticle's visibility back on every frame (it doubles as
-- the mouse cursor in menus), so hide it with opacity instead, and only during
-- play so it still shows as the cursor in menus
-- The filled dot (SphereW) also gets its opacity animated by the game (it
-- fades in over things you can use, e.g. the edge of the till's screen),
-- which runs after this and undid the hiding. So it's also tinted fully
-- transparent; the animation doesn't touch the tint.
local tinted = {} -- image address -> true while tinted transparent
local white = nil

local function set_tint_hidden(img, hidden)
    local addr = img:get_address()
    if hidden and not tinted[addr] then
        img:SetColorAndOpacity(no_color) -- all zero, so alpha 0
        tinted[addr] = true
    elseif not hidden and tinted[addr] then
        if white == nil then
            white = kml:LinearColor_White()
        end
        img:SetColorAndOpacity(white)
        tinted[addr] = nil
    end
end

local function set_reticle_hidden(hidden)
    local opacity = hidden and 0.0 or 1.0
    for i = #reticles, 1, -1 do
        local img = reticles[i]
        if not UEVR_UObjectHook.exists(img) then
            tinted[img:get_address()] = nil
            table.remove(reticles, i)
        else
            if img:GetRenderOpacity() ~= opacity then
                img:SetRenderOpacity(opacity)
            end
            if RETICLE_TEXTURES[texture_name(img)] then
                local ok, err = pcall(set_tint_hidden, img, hidden)
                if not ok and not logged_tint_error then
                    logged_tint_error = true
                    log("couldn't tint the centre dot: " .. tostring(err))
                end
            end
        end
    end
end

local function in_menu(engine, controller, pawn)
    -- Set by auto_2d_screen.lua when the scripts share one Lua state
    if bettermart_mode ~= nil then
        return bettermart_mode ~= "play"
    end

    if controller.bShowMouseCursor == true then
        return true
    end
    local view_target = controller:GetViewTarget()
    if view_target ~= nil and view_target:get_address() ~= pawn:get_address() then
        return true
    end
    -- The pause menu opened with Start shows no cursor, but pauses the game
    local ok, paused = pcall(function() return gameplay_statics:IsGamePaused(engine.GameViewport.World) end)
    return ok and paused == true
end

local function set_shown(shown)
    dot:SetVisibility(shown, false)
end

local function update(engine, delta)
    step = "get pawn"
    local pawn = api:get_local_pawn(0)
    local controller = api:get_player_controller(0)
    if pawn == nil or controller == nil then
        return
    end

    -- Recreate after level loads or when the pawn changes
    if dot == nil or dot_pawn ~= pawn:get_address() or not UEVR_UObjectHook.exists(dot) then
        step = "create dot"
        dot = create_dot(pawn)
        dot_pawn = pawn:get_address()
    end

    step = "check menu"
    local menu = in_menu(engine, controller, pawn)
    pcall(set_reticle_hidden, not menu)

    -- Only scan during play, when the reticle is on screen. Reticle problems
    -- shouldn't take the dot down with them.
    since_scan = since_scan + delta
    if not menu and since_scan >= RETICLE_SCAN_INTERVAL then
        since_scan = 0.0
        local ok, err = pcall(scan_for_reticle)
        if not ok then
            log("reticle scan error: " .. tostring(err))
        end
    end

    if menu then
        step = "hide (menu)"
        set_shown(false)
        return
    end

    step = "aim ray"
    local cam = controller.PlayerCameraManager:GetCameraLocation()
    local dir = kml:Conv_RotatorToVector(controller:GetControlRotation())
    local start = Vector3d.new(cam.X, cam.Y, cam.Z)
    local finish = Vector3d.new(cam.X + dir.X * MAX_DISTANCE, cam.Y + dir.Y * MAX_DISTANCE, cam.Z + dir.Z * MAX_DISTANCE)

    step = "line trace"
    local world = engine.GameViewport.World
    local hit = ksl:LineTraceSingle(world, start, finish, 0, true, { pawn }, 0, hit_result, true, no_color, no_color, 0.0)
    if not hit then
        step = "hide (no hit)"
        set_shown(false)
        return
    end

    step = "place dot"
    local diameter = DOT_SIZE * math.sqrt(hit_result.Distance / 100.0)
    -- Pull back by the dot's radius so it sits on the surface instead of half inside it
    local back = diameter / 2.0 + 0.5
    local p = hit_result.ImpactPoint
    local loc = Vector3d.new(p.X - dir.X * back, p.Y - dir.Y * back, p.Z - dir.Z * back)
    dot:K2_SetWorldLocation(loc, false, sweep_result, false)

    local s = diameter / 100.0
    dot:SetWorldScale3D(Vector3d.new(s, s, s))

    step = "show"
    set_shown(true)
end

local ok, err = pcall(init)
if not ok then
    log("init error: " .. tostring(err))
    failed = true
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if failed then
        return
    end

    local ok, err = pcall(update, engine, delta)
    if not ok then
        log("error at '" .. step .. "': " .. tostring(err))
        failed = true
    end
end)

log("script loaded")
