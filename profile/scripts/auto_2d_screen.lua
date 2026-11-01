-- Switches between normal play and menus. In a menu (game paused, mouse
-- cursor shown, no player pawn, or the view moved to another camera such as a
-- computer), aim goes back to the game and UI_FollowView is turned off, so
-- the menu panel holds still in front of you instead of swinging with the
-- hand. Menus are navigated with the controller as normal. Returns to right
-- controller aim when normal control resumes.
--
-- Set USE_2D_SCREEN to show the computer (when the view moves to it) as a
-- flat 2D screen. The main menu (no pawn) and the computer UI opened from the
-- rewards market stay held-still VR panels either way.

local api = uevr.api
local vr = uevr.params.vr
local functions = uevr.params.functions

local USE_2D_SCREEN = true

-- Menus that show neither a cursor nor pause the game, recognised by their
-- widget class: the pause menu opened with Start, the rewards menu opened
-- with D-pad up, and the computer's UI (also opened from the rewards menu's
-- market, without moving the view to the computer)
local MENU_WIDGETS = { WBP_InGameMenuPause_C = true, WB_NiveauRewardGems_C = true, WB_NewMain_C = true }
local MENU_WIDGET_CHECK_INTERVAL = 0.25 -- seconds

-- Vehicles also move the view to another actor, but you drive them, so they
-- stay in the 3D world ("vehicle" mode) instead of going to the flat screen.
-- Aim is left to the game, so the controller doesn't fight the steering.
-- BP_Gerber_C is the forklift.
local VEHICLE_VIEW_TARGETS = { BP_Gerber_C = true }

local PLAY_AIM = 2 -- right controller
local HEAD_AIM = 1
local GAME_AIM = 0

-- UEVR puts a menu in front of the game's camera, which in play points where
-- the hand points. So when a menu opens, aim with the head for a moment to
-- turn the camera to where you're looking, then hand aim to the game so the
-- camera (and menu) hold still.
local MENU_HEAD_AIM_TIME = 0.2 -- seconds

-- The game's UI (CommonUI) switches to mouse-and-keyboard mode at times,
-- e.g. as you select the till, and button prompts built then show keyboard
-- keys. Played with VR controllers only, so whenever it goes to mouse and
-- keyboard it's put straight back to gamepad.
local HOLD_GAMEPAD = true
local INPUT_MOUSE_AND_KEYBOARD = 0
local INPUT_GAMEPAD = 1
local common_input_c = nil
local common_input = nil
local gamepad_holds = 0
local hold_gamepad_error = false
local head_aim_left = 0.0

local current_mode = nil
local gameplay_statics = nil
local user_widget_c = nil
local menu_widget_open = false
local since_widget_check = MENU_WIDGET_CHECK_INTERVAL

local function log(msg)
    functions.log_info("[auto_2d_screen] " .. msg)
end

local function find_open_menu_widget()
    for _, w in ipairs(UEVR_UObjectHook.get_objects_by_class(user_widget_c, false)) do
        if MENU_WIDGETS[w:get_class():get_fname():to_string()] then
            -- The computer's UI stays on screen, hidden, after you leave it
            local ok, shown = pcall(function() return w:IsInViewport() end)
            -- Only a definite "hidden" rules it out
            local ok_v, visible = pcall(function() return w:IsVisible() end)
            if ok and shown and not (ok_v and visible == false) then
                return true
            end
        end
    end
    return false
end

-- Returns the wanted mode ("2d", "menu" or "play"), plus the reason (for the log)
local function wanted_mode(engine)
    local camera_mode = USE_2D_SCREEN and "2d" or "menu"

    local pawn = api:get_local_pawn(0)
    if pawn == nil then
        return "menu", "no pawn"
    end

    local controller = api:get_player_controller(0)
    if controller == nil then
        return "menu", "no player controller"
    end

    -- Computers zoom in by switching the view to a separate camera actor
    local ok_vt, view_target = pcall(function() return controller:GetViewTarget() end)
    if ok_vt and view_target ~= nil and view_target:get_address() ~= pawn:get_address() then
        local ok_c, class_name = pcall(function() return view_target:get_class():get_fname():to_string() end)
        if ok_c and VEHICLE_VIEW_TARGETS[class_name] then
            return "vehicle", "driving " .. class_name
        end
        return camera_mode, "view target " .. view_target:get_full_name()
    end

    -- (menu_pointer.lua turns the cursor on in menus that hide it, so don't
    -- count that one, or the menu could never close)
    local ok, cursor = pcall(function() return controller.bShowMouseCursor end)
    if ok and cursor == true and not bettermart_cursor_forced then
        return "menu", "mouse cursor shown"
    end

    local ok_p, paused = pcall(function() return gameplay_statics:IsGamePaused(engine.GameViewport.World) end)
    if ok_p and paused == true then
        return "menu", "game paused"
    end

    if menu_widget_open then
        return "menu", "menu widget open"
    end

    return "play", "normal play"
end

local function set_mode(mode, reason)
    if current_mode == mode then
        return
    end
    current_mode = mode

    local playing = mode == "play"
    local driving = mode == "vehicle"
    vr.set_mod_value("VR_2DScreenMode", mode == "2d" and "true" or "false")
    vr.set_mod_value("UI_FollowView", (playing or driving) and "true" or "false")
    if playing then
        vr.set_aim_method(PLAY_AIM)
        head_aim_left = 0.0
    elseif driving then
        vr.set_aim_method(GAME_AIM)
        head_aim_left = 0.0
    else
        vr.set_aim_method(HEAD_AIM)
        head_aim_left = MENU_HEAD_AIM_TIME
    end
    log("mode " .. mode .. " (" .. reason .. ")")
end

gameplay_statics = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
common_input_c = api:find_uobject("Class /Script/CommonInput.CommonInputSubsystem")

local function hold_gamepad()
    if common_input_c == nil then
        return
    end
    if common_input == nil or not UEVR_UObjectHook.exists(common_input) then
        common_input = nil
        for _, s in ipairs(UEVR_UObjectHook.get_objects_by_class(common_input_c, false)) do
            common_input = s
            break
        end
        if common_input == nil then
            return
        end
    end
    if common_input:GetCurrentInputType() == INPUT_MOUSE_AND_KEYBOARD then
        common_input:SetCurrentInputType(INPUT_GAMEPAD)
        gamepad_holds = gamepad_holds + 1
        if gamepad_holds <= 5 then
            log("the game switched to mouse and keyboard; set it back to gamepad (time " .. gamepad_holds .. ")")
        end
    end
end
user_widget_c = api:find_uobject("Class /Script/UMG.UserWidget")

-- Shared with controller_pointer.lua so both agree on whether a menu is open
-- (bettermart_cursor_forced was set by the removed menu_pointer.lua; kept
-- false so it can be restored from the backup)
bettermart_mode = "play"
bettermart_cursor_forced = false

log("script loaded")

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    since_widget_check = since_widget_check + delta
    if since_widget_check >= MENU_WIDGET_CHECK_INTERVAL then
        since_widget_check = 0.0
        local ok, open = pcall(find_open_menu_widget)
        menu_widget_open = ok and open
    end

    local ok, mode, reason = pcall(wanted_mode, engine)
    if ok then
        set_mode(mode, reason)
        bettermart_mode = mode
    end

    if HOLD_GAMEPAD then
        local ok_g, err_g = pcall(hold_gamepad)
        if not ok_g and not hold_gamepad_error then
            hold_gamepad_error = true
            log("couldn't hold gamepad mode: " .. tostring(err_g))
        end
    end

    if head_aim_left > 0.0 then
        head_aim_left = head_aim_left - delta
        if head_aim_left <= 0.0 then
            vr.set_aim_method(GAME_AIM)
        end
    end
end)
