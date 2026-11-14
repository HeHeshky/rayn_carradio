-- =====================================================================
--  rayn_carradio – server bridge (open file)
--  Edit this file to support a custom framework.
-- =====================================================================

local ESX, QB

CreateThread(function()
    if GetResourceState('es_extended') == 'started' then
        ESX = exports['es_extended']:getSharedObject()
    elseif GetResourceState('qb-core') == 'started' then
        QB = exports['qb-core']:GetCoreObject()
    end
end)

-- Returns a unique, persistent id of the player's CHARACTER.
-- Playlists are stored per this id.
function Bridge_GetOwner(src)
    if ESX then
        local xPlayer = ESX.GetPlayerFromId(src)
        if xPlayer then return xPlayer.identifier end
    elseif QB then
        local Player = QB.Functions.GetPlayer(src)
        if Player then return Player.PlayerData.citizenid end
    end

    -- standalone fallback: Rockstar license
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, 8) == 'license:' then return id end
    end
    return nil
end
