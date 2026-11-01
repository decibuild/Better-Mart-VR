-- shop_nav.lua: on the computer's Buy screen, pressing right on a category
-- goes to the products even when no product sits level with that category.
--
-- The game's controller navigation only moves right to a widget level with
-- the focused one (Slate's default spatial search). When the product list is
-- shorter than the category list, lower categories have nothing beside them.
-- While a category has focus and nothing is level with it, this gives that
-- category an explicit "right goes to the nearest product" rule
-- (UWidget:SetNavigationRuleExplicit). Categories that already have a product
-- beside them are left to the game. The rule is removed when focus leaves.
--
-- Widgets (from the game files): WB_MainShop holds a ScrollBox of W_Category
-- widgets and a ListView whose rows hold W_ItemNew products (button
-- PressetCattegoryButton).

local api = uevr.api
local functions = uevr.params.functions

local SHOP_PATH = "/Game/Widget/PC_Interface/Widgets/Shop/MainShop/WB_MainShop.WB_MainShop_C"
local CATEGORY_PATH = "/Game/Widget/PC_Interface/Widgets/Shop/Category/W_Category.W_Category_C"
local ITEM_PATH = "/Game/Widget/PC_Interface/Widgets/Shop/Item/W_ItemNew.W_ItemNew_C"

local CHECK_INTERVAL = 0.05 -- seconds between focus checks
local FIND_INTERVAL = 1.0   -- seconds between looking for the shop widget

local NAV_RIGHT = 1   -- EUINavigation::Right
local RULE_ESCAPE = 0 -- EUINavigationRule::Escape (the default)

local shop_c, category_c, item_c = nil, nil, nil
local user_widget_c, list_view_c = nil, nil
local sbl = nil
local zero_2d = nil
local shop = nil

local since_check = 0.0
local since_find = FIND_INTERVAL
local logged_errors = {}

-- The category we put a rule on: { widget, addr, target_addr }
local ruled = nil

local function log(msg)
    functions.log_info("[shop_nav] " .. msg)
end

local function log_error(key, err)
    local n = (logged_errors[key] or 0) + 1
    logged_errors[key] = n
    if n <= 5 then
        log(key .. " failed (time " .. n .. "): " .. tostring(err))
    end
end

local function find_class(path)
    for _, prefix in ipairs({ "WidgetBlueprintGeneratedClass ", "BlueprintGeneratedClass " }) do
        local c = api:find_uobject(prefix .. path)
        if c ~= nil then
            return c
        end
    end
    return nil
end

local function exists(o)
    return o ~= nil and UEVR_UObjectHook.exists(o)
end

-- Top, left, width, height in desktop pixels, from the last frame's layout
local function rect(widget)
    local geom = widget:GetCachedGeometry()
    local pos = sbl:LocalToAbsolute(geom, zero_2d)
    local size = sbl:GetAbsoluteSize(geom)
    return pos.X, pos.Y, size.X, size.Y
end

local function has_focus(w)
    local ok, f = pcall(function() return w:HasKeyboardFocus() end)
    if ok and f then return true end
    ok, f = pcall(function() return w:HasFocusedDescendants() end)
    return ok and f == true
end

local function find_shop()
    if shop_c == nil then shop_c = find_class(SHOP_PATH) end
    if category_c == nil then category_c = find_class(CATEGORY_PATH) end
    if item_c == nil then item_c = find_class(ITEM_PATH) end
    if shop_c == nil or category_c == nil or item_c == nil then
        return nil
    end
    for _, s in ipairs(UEVR_UObjectHook.get_objects_by_class(shop_c, false)) do
        if not s:get_full_name():find("Default__") then
            local ok, vis = pcall(function() return s:IsVisible() end)
            if ok and vis then
                return s
            end
        end
    end
    return nil
end

-- The category that has focus, with its rect. (The shop's widgets aren't
-- variables with known names, so no container check; a focused W_Category
-- while the shop is showing is the shop's.)
local function focused_category()
    for _, c in ipairs(UEVR_UObjectHook.get_objects_by_class(category_c, false)) do
        if not c:get_full_name():find("Default__") and has_focus(c) then
            local x, y, w, h = rect(c)
            if w > 0 and h > 0 then
                return c, x, y, w, h
            end
        end
    end
    return nil
end

-- Is obj part of the shop widget? (Designer widgets have the shop's
-- WidgetTree as their outer.)
local function in_shop(obj)
    local o = obj:get_outer()
    local shop_addr = shop:get_address()
    for _ = 1, 8 do
        if o == nil then return false end
        if o:get_address() == shop_addr then return true end
        o = o:get_outer()
    end
    return false
end

-- W_ItemNew widgets inside a widget (panels, and user widgets' trees)
local function collect_items(w, out, depth)
    if w == nil or depth > 12 then return end
    if w:is_a(item_c) then
        table.insert(out, w)
        return
    end
    if w:is_a(user_widget_c) then
        local ok, root = pcall(function() return w.WidgetTree.RootWidget end)
        if ok and root ~= nil then collect_items(root, out, depth + 1) end
        return
    end
    local ok, kids = pcall(function() return w:GetAllChildren() end)
    if ok and type(kids) == "table" then
        for _, k in ipairs(kids) do collect_items(k, out, depth + 1) end
    end
end

-- Products showing in the shop's product list(s): { widget, x, y, w, h }.
-- Taken from each list view's displayed rows, so recycled rows that are no
-- longer shown (with stale positions) aren't counted.
local function visible_products(cx)
    local list = {}
    local views = {}
    local all = UEVR_UObjectHook.get_objects_by_class(list_view_c, false)
    for _, lv in ipairs(all) do
        if not lv:get_full_name():find("Default__") and in_shop(lv) then
            table.insert(views, lv)
        end
    end
    if #views == 0 then
        -- Fallback: none traced to the shop widget; use any visible list view
        for _, lv in ipairs(all) do
            local ok, vis = pcall(function() return lv:IsVisible() end)
            if ok and vis and not lv:get_full_name():find("Default__") then
                table.insert(views, lv)
            end
        end
    end
    for _, lv in ipairs(views) do
        do
            local ok_e, entries = pcall(function() return lv:GetDisplayedEntryWidgets() end)
            local items = {}
            if ok_e and type(entries) == "table" then
                for _, e in ipairs(entries) do collect_items(e, items, 0) end
            end
            for _, it in ipairs(items) do
                local ok_v, vis = pcall(function() return it:IsVisible() end)
                if ok_v and vis then
                    local ok, x, y, w, h = pcall(rect, it)
                    if ok and w > 0 and h > 0 and x > cx then
                        table.insert(list, { widget = it, x = x, y = y, w = w, h = h })
                    end
                end
            end
        end
    end
    return list
end

local function clear_rule()
    if ruled == nil then return end
    if exists(ruled.widget) then
        local ok, err = pcall(function() ruled.widget:SetNavigationRuleBase(NAV_RIGHT, RULE_ESCAPE) end)
        if not ok then log_error("SetNavigationRuleBase", err) end
    end
    ruled = nil
end

-- Does this category already have its own right rule from the game?
local function game_has_right_rule(cat)
    local ok, rule = pcall(function()
        local nav = cat.Navigation
        if nav == nil then return RULE_ESCAPE end
        return nav.Right.Rule
    end)
    if not ok then return false end
    return rule ~= nil and rule ~= RULE_ESCAPE
end


local function check()
    if not exists(shop) then
        shop = nil
        clear_rule()
        return
    end

    local cat, cx, cy, cw, ch = focused_category()

    -- Focus left the category we gave a rule to
    if ruled ~= nil and (cat == nil or cat:get_address() ~= ruled.addr) then
        clear_rule()
    end

    if cat == nil then return end

    local addr = cat:get_address()
    if ruled == nil and game_has_right_rule(cat) then
        return -- leave the game's own rule alone
    end

    -- Is a product level with the category? Then the game's own search works.
    local products = visible_products(cx + cw / 2)
    local best, best_d = nil, nil
    local level = false
    local mid = cy + ch / 2
    for _, p in ipairs(products) do
        if p.x > cx and p.y < cy + ch and p.y + p.h > cy then
            level = true
        end
        local d = math.abs((p.y + p.h / 2) - mid)
        if best == nil or d < best_d - 1 or (math.abs(d - best_d) <= 1 and p.x < best.x) then
            best, best_d = p, d
        end
    end

    if level or best == nil then
        if ruled ~= nil then
            clear_rule()
        end
        return
    end

    local target = best.widget
    local ok_b, button = pcall(function() return best.widget.PressetCattegoryButton end)
    if ok_b and button ~= nil then target = button end

    if ruled ~= nil and ruled.target_addr == target:get_address() then
        return -- already pointing there
    end

    local ok, err = pcall(function() cat:SetNavigationRuleExplicit(NAV_RIGHT, target) end)
    if not ok then
        log_error("SetNavigationRuleExplicit", err)
        return
    end
    ruled = { widget = cat, addr = addr, target_addr = target:get_address() }
end

local function init()
    local c = api:find_uobject("Class /Script/UMG.SlateBlueprintLibrary")
    sbl = c and c:get_class_default_object()
    zero_2d = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Vector2D"))
    user_widget_c = api:find_uobject("Class /Script/UMG.UserWidget")
    list_view_c = api:find_uobject("Class /Script/UMG.ListView")
end

local ok_init, err_init = pcall(init)
if not ok_init then log("setup failed: " .. tostring(err_init)) end
log("script loaded")

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if sbl == nil then return end

    since_find = since_find + delta
    if shop == nil and since_find >= FIND_INTERVAL then
        since_find = 0.0
        local ok, s = pcall(find_shop)
        if not ok then
            log_error("finding the shop", s)
        elseif s ~= nil then
            shop = s
        end
    end

    if shop == nil then return end

    since_check = since_check + delta
    if since_check < CHECK_INTERVAL then return end
    since_check = 0.0

    local ok, err = pcall(function()
        local vis = shop:IsVisible()
        if not vis then
            clear_rule()
            shop = nil
            return
        end
        check()
    end)
    if not ok then
        log_error("checking the shop", err)
        shop = nil
    end
end)

uevr.sdk.callbacks.on_script_reset(function()
    pcall(clear_rule)
end)
