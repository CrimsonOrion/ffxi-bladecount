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
addon.version = '1.4';
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

local function stage_for(n)
    return (n < STAGES[1].goal) and STAGES[1] or STAGES[2];
end
local MSG_DEFEATS  = 6;     -- "<actor> defeats <target>."
local STORAGE_BAGS = { 5, 6, 7 }; -- Satchel, Sack, Case
local STEP_DELAY   = 1.5;

local defaults = T{
    visible   = true,
    read      = -1,    -- last count read from the item (-1 = never read)
    live      = 0,     -- kills seen since that read
    read_time = 0,
};

local cfg  = settings.load(defaults);
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

local function run_steps(steps, n)
    n = n or 1;
    if (n > #steps) then busy = false; return; end
    local ok, stop = pcall(steps[n]);
    if (not ok) then
        err('Refresh failed: ' .. tostring(stop));
        watch_slot = nil;
        busy = false;
        return;
    end
    if (stop) then busy = false; return; end
    ashita.tasks.once(STEP_DELAY, function () run_steps(steps, n + 1); end);
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
            if (c ~= 0) then error('could not move the sword to the inventory'); end
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
            watch_slot = nil;
            if (n == nil) then error('the server did not send the count'); end
            set_read(n);
            report();
            for j = 1, inv():GetContainerCountMax(storage) do
                local item = inv():GetContainerItem(storage, j);
                if (item ~= nil and item.Id == CHAOSBRINGER) then
                    send_move(storage, j, 0);
                    return;
                end
            end
            error('could not find the sword in the storage bag');
        end,
        function ()
            c, i = find_sword();
            if (c ~= 0) then error('the sword did not come back to the inventory'); end
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
    elseif (sub == 'reset') then
        cfg.live = 0;
        settings.save();
        msg('Live counter reset.');
    elseif (sub == 'show' or sub == 'hide' or sub == '') then
        cfg.visible = (sub == 'show') or (sub == '' and not cfg.visible);
        settings.save();
    elseif (sub == 'status' or sub == 's') then
        report();
    else
        msg('/bladecount [show|hide] | refresh | status | reset   (alias /bod)');
    end
end);

-- Live counter -----------------------------------------------------------------------------------

-- Only a regular melee swing from the sword counts (not weapon skills, spells, or other
-- people's hits), so remember the category of our last action on each target.
local last_action = {};   -- target server id -> action category (1 = melee)

ashita.events.register('packet_in', 'bladecount_packet_in', function (e)
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

ashita.events.register('d3d_present', 'bladecount_present', function ()
    if (not cfg.visible) then return; end
    if (os.clock() >= next_scan) then
        has_sword = find_sword() ~= nil;
        next_scan = os.clock() + 2;
    end
    if (not has_sword) then return; end

    imgui.SetNextWindowSize({ 220, 0 }, ImGuiCond_Always);
    local open = { true };
    if (imgui.Begin('Chaosbringer###bladecount', open, bit.bor(ImGuiWindowFlags_NoResize, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse))) then
        if (cfg.read < 0) then
            imgui.Text(('Stored: unknown'));
            imgui.Text(('Live kills: %d'):fmt(cfg.live));
        else
            local est = cfg.read + cfg.live;
            local st  = stage_for(est);
            if (st ~= STAGES[1]) then
                imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, ('%s: done (%d)'):fmt(STAGES[1].name, STAGES[1].goal));
            end
            imgui.Text(st.name);
            imgui.Text(('Stored: %d   Live: +%d'):fmt(cfg.read, cfg.live));
            local frac = math.max(0, math.min(1, (est - st.from) / (st.goal - st.from)));
            imgui.ProgressBar(frac, { -1, 0 }, ('%d / %d'):fmt(est, st.goal));
            if (est >= st.goal) then
                imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'Done!');
                imgui.PushTextWrapPos(0);
                imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, st.done);
                imgui.PopTextWrapPos();
            elseif (st ~= STAGES[1]) then
                imgui.PushTextWrapPos(0);
                imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'Zone into Beadeaux first if you have not finished Blade of Darkness yet.');
                imgui.PopTextWrapPos();
            end
        end
        if (not main_is_chaosbringer()) then
            imgui.TextColored({ 1.0, 0.6, 0.3, 1.0 }, 'Chaosbringer not equipped');
        end
        imgui.BeginDisabled(busy);
        if (imgui.Button(busy and 'Refreshing...' or 'Refresh stored count')) then refresh(); end
        imgui.EndDisabled();
    end
    imgui.End();
    if (not open[1]) then
        cfg.visible = false;
        settings.save();
    end
end);
