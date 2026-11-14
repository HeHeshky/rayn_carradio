-- =====================================================================
--  rayn_carradio – client bridge (open file)
--  Replace the notification with your own system if you want.
-- =====================================================================

function Bridge_Notify(msg)
    -- Example for ox_lib:  lib.notify({ description = msg })
    -- Example for ESX:     ESX.ShowNotification(msg)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, false)
end
