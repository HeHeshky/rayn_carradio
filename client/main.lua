-- =====================================================================
--  rayn_carradio – client
--
--  Why it doesn't lag even at 3000 km/h:
--  * Vehicle positions are NEVER sent over the network. The game already
--    syncs vehicles, so every client computes distance and volume itself.
--  * Occupants always get full volume – their distance is 0.
--  * Only volume changes > 1% are sent to the NUI, max 5x per second.
--  * Music is played from the server clock (startedAt), so anyone who
--    drives up hears the same moment of the track – no audio streaming.
-- =====================================================================

local active = {}          -- [netId] = { veh, state, audible, vol, silentSince }
local uiOpen, uiVeh, uiNet = false, 0, nil
local uiSt, uiQ = nil, {}
local personalVolume = 1.0

-- ---------------------------------------------------------------------
-- Requests to the server (with a response)
-- ---------------------------------------------------------------------
local pending, rid = {}, 0

local function request(name, args)
    rid = rid + 1
    local id = rid
    local p = promise.new()
    pending[id] = p
    TriggerServerEvent('rayn_carradio:req', id, name, args or {})
    SetTimeout(15000, function()
        if pending[id] then
            pending[id] = nil
            p:resolve({ ok = false, err = L('server_no_response') })
        end
    end)
    return Citizen.Await(p)
end

RegisterNetEvent('rayn_carradio:res', function(id, res)
    local p = pending[id]
    if p then
        pending[id] = nil
        p:resolve(res)
    end
end)

-- ---------------------------------------------------------------------
-- Server clock (so everybody hears the same moment of the track)
-- ---------------------------------------------------------------------
local timeBase, timeGT = nil, 0

local function serverNow()
    if not timeBase then return GetCloudTimeAsInt() + 0.0 end
    return timeBase + (GetGameTimer() - timeGT) / 1000.0
end

local function elapsedOf(st)
    if not st then return 0 end
    if st.pausedAt then return st.pausedAt end
    return serverNow() - (st.startedAt or serverNow())
end

CreateThread(function()
    Wait(2000)
    while true do
        local t0 = GetGameTimer()
        local r = request('time', {})
        if r and r.ok then
            local t1 = GetGameTimer()
            timeBase = r.data + (t1 - t0) / 2000.0 -- half of the round trip
            timeGT = t1
            -- re-sync playing vehicles with the corrected clock
            for net, a in pairs(active) do
                if a.audible then
                    SendNUIMessage({ type = 'sync', id = tostring(net), state = a.state, elapsed = elapsedOf(a.state), vol = math.max(a.vol, 0) })
                end
            end
        end
        Wait(timeBase and 300000 or 5000)
    end
end)

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function canControl(veh)
    local ped = PlayerPedId()
    for _, seat in ipairs(Config.ControlSeats) do
        if GetPedInVehicleSeat(veh, seat) == ped then return true end
    end
    return false
end

local function isPlaying(st)
    return type(st) == 'table' and not st.stopped and st.track ~= nil
end

local function sendSync(net)
    local a = active[net]
    if not a then return end
    SendNUIMessage({
        type = 'sync',
        id = tostring(net),
        state = a.state,
        elapsed = elapsedOf(a.state),
        vol = math.max(a.vol, 0),
    })
end

local function stopStream(net)
    if active[net] then
        active[net] = nil
        SendNUIMessage({ type = 'remove', id = tostring(net) })
    end
end

local function ensureStream(veh, st)
    if not NetworkGetEntityIsNetworked(veh) then return end
    local net = NetworkGetNetworkIdFromEntity(veh)
    local a = active[net]
    if a then
        a.veh = veh
        return
    end
    active[net] = { veh = veh, state = st, audible = false, vol = -1 }
end

local function pushUi()
    if not uiOpen then return end
    SendNUIMessage({
        type = 'ui',
        id = tostring(uiNet),
        state = uiSt or false,
        queue = uiQ or {},
        elapsed = elapsedOf(uiSt),
    })
end

-- ---------------------------------------------------------------------
-- Opening / closing the UI
-- ---------------------------------------------------------------------
local function closeUi()
    if not uiOpen then return end
    uiOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'close' })
end

local function openUi()
    if uiOpen then return end
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return Bridge_Notify('~r~' .. L('in_vehicle_required')) end
    if Config.BlockedVehicleClasses[GetVehicleClass(veh)] then return Bridge_Notify(L('vehicle_no_radio')) end
    if not canControl(veh) then return Bridge_Notify('~r~' .. L('seat_no_control')) end
    if not NetworkGetEntityIsNetworked(veh) then return Bridge_Notify(L('vehicle_not_networked')) end

    uiVeh = veh
    uiNet = NetworkGetNetworkIdFromEntity(veh)
    uiSt = Entity(veh).state.carradio
    uiQ = Entity(veh).state.carradio_q or {}
    uiOpen = true

    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'open', locale = GetUiLocale() })
    pushUi()
end

RegisterCommand(Config.OpenCommand, function()
    if uiOpen then closeUi() else openUi() end
end, false)
RegisterKeyMapping(Config.OpenCommand, L('keymap'), 'keyboard', Config.OpenKey or '')

if Config.PersonalVolumeCommand then
    RegisterCommand(Config.PersonalVolumeCommand, function(_, args)
        local v = tonumber(args[1])
        if not v then
            return Bridge_Notify(L('personal_vol_info', math.floor(personalVolume * 100), Config.PersonalVolumeCommand))
        end
        personalVolume = math.min(100, math.max(0, v)) / 100
        for _, a in pairs(active) do a.vol = -1 end -- force recalculation
        Bridge_Notify(L('personal_vol_set', math.floor(personalVolume * 100)))
    end, false)
end

-- ---------------------------------------------------------------------
-- Radio state changes (state bags)
-- ---------------------------------------------------------------------
local function netFromBag(bag)
    return tonumber(bag:match('^entity:(%d+)$'))
end

AddStateBagChangeHandler('carradio', nil, function(bag, _, value)
    local net = netFromBag(bag)
    if not net then return end

    local a = active[net]
    if a then
        if not isPlaying(value) then
            stopStream(net)
        else
            a.state = value
            if a.audible then sendSync(net) end
        end
    elseif isPlaying(value) then
        -- attach our own vehicle immediately (others: scanned every second)
        local veh = GetEntityFromStateBagName(bag)
        if veh ~= 0 and veh == GetVehiclePedIsIn(PlayerPedId(), false) then
            active[net] = { veh = veh, state = value, audible = false, vol = -1 }
        end
    end

    if uiOpen and net == uiNet then
        uiSt = value
        pushUi()
    end
end)

AddStateBagChangeHandler('carradio_q', nil, function(bag, _, value)
    local net = netFromBag(bag)
    if uiOpen and net == uiNet then
        uiQ = value or {}
        pushUi()
    end
end)

-- ---------------------------------------------------------------------
-- Area scan: find vehicles with the radio on (every Config.ScanMs)
-- ---------------------------------------------------------------------
CreateThread(function()
    local range = Config.MaxDistance + 30.0
    while true do
        local pc = GetEntityCoords(PlayerPedId())
        local seen = {}

        for _, veh in ipairs(GetGamePool('CVehicle')) do
            local st = Entity(veh).state.carradio
            if isPlaying(st) and #(pc - GetEntityCoords(veh)) <= range and NetworkGetEntityIsNetworked(veh) then
                local net = NetworkGetNetworkIdFromEntity(veh)
                seen[net] = true
                if not active[net] then
                    active[net] = { veh = veh, state = st, audible = false, vol = -1 }
                else
                    active[net].veh = veh
                end
            end
        end

        local myVeh = GetVehiclePedIsIn(PlayerPedId(), false)
        for net, a in pairs(active) do
            if not seen[net] and a.veh ~= myVeh then stopStream(net) end
        end

        Wait(Config.ScanMs)
    end
end)

-- ---------------------------------------------------------------------
-- Volume: computed locally from vehicle positions (every Config.TickMs)
-- ---------------------------------------------------------------------
CreateThread(function()
    local maxD = Config.MaxDistance
    while true do
        local ped = PlayerPedId()
        local pc = GetEntityCoords(ped)
        local myVeh = GetVehiclePedIsIn(ped, false)

        -- the vehicle we sit in always has priority
        if myVeh ~= 0 then
            local st = Entity(myVeh).state.carradio
            if isPlaying(st) then ensureStream(myVeh, st) end
        end

        -- close the UI when leaving the vehicle / changing seats
        if uiOpen and (myVeh ~= uiVeh or not canControl(uiVeh)) then closeUi() end

        -- candidates sorted by distance (limited by Config.MaxStreams)
        local list = {}
        for net, a in pairs(active) do
            if not DoesEntityExist(a.veh) then
                stopStream(net)
            else
                local d = (a.veh == myVeh) and 0.0 or #(pc - GetEntityCoords(a.veh))
                list[#list + 1] = { net = net, a = a, d = d }
            end
        end
        table.sort(list, function(x, y) return x.d < y.d end)

        local vols, changed = {}, false
        local t = GetGameTimer()

        for i, e in ipairs(list) do
            local a, v = e.a, 0.0
            local base = (a.state.volume or Config.DefaultVolume) * personalVolume

            if i <= Config.MaxStreams then
                if a.veh == myVeh then
                    v = base
                elseif e.d < maxD then
                    local f = 1.0 - e.d / maxD
                    v = base * Config.OutsideVolume * f * f
                end
            end

            if v > 0.001 then
                a.silentSince = nil
                if not a.audible then
                    a.audible = true
                    a.vol = v
                    sendSync(e.net)
                end
            elseif a.audible then
                -- destroy the player only after 3 s of silence (saves CPU)
                a.silentSince = a.silentSince or t
                if t - a.silentSince > 3000 then
                    a.audible = false
                    a.vol = -1
                    SendNUIMessage({ type = 'remove', id = tostring(e.net) })
                end
            end

            if a.audible and math.abs(v - a.vol) > 0.01 then
                a.vol = v
                vols[tostring(e.net)] = v
                changed = true
            end
        end

        if changed then SendNUIMessage({ type = 'volume', vols = vols }) end
        Wait(Config.TickMs)
    end
end)

-- ---------------------------------------------------------------------
-- NUI callbacks
-- ---------------------------------------------------------------------
RegisterNUICallback('close', function(_, cb)
    closeUi()
    cb(true)
end)

RegisterNUICallback('req', function(data, cb)
    CreateThread(function()
        cb(request(data.name, data.args or {}))
    end)
end)

RegisterNUICallback('ended', function(data, cb)
    cb(true)
    local net = tonumber(data.id)
    local a = net and active[net]
    if a and GetVehiclePedIsIn(PlayerPedId(), false) == a.veh then
        TriggerServerEvent('rayn_carradio:ended', net, data.tid, data.error == true)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and uiOpen then
        SetNuiFocus(false, false)
    end
end)
