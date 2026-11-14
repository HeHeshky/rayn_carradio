-- =====================================================================
--  rayn_carradio – server
--  Radio state lives in the vehicle's state bag:
--    carradio   = playback (current track, start time, pause, volume)
--    carradio_q = queue (only needed by the UI)
--  The server NEVER sends vehicle positions – every client computes
--  the volume locally.
-- =====================================================================

local baseTime, baseGT = os.time(), GetGameTimer()

-- Server clock with millisecond precision (shared by all clients)
local function now()
    return baseTime + (GetGameTimer() - baseGT) / 1000.0
end

-- ---------------------------------------------------------------------
-- Database
-- ---------------------------------------------------------------------
MySQL.ready(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `carradio_playlists` (
            `id` INT(11) NOT NULL AUTO_INCREMENT,
            `owner` VARCHAR(80) NOT NULL,
            `name` VARCHAR(40) NOT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            INDEX `owner` (`owner`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `carradio_tracks` (
            `id` INT(11) NOT NULL AUTO_INCREMENT,
            `playlist_id` INT(11) NOT NULL,
            `t` VARCHAR(8) NOT NULL,
            `yt_id` VARCHAR(16) NULL DEFAULT NULL,
            `url` VARCHAR(512) NOT NULL,
            `title` VARCHAR(200) NULL DEFAULT NULL,
            `artist` VARCHAR(120) NULL DEFAULT NULL,
            `position` INT(11) NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`),
            INDEX `playlist_id` (`playlist_id`)
        )
    ]])
end)

local function getOwner(src)
    return Bridge_GetOwner(src)
end

-- ---------------------------------------------------------------------
-- Links and titles
-- ---------------------------------------------------------------------
local titleCache = {}

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

local function urlencode(s)
    return (s:gsub('[^%w%-%._~]', function(c) return ('%%%02X'):format(c:byte()) end))
end

-- Turns a pasted link into a track: YouTube (by video id) or a direct audio URL
local function parseUrl(url)
    if type(url) ~= 'string' then return nil end
    url = trim(url)
    if #url < 10 or #url > 500 then return nil end
    if not url:match('^https?://') then return nil end

    local host = (url:match('^https?://([^/?#]+)') or ''):lower()
    if host:find('youtube%.com$') or host:find('youtu%.be$') or host:find('youtube%-nocookie%.com$') then
        local id = url:match('youtu%.be/([%w_%-]+)')
            or url:match('[?&]v=([%w_%-]+)')
            or url:match('/shorts/([%w_%-]+)')
            or url:match('/embed/([%w_%-]+)')
            or url:match('/live/([%w_%-]+)')
        if not id or #id < 11 then return nil end
        id = id:sub(1, 11)
        return { t = 'yt', id = id, url = 'https://www.youtube.com/watch?v=' .. id }
    end

    return { t = 'audio', url = url }
end

-- Parses the link and fetches the title (YouTube oEmbed, cached)
local function resolveTrack(url)
    local tr = parseUrl(url)
    if not tr then return nil, L('invalid_link') end

    local c = titleCache[tr.url]
    if c then
        tr.title, tr.artist = c.title, c.artist
        return tr
    end

    if tr.t == 'yt' then
        local p, done = promise.new(), false
        PerformHttpRequest('https://www.youtube.com/oembed?format=json&url=' .. urlencode(tr.url), function(code, body)
            if done then return end
            done = true
            local data = nil
            if code == 200 and body then
                local ok, d = pcall(json.decode, body)
                if ok then data = d end
            end
            p:resolve(data)
        end, 'GET', '', { ['Accept'] = 'application/json' })
        SetTimeout(5000, function()
            if not done then done = true p:resolve(nil) end
        end)
        local d = Citizen.Await(p)
        if type(d) == 'table' and d.title then
            tr.title = tostring(d.title):sub(1, 120)
            tr.artist = tostring(d.author_name or 'YouTube'):sub(1, 80)
        end
    end

    if not tr.title then
        local name = tr.url:match('([^/?#]+)[?#]?[^/]*$') or L('default_track')
        name = name:gsub('%%20', ' '):gsub('%.%w+$', '')
        tr.title = name:sub(1, 120)
        tr.artist = tr.t == 'yt' and 'YouTube' or L('audio_link')
    end

    titleCache[tr.url] = { title = tr.title, artist = tr.artist }
    return tr
end

-- ---------------------------------------------------------------------
-- Vehicle radio state
-- ---------------------------------------------------------------------
local function newState(old)
    return {
        tid = old and old.tid or 0,          -- increments on every track start
        index = 0,
        count = 0,
        startedAt = 0,
        stopped = true,
        loop = old and old.loop or 'all',    -- 'all' | 'one' | 'none'
        shuffle = false,
        volume = old and old.volume or Config.DefaultVolume,
        errors = 0,
    }
end

local function getVeh(veh)
    local bag = Entity(veh).state
    local st = bag.carradio
    local q = bag.carradio_q
    if type(st) ~= 'table' then st = newState() end
    if type(q) ~= 'table' then q = {} end
    return st, q
end

-- Saves the state; the queue is only re-sent when it changed
local function commit(veh, st, q, queueChanged)
    st.count = #q
    if st.index > #q then st.index = #q end
    st.track = q[st.index]
    if not st.track then st.stopped = true end
    if st.stopped then st.pausedAt = nil end
    if queueChanged then
        Entity(veh).state:set('carradio_q', q, true)
    end
    Entity(veh).state:set('carradio', st, true)
end

local function startTrack(st, idx)
    st.index = idx
    st.tid = (st.tid or 0) + 1
    st.startedAt = now()
    st.pausedAt = nil
    st.stopped = false
end

local function position(st)
    if st.pausedAt then return st.pausedAt end
    return now() - (st.startedAt or now())
end

-- Next track; auto = the track ended by itself (respects repeat mode)
local function advance(st, q, auto)
    if #q == 0 then st.stopped = true return end
    if auto and st.loop == 'one' then startTrack(st, math.max(st.index, 1)) return end
    local n = st.index + 1
    if n > #q then
        if st.loop == 'all' or not auto then
            n = 1
        else
            st.stopped = true
            return
        end
    end
    startTrack(st, n)
end

local function shuffleList(t, from)
    for i = #t, from + 1, -1 do
        local j = math.random(from, i)
        t[i], t[j] = t[j], t[i]
    end
end

-- Returns the vehicle if the player sits in a seat allowed to control the radio
local function controlVeh(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil, L('no_ped') end
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return nil, L('in_vehicle_required') end
    for _, seat in ipairs(Config.ControlSeats) do
        if GetPedInVehicleSeat(veh, seat) == ped then return veh end
    end
    return nil, L('seat_no_control')
end

local function toQueueTrack(row)
    return { t = row.t, id = row.yt_id, url = row.url, title = row.title or L('default_track'), artist = row.artist or '' }
end

local function ownPlaylist(owner, id)
    local r = MySQL.scalar.await('SELECT id FROM carradio_playlists WHERE id = ? AND owner = ?', { tonumber(id) or 0, owner })
    return r ~= nil
end

-- ---------------------------------------------------------------------
-- UI request handlers
--   return data            -> success
--   return nil, 'message'  -> error shown in the UI
-- ---------------------------------------------------------------------
local H = {}

function H.time()
    return now()
end

function H.play(src, a)
    local veh, err = controlVeh(src)
    if not veh then return nil, err end

    local tr, e = resolveTrack(a.url)
    if not tr then return nil, e end

    -- the vehicle may have been deleted while the title was being fetched
    if not DoesEntityExist(veh) then return nil, L('vehicle_gone') end

    local st, q = getVeh(veh)
    if #q >= Config.MaxQueue then return nil, L('queue_full', Config.MaxQueue) end

    if a.mode == 'queue' then
        q[#q + 1] = tr
        if st.stopped then startTrack(st, #q) end
    else
        local pos = (not st.stopped and st.index > 0) and st.index + 1 or #q + 1
        table.insert(q, pos, tr)
        startTrack(st, pos)
    end

    commit(veh, st, q, true)
    return { title = tr.title }
end

function H.control(src, a)
    local veh, err = controlVeh(src)
    if not veh then return nil, err end

    local st, q = getVeh(veh)
    local action, value = a.action, a.value
    local qChanged = false

    if action == 'toggle' then
        if st.stopped then
            if #q == 0 then return nil, L('queue_empty') end
            startTrack(st, math.min(math.max(st.index, 1), #q))
        elseif st.pausedAt then
            st.startedAt = now() - st.pausedAt
            st.pausedAt = nil
        else
            st.pausedAt = position(st)
        end
    elseif action == 'power' then
        if st.stopped then
            if #q == 0 then return nil, L('queue_empty') end
            startTrack(st, math.min(math.max(st.index, 1), #q))
        else
            st.stopped = true
        end
    elseif action == 'next' then
        advance(st, q, false)
    elseif action == 'prev' then
        if st.stopped then return true end
        if position(st) > 5 or st.index <= 1 then
            if st.pausedAt then st.pausedAt = 0 else st.startedAt = now() end
        else
            startTrack(st, st.index - 1)
        end
    elseif action == 'seek' then
        local v = tonumber(value)
        if not v or st.stopped then return true end
        v = math.max(0, v)
        if st.pausedAt then st.pausedAt = v else st.startedAt = now() - v end
    elseif action == 'volume' then
        local v = tonumber(value)
        if not v then return true end
        st.volume = math.min(1.0, math.max(0.0, v))
    elseif action == 'loop' then
        st.loop = (st.loop == 'all' and 'one') or (st.loop == 'one' and 'none') or 'all'
    elseif action == 'shuffle' then
        st.shuffle = not st.shuffle
        if st.shuffle and #q > 1 then
            -- current track goes first, the rest is shuffled (no restart)
            if st.index > 0 and not st.stopped then
                local cur = table.remove(q, st.index)
                table.insert(q, 1, cur)
                st.index = 1
                shuffleList(q, 2)
            else
                shuffleList(q, 1)
            end
            qChanged = true
        end
    elseif action == 'jump' then
        local i = tonumber(value)
        if not i or not q[i] then return nil, L('no_such_track') end
        startTrack(st, i)
    elseif action == 'remove' then
        local i = tonumber(value)
        if not i or not q[i] then return nil, L('no_such_track') end
        table.remove(q, i)
        qChanged = true
        if i < st.index then
            st.index = st.index - 1
        elseif i == st.index then
            if #q == 0 then
                st.stopped = true
            elseif not st.stopped then
                startTrack(st, math.min(i, #q))
            end
        end
    elseif action == 'clear' then
        q = {}
        st = newState(st)
        qChanged = true
    else
        return nil, L('unknown_action')
    end

    commit(veh, st, q, qChanged)
    return true
end

function H.playlists(src)
    local owner = getOwner(src)
    if not owner then return nil, L('no_identifier') end

    local pls = MySQL.query.await('SELECT id, name FROM carradio_playlists WHERE owner = ? ORDER BY id', { owner }) or {}
    if #pls == 0 then return {} end

    local ids, byId = {}, {}
    for _, p in ipairs(pls) do
        p.tracks = {}
        ids[#ids + 1] = p.id
        byId[p.id] = p
    end

    local rows = MySQL.query.await(
        ('SELECT id, playlist_id, t, yt_id, url, title, artist FROM carradio_tracks WHERE playlist_id IN (%s) ORDER BY position, id')
            :format(table.concat(ids, ',')), {}) or {}

    for _, r in ipairs(rows) do
        local p = byId[r.playlist_id]
        if p then
            p.tracks[#p.tracks + 1] = { rowId = r.id, t = r.t, id = r.yt_id, url = r.url, title = r.title, artist = r.artist }
        end
    end
    return pls
end

function H.createPlaylist(src, a)
    local owner = getOwner(src)
    if not owner then return nil, L('no_identifier') end
    local name = trim(tostring(a.name or ''))
    if #name < 1 or #name > 32 then return nil, L('name_length') end
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM carradio_playlists WHERE owner = ?', { owner }) or 0
    if count >= Config.MaxPlaylists then return nil, L('max_playlists', Config.MaxPlaylists) end
    local id = MySQL.insert.await('INSERT INTO carradio_playlists (owner, name) VALUES (?, ?)', { owner, name })
    return { id = id }
end

function H.renamePlaylist(src, a)
    local owner = getOwner(src)
    local name = trim(tostring(a.name or ''))
    if #name < 1 or #name > 32 then return nil, L('name_length') end
    MySQL.update.await('UPDATE carradio_playlists SET name = ? WHERE id = ? AND owner = ?', { name, tonumber(a.id) or 0, owner })
    return true
end

function H.deletePlaylist(src, a)
    local owner = getOwner(src)
    local id = tonumber(a.id) or 0
    if not ownPlaylist(owner, id) then return nil, L('no_such_playlist') end
    MySQL.query.await('DELETE FROM carradio_tracks WHERE playlist_id = ?', { id })
    MySQL.query.await('DELETE FROM carradio_playlists WHERE id = ?', { id })
    return true
end

local function insertTrack(playlistId, tr)
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM carradio_tracks WHERE playlist_id = ?', { playlistId }) or 0
    if count >= Config.MaxTracksPerPlaylist then
        return nil, L('playlist_full', Config.MaxTracksPerPlaylist)
    end
    local pos = (MySQL.scalar.await('SELECT MAX(position) FROM carradio_tracks WHERE playlist_id = ?', { playlistId }) or 0) + 1
    MySQL.insert.await('INSERT INTO carradio_tracks (playlist_id, t, yt_id, url, title, artist, position) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { playlistId, tr.t, tr.id, tr.url, tr.title, tr.artist, pos })
    return true
end

function H.addToPlaylist(src, a)
    local owner = getOwner(src)
    local id = tonumber(a.id) or 0
    if not ownPlaylist(owner, id) then return nil, L('no_such_playlist') end
    local tr, e = resolveTrack(a.url)
    if not tr then return nil, e end
    local ok, err = insertTrack(id, tr)
    if not ok then return nil, err end
    return { title = tr.title }
end

function H.addCurrentToPlaylist(src, a)
    local owner = getOwner(src)
    local id = tonumber(a.id) or 0
    if not ownPlaylist(owner, id) then return nil, L('no_such_playlist') end
    local veh = GetVehiclePedIsIn(GetPlayerPed(src), false)
    if veh == 0 then return nil, L('in_vehicle_required') end
    local st = getVeh(veh)
    if st.stopped or not st.track then return nil, L('nothing_playing') end
    local ok, err = insertTrack(id, st.track)
    if not ok then return nil, err end
    return { title = st.track.title }
end

function H.removeFromPlaylist(src, a)
    local owner = getOwner(src)
    MySQL.query.await([[
        DELETE t FROM carradio_tracks t
        JOIN carradio_playlists p ON p.id = t.playlist_id
        WHERE t.id = ? AND p.owner = ?
    ]], { tonumber(a.rowId) or 0, owner })
    return true
end

function H.playPlaylist(src, a)
    local veh, err = controlVeh(src)
    if not veh then return nil, err end
    local owner = getOwner(src)
    local id = tonumber(a.id) or 0
    if not ownPlaylist(owner, id) then return nil, L('no_such_playlist') end

    local rows = MySQL.query.await('SELECT t, yt_id, url, title, artist FROM carradio_tracks WHERE playlist_id = ? ORDER BY position, id', { id }) or {}
    if #rows == 0 then return nil, L('playlist_empty') end
    if not DoesEntityExist(veh) then return nil, L('vehicle_gone') end

    local st, q = getVeh(veh)

    if a.mode == 'queue' then
        for _, r in ipairs(rows) do
            if #q >= Config.MaxQueue then break end
            q[#q + 1] = toQueueTrack(r)
        end
        if st.stopped and #q > 0 then startTrack(st, 1) end
        commit(veh, st, q, true)
        return true
    end

    q = {}
    for i = 1, math.min(#rows, Config.MaxQueue) do q[i] = toQueueTrack(rows[i]) end

    local start = math.min(math.max(tonumber(a.start) or 1, 1), #q)
    st.shuffle = a.shuffle == true
    if st.shuffle then
        local first = table.remove(q, start)
        shuffleList(q, 1)
        table.insert(q, 1, first)
        start = 1
    end

    startTrack(st, start)
    commit(veh, st, q, true)
    return true
end

-- ---------------------------------------------------------------------
-- Request router (+ simple anti-spam)
-- ---------------------------------------------------------------------
local lastReq = {}
local noLimit = { time = true, playlists = true }

RegisterNetEvent('rayn_carradio:req', function(rid, name, args)
    local src = source
    local h = H[name]
    if not h then return end

    if not noLimit[name] then
        local t = GetGameTimer()
        if lastReq[src] and t - lastReq[src] < 100 then
            TriggerClientEvent('rayn_carradio:res', src, rid, { ok = false, err = L('too_fast') })
            return
        end
        lastReq[src] = t
    end

    CreateThread(function()
        local ok, data, err = pcall(h, src, type(args) == 'table' and args or {})
        local res
        if not ok then
            print(('^1[rayn_carradio] error in %s: %s^0'):format(name, tostring(data)))
            res = { ok = false, err = L('server_error') }
        elseif data == nil then
            res = { ok = false, err = err or L('error') }
        else
            res = { ok = true, data = data }
        end
        TriggerClientEvent('rayn_carradio:res', src, rid, res)
    end)
end)

AddEventHandler('playerDropped', function()
    lastReq[source] = nil
end)

-- ---------------------------------------------------------------------
-- Track ended / playback error (reported by someone inside the vehicle)
-- ---------------------------------------------------------------------
RegisterNetEvent('rayn_carradio:ended', function(net, tid, isError)
    local src = source
    local veh = NetworkGetEntityFromNetworkId(tonumber(net) or 0)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if GetVehiclePedIsIn(GetPlayerPed(src), false) ~= veh then return end

    local st, q = getVeh(veh)
    if st.stopped or st.tid ~= tid then return end -- already reported by another occupant

    if isError then
        -- skip unplayable tracks; stop if every track in the queue fails
        st.errors = (st.errors or 0) + 1
        if st.errors >= #q then
            st.errors = 0
            st.stopped = true
        else
            local loop = st.loop
            if loop == 'one' then st.loop = 'all' end
            advance(st, q, true)
            st.loop = loop
        end
    else
        st.errors = 0
        advance(st, q, true)
    end

    commit(veh, st, q, false)
end)
