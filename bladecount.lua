--[[
* bladecount - Tracks Chaosbringer kills for the Dark Knight quests Blade of Darkness
* (100 kills) and Blade of Death (the count carries on to 200).
*
* The game stores the kill count on the Chaosbringer itself, in the first 4 bytes of the
* item's extra data (the same value Windower's LatentChecker reads as "ws_points").
* The client copy never updates, so /bladecount refresh moves the sword to a storage bag
* and back; the server's update for the inventory slot it left carries the current count
* (what LatentChecker reads).
*
* A live counter adds kills seen since the last read ("You defeat ..." while the sword
* is in your main hand), so progress shows between refreshes.
--]]

addon.name    = 'bladecount';
addon.author  = 'CrimsonOrion';
addon.version = '1.10';
addon.desc    = 'Tracks Chaosbringer kills for Blade of Darkness and Blade of Death.';
addon.link    = 'https://github.com/CrimsonOrion/ffxi-bladecount';

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');

local CHAOSBRINGER = 16607;
-- The sword's count keeps going after Blade of Darkness, so Blade of Death ends at 200.
local STAGES = {
    { name = 'Blade of Darkness', from = 0,   goal = 100, done = 'Zone into Beadeaux for the cutscene.' },
    { name = 'Blade of Death',    from = 100, goal = 200, done = 'Trade Chaosbringer to the ??? in Gusgen Mines (J-7, map 1).' },
};

-- Quest log bits (Bastok log), as read by the journal addon from packet 0x056.
local QUEST_DARKNESS = 28;
local QUEST_DEATH    = 47;
local LOG_BASTOK_CURRENT, LOG_BASTOK_COMPLETED = 0x0058, 0x0098;
local MSG_DEFEATS  = 6;     -- "<actor> defeats <target>."
local STORAGE_BAGS = { 5, 6, 7 }; -- Satchel, Sack, Case
local STEP_DELAY   = 1.5;

local defaults = T{
    visible   = true,
    opacity   = 95,      -- window background opacity, percent
    read      = -1,    -- last count read from the item (-1 = never read)
    live      = 0,     -- kills seen since that read
    read_time = 0,
    darkness  = 'unknown',   -- quest status from the game's quest log:
    death     = 'unknown',   -- 'unknown', 'not_started', 'active' or 'completed'
};

local cfg  = settings.load(defaults);

-- Which quest the count is for. Uses the quest log when known, else the count itself.
local function stage_for(n)
    if (cfg.darkness == 'completed') then return STAGES[2]; end
    if (cfg.darkness ~= 'unknown') then return STAGES[1]; end
    return (n < STAGES[1].goal) and STAGES[1] or STAGES[2];
end

local STATUS_TEXT = { unknown = 'unknown', not_started = 'not started', active = 'active', completed = 'completed' };
local busy = false;
local has_sword, next_scan = false, 0;
local watch_slot, captured = nil, nil;  -- inventory slot the sword just left, and the count the server sent for it

settings.register('settings', 'bladecount_settings', function (s)
    if (s ~= nil) then cfg = s; end
    settings.save();
end);

local function msg(s)
    print(chat.header(addon.name):append(chat.message(s)));
end

local function err(s)
    print(chat.header(addon.name):append(chat.error(s)));
end

local function inv()
    return AshitaCore:GetMemoryManager():GetInventory();
end

-- Returns container, index of the equipped main-hand item (index 0 = nothing).
local function equipped_main()
    local e = inv():GetEquippedItem(0);
    if (e == nil) then return 0, 0; end
    return bit.rshift(bit.band(e.Index, 0xFF00), 8), bit.band(e.Index, 0x00FF);
end

local function main_is_chaosbringer()
    local c, i = equipped_main();
    if (i == 0) then return false; end
    local item = inv():GetContainerItem(c, i);
    return item ~= nil and item.Id == CHAOSBRINGER;
end

-- Finds the Chaosbringer: inventory first, then the wardrobes. Returns container, index.
local function find_sword()
    for _, c in ipairs({ 0, 8, 10, 11, 12, 13, 14, 15, 16 }) do
        local max = inv():GetContainerCountMax(c);
        for i = 1, max do
            local item = inv():GetContainerItem(c, i);
            if (item ~= nil and item.Id == CHAOSBRINGER) then
                return c, i;
            end
        end
    end
    return nil, nil;
end

local function set_read(n)
    cfg.read      = n;
    cfg.live      = 0;
    cfg.read_time = os.time();
    settings.save();
end

local function report()
    if (cfg.read < 0) then
        msg(('No stored count read yet; %d kills counted live. Use /bladecount refresh.'):fmt(cfg.live));
        return;
    end
    local est = cfg.read + cfg.live;
    local st = stage_for(est);
    msg(('%s: stored count %d / %d'):fmt(st.name, cfg.read, st.goal)
        .. (cfg.live > 0 and (' (+%d live = ~%d)'):fmt(cfg.live, est) or '')
        .. (est >= st.goal and (' - done! ' .. st.done) or ''));
    msg(('Quest log: Blade of Darkness %s, Blade of Death %s'):fmt(STATUS_TEXT[cfg.darkness] or '?', STATUS_TEXT[cfg.death] or '?'));
end

-- Packets ----------------------------------------------------------------------------------------

local function send_equip(index, slot, container)
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x50, { 0x00, 0x00, 0x00, 0x00, index, slot, container, 0x00 });
end

local function send_move(from_bag, from_index, to_bag, count)
    local p = struct.pack('BBBBIBBBB', 0x29, 0x06, 0x00, 0x00, count or 1, from_bag, to_bag, from_index, 0x52):totable();
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x29, p);
end

local function bag_has_room(c)
    local max = inv():GetContainerCountMax(c);
    if (max == 0) then return false; end
    local used = 0;
    for i = 1, max do
        local item = inv():GetContainerItem(c, i);
        if (item ~= nil and item.Id ~= 0) then used = used + 1; end
    end
    return used < max;
end

-- Refresh: unequip, (wardrobe ->) inventory -> storage -> inventory, read, re-equip ------------------

local BAG_NAMES = { [0] = 'Inventory', [5] = 'Satchel', [6] = 'Sack', [7] = 'Case' };

-- Where the sword is now, as a bag name (for error messages).
local function where_is_sword()
    for _, c in ipairs({ 0, 5, 6, 7 }) do
        for i = 1, inv():GetContainerCountMax(c) do
            local item = inv():GetContainerItem(c, i);
            if (item ~= nil and item.Id == CHAOSBRINGER) then return BAG_NAMES[c]; end
        end
    end
    return find_sword() ~= nil and 'a wardrobe' or nil;
end

-- A step may return 'retry' while it waits for the game to catch up (the client's copy
-- of a bag can lag behind the move); it is retried every second up to MAX_RETRIES times.
local MAX_RETRIES = 8;

local function run_steps(steps, n, tries)
    n, tries = n or 1, tries or 0;
    if (n > #steps) then busy = false; return; end
    local ok, result = pcall(steps[n]);
    if (ok and result == 'retry') then
        if (tries < MAX_RETRIES) then
            ashita.tasks.once(1, function () run_steps(steps, n, tries + 1); end);
            return;
        end
        ok, result = false, 'timed out waiting for the sword to move';
    end
    if (not ok) then
        err('Refresh failed: ' .. tostring(result));
        local where = where_is_sword();
        if (where ~= nil) then err('Your Chaosbringer is in your ' .. where .. '.'); end
        watch_slot = nil;
        busy = false;
        return;
    end
    if (result == 'stop') then busy = false; return; end
    ashita.tasks.once(STEP_DELAY, function () run_steps(steps, n + 1); end);
end

-- Step: move the sword from whichever storage bag holds it back to the inventory.
local function step_bring_back()
    for _, b in ipairs(STORAGE_BAGS) do
        for j = 1, inv():GetContainerCountMax(b) do
            local item = inv():GetContainerItem(b, j);
            if (item ~= nil and item.Id == CHAOSBRINGER) then
                send_move(b, j, 0);
                return;
            end
        end
    end
    return 'retry';
end

-- Fetch: bring the sword back from a storage bag (if it is in one) and equip it.
local function fetch()
    if (busy) then err('A refresh is already running.'); return; end
    local in_storage = false;
    for _, b in ipairs(STORAGE_BAGS) do
        for j = 1, inv():GetContainerCountMax(b) do
            local item = inv():GetContainerItem(b, j);
            if (item ~= nil and item.Id == CHAOSBRINGER) then in_storage = true; end
        end
    end
    if (not in_storage and find_sword() == nil) then
        err('No Chaosbringer in your inventory, wardrobes, Satchel, Sack or Case.');
        return;
    end
    if (in_storage and not bag_has_room(0)) then err('Need a free inventory slot.'); return; end

    busy = true;
    local steps = {};
    if (in_storage) then steps[#steps + 1] = step_bring_back; end
    steps[#steps + 1] = function ()
        local c, i = find_sword();
        if (c == nil) then return 'retry'; end
        send_equip(i, 0, c);
        msg('Chaosbringer equipped.');
    end;
    run_steps(steps);
end

local function refresh()
    if (busy) then err('A refresh is already running.'); return; end
    watch_slot, captured = nil, nil;
    local c, i = find_sword();
    if (c == nil) then err('No Chaosbringer in your inventory or wardrobes.'); return; end

    local storage;
    for _, b in ipairs(STORAGE_BAGS) do
        if (bag_has_room(b)) then storage = b; break; end
    end
    if (storage == nil) then err('Need a free slot in your Satchel, Sack or Case.'); return; end
    if (c ~= 0 and not bag_has_room(0)) then err('Need a free inventory slot.'); return; end

    local was_equipped = main_is_chaosbringer();
    busy = true;
    msg('Refreshing the stored count... (this resets your TP)');

    run_steps({
        function ()
            if (was_equipped) then send_equip(0, 0, 0); end
        end,
        function ()
            c, i = find_sword();
            if (c == nil) then error('lost track of the sword'); end
            if (c ~= 0) then send_move(c, i, 0); end
        end,
        function ()
            c, i = find_sword();
            if (c ~= 0) then return 'retry'; end
            watch_slot, captured = i, nil;
            send_move(0, i, storage);
        end,
        function ()
            -- The server's update for the slot the sword just left carries the current count
            -- (this is what LatentChecker reads). Fall back to the client's copy of that slot.
            local n = captured;
            if (n == nil and watch_slot ~= nil) then
                local slot = inv():GetContainerItem(0, watch_slot);
                if (slot ~= nil and slot.Id == 0 and slot.Extra ~= nil) then
                    n = struct.unpack('I', slot.Extra, 1);
                end
            end
            if (n == nil) then return 'retry'; end
            watch_slot = nil;
            set_read(n);
            report();
        end,
        step_bring_back,
        function ()
            c, i = find_sword();
            if (c ~= 0) then return 'retry'; end
            if (was_equipped) then send_equip(i, 0, 0); end
        end,
    });
end

-- Commands ---------------------------------------------------------------------------------------

ashita.events.register('command', 'bladecount_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not T{ '/bladecount', '/bod' }:contains(args[1]:lower())) then return; end
    e.blocked = true;

    local sub = (args[2] or ''):lower();
    if (sub == 'refresh' or sub == 'r') then
        refresh();
    elseif (sub == 'fetch' or sub == 'f') then
        fetch();
    elseif (sub == 'reset') then
        cfg.live = 0;
        settings.save();
        msg('Live counter reset.');
    elseif (sub == 'show' or sub == 'hide' or sub == '') then
        cfg.visible = (sub == 'show') or (sub == '' and not cfg.visible);
        settings.save();
    elseif (sub == 'opacity' and tonumber(args[3]) ~= nil) then
        cfg.opacity = math.max(0, math.min(100, math.floor(tonumber(args[3]))));
        settings.save();
        msg(('Background opacity: %d%%'):fmt(cfg.opacity));
    elseif (sub == 'status' or sub == 's') then
        report();
    else
        msg('/bladecount [show|hide] | refresh | fetch | status | reset | opacity <0-100>   (alias /bod)');
    end
end);

-- Live counter -----------------------------------------------------------------------------------

-- Only a regular melee swing from the sword counts (not weapon skills, spells, or other
-- people's hits), so remember the category of our last action on each target.
local last_action = {};   -- target server id -> action category (1 = melee)

ashita.events.register('packet_in', 'bladecount_packet_in', function (e)
    if (e.id == 0x56 and e.size >= 40) then
        local log = struct.unpack('I', e.data, 0x24 + 1);
        if (log ~= LOG_BASTOK_CURRENT and log ~= LOG_BASTOK_COMPLETED) then return; end
        local function bit_set(id)
            local byte = e.data:byte(0x04 + math.floor(id / 8) + 1) or 0;
            return bit.band(byte, bit.lshift(1, id % 8)) ~= 0;
        end
        local changed = false;
        for key, id in pairs({ darkness = QUEST_DARKNESS, death = QUEST_DEATH }) do
            local new = cfg[key];
            if (log == LOG_BASTOK_COMPLETED) then
                if (bit_set(id)) then new = 'completed';
                elseif (new == 'completed' or new == 'unknown') then new = 'not_started'; end
            elseif (new ~= 'completed') then
                new = bit_set(id) and 'active' or 'not_started';
            end
            if (new ~= cfg[key]) then cfg[key] = new; changed = true; end
        end
        if (changed) then settings.save(); end
        return;
    end

    local me = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);

    if (e.id == 0x28) then
        local raw = e.data_raw;
        if (ashita.bits.unpack_be(raw, 0, 40, 32) ~= me) then return; end
        local category = ashita.bits.unpack_be(raw, 0, 82, 4);
        local count    = ashita.bits.unpack_be(raw, 0, 72, 6);
        if (count < 1) then return; end
        local target = ashita.bits.unpack_be(raw, 0, 150, 32);
        last_action[target] = category;
        return;
    end

    if (e.id == 0x20 and watch_slot ~= nil) then
        local id   = struct.unpack('H', e.data, 0x0C + 1);
        local bag  = struct.unpack('B', e.data, 0x0E + 1);
        local slot = struct.unpack('B', e.data, 0x0F + 1);
        if (id == 0 and bag == 0 and slot == watch_slot) then
            captured = struct.unpack('I', e.data, 0x11 + 1);
        end
        return;
    end

    if (e.id ~= 0x29) then return; end
    local m = struct.unpack('H', e.data, 0x18 + 1);
    if (m ~= MSG_DEFEATS) then return; end
    if (struct.unpack('I', e.data, 0x04 + 1) ~= me) then return; end
    local target = struct.unpack('I', e.data, 0x08 + 1);
    local category = last_action[target];
    last_action[target] = nil;
    if (category ~= 1 or not main_is_chaosbringer()) then return; end
    cfg.live = cfg.live + 1;
    settings.save();
end);

ashita.events.register('packet_in', 'bladecount_zone', function (e)
    if (e.id == 0x0A) then last_action = {}; end
end);

-- Window -----------------------------------------------------------------------------------------
-- Theme matches the addon manager (and XIUI's config window): dark warm background, gold accent.

local gold       = { 0.957, 0.855, 0.592, 1.0 };
local goldDark   = { 0.765, 0.684, 0.474, 1.0 };
local goldDarker = { 0.573, 0.512, 0.355, 1.0 };
local bgDark     = { 0.051, 0.051, 0.051, 0.95 };
local bgMedium   = { 0.098, 0.090, 0.075, 1.0 };
local bgLight    = { 0.137, 0.125, 0.106, 1.0 };
local bgLighter  = { 0.176, 0.161, 0.137, 1.0 };
local textLight  = { 0.878, 0.855, 0.812, 1.0 };
local textMuted  = { 0.6, 0.58, 0.54, 1.0 };
local borderDark = { 0.3, 0.275, 0.235, 1.0 };
local green      = { 0.55, 0.80, 0.50, 1.0 };
local red        = { 0.90, 0.45, 0.40, 1.0 };

local THEME_COLORS = {
    { ImGuiCol_WindowBg, bgDark }, { ImGuiCol_TitleBg, bgMedium }, { ImGuiCol_TitleBgActive, bgLight },
    { ImGuiCol_TitleBgCollapsed, bgDark }, { ImGuiCol_FrameBg, bgMedium }, { ImGuiCol_FrameBgHovered, bgLight },
    { ImGuiCol_FrameBgActive, bgLighter }, { ImGuiCol_Border, borderDark }, { ImGuiCol_Text, textLight },
    { ImGuiCol_TextDisabled, goldDark }, { ImGuiCol_Button, bgMedium }, { ImGuiCol_ButtonHovered, bgLight },
    { ImGuiCol_ButtonActive, bgLighter }, { ImGuiCol_Separator, borderDark },
    { ImGuiCol_Header, bgLight }, { ImGuiCol_HeaderHovered, bgLighter },
    { ImGuiCol_HeaderActive, { gold[1], gold[2], gold[3], 0.3 } },
    { ImGuiCol_SliderGrab, goldDark }, { ImGuiCol_SliderGrabActive, gold },
    { ImGuiCol_PlotHistogram, { gold[1], gold[2], gold[3], 0.55 } },
    { ImGuiCol_ResizeGrip, goldDarker }, { ImGuiCol_ResizeGripHovered, goldDark }, { ImGuiCol_ResizeGripActive, gold },
};
local THEME_VARS = {
    { ImGuiStyleVar_WindowPadding, { 12, 12 } }, { ImGuiStyleVar_FramePadding, { 6, 4 } },
    { ImGuiStyleVar_ItemSpacing, { 8, 6 } }, { ImGuiStyleVar_FrameRounding, 4.0 }, { ImGuiStyleVar_WindowRounding, 6.0 },
};

local LABEL_WIDTH = 70;
local draw_error  = false;

local function labelValue(label, value, color)
    imgui.TextColored(textMuted, label);
    imgui.SameLine(LABEL_WIDTH);
    if (color ~= nil) then imgui.TextColored(color, value); else imgui.Text(value); end
end

local function wrapped(color, text)
    imgui.PushTextWrapPos(0);
    imgui.TextColored(color, text);
    imgui.PopTextWrapPos();
end

local function accentButton(label, enabled)
    imgui.PushStyleColor(ImGuiCol_Button, { gold[1], gold[2], gold[3], 0.22 });
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { gold[1], gold[2], gold[3], 0.35 });
    imgui.PushStyleColor(ImGuiCol_ButtonActive, { gold[1], gold[2], gold[3], 0.45 });
    imgui.BeginDisabled(not enabled);
    local pressed = imgui.Button(label, { -1, 0 });
    imgui.EndDisabled();
    imgui.PopStyleColor(3);
    return pressed;
end

local function draw_body()
    if (cfg.read < 0) then
        imgui.TextColored(gold, 'Chaosbringer');
        labelValue('Stored', 'unknown', textMuted);
        labelValue('Live', ('+%d'):fmt(cfg.live));
        wrapped(textMuted, 'Refresh to read the count from the sword.');
    else
        local est = cfg.read + cfg.live;
        local st  = stage_for(est);
        local done = est >= st.goal;

        if (st ~= STAGES[1]) then
            imgui.TextColored(textMuted, STAGES[1].name);
            imgui.SameLine();
            imgui.TextColored(green, 'Done');
        end
        imgui.TextColored(gold, st.name);
        imgui.SameLine();
        if (done) then imgui.TextColored(green, 'Done'); else imgui.TextColored(textMuted, 'In progress'); end

        imgui.Spacing();
        labelValue('Stored', tostring(cfg.read));
        labelValue('Live', ('+%d'):fmt(cfg.live), cfg.live > 0 and gold or nil);
        local frac = math.max(0, math.min(1, (est - st.from) / (st.goal - st.from)));
        if (done) then imgui.PushStyleColor(ImGuiCol_PlotHistogram, { green[1], green[2], green[3], 0.6 }); end
        imgui.ProgressBar(frac, { -1, 0 }, ('%d / %d'):fmt(est, st.goal));
        if (done) then imgui.PopStyleColor(); end

        if (done) then wrapped(green, st.done); end
        local hint;
        if (st == STAGES[2] and cfg.darkness == 'unknown') then
            hint = 'Zone into Beadeaux first if you have not finished Blade of Darkness yet.';
        elseif (st == STAGES[2] and cfg.death == 'not_started') then
            hint = 'Get Blade of Death from Gumbah in Bastok Mines (J-7); needs Bastok fame 3.';
        elseif (st == STAGES[1] and cfg.darkness == 'not_started') then
            hint = 'Blade of Darkness is not active in your quest log.';
        end
        if (hint ~= nil) then wrapped(textMuted, hint); end
    end

    if (not main_is_chaosbringer()) then
        wrapped(red, 'Chaosbringer is not in your main hand.');
    end
    imgui.Spacing();
    if (accentButton(busy and 'Refreshing...' or 'Refresh stored count', not busy)) then refresh(); end

    imgui.Spacing();
    if (imgui.CollapsingHeader('Settings')) then
        imgui.TextColored(textMuted, 'Background');
        imgui.SetNextItemWidth(-1);
        local v = { cfg.opacity };
        if (imgui.SliderInt('##bladecount_opacity', v, 0, 100, '%d%%', ImGuiSliderFlags_AlwaysClamp)) then
            cfg.opacity = v[1];
        end
        if (imgui.IsItemDeactivatedAfterEdit()) then settings.save(); end
    end
end

ashita.events.register('d3d_present', 'bladecount_present', function ()
    if (not cfg.visible) then return; end
    if (os.clock() >= next_scan) then
        has_sword = find_sword() ~= nil;
        next_scan = os.clock() + 2;
    end
    if (not has_sword) then return; end

    for _, c in ipairs(THEME_COLORS) do imgui.PushStyleColor(c[1], c[2]); end
    for _, v in ipairs(THEME_VARS) do imgui.PushStyleVar(v[1], v[2]); end
    local alpha = math.max(0, math.min(100, tonumber(cfg.opacity) or 95)) / 100;
    imgui.PushStyleColor(ImGuiCol_WindowBg, { bgDark[1], bgDark[2], bgDark[3], alpha });
    imgui.PushStyleColor(ImGuiCol_Border, { borderDark[1], borderDark[2], borderDark[3], alpha });

    imgui.SetNextWindowSize({ 240, 0 }, ImGuiCond_Always);
    local open = { true };
    if (imgui.Begin('Chaosbringer - v' .. addon.version .. '###bladecount', open,
            bit.bor(ImGuiWindowFlags_NoResize, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse))) then
        -- Keep the style stack balanced even if drawing fails.
        local ok, e = pcall(draw_body);
        if (not ok and not draw_error) then draw_error = true; err('Window error: ' .. tostring(e)); end
    end
    imgui.End();

    imgui.PopStyleVar(#THEME_VARS);
    imgui.PopStyleColor(#THEME_COLORS + 2);

    if (not open[1]) then
        cfg.visible = false;
        settings.save();
    end
end);
