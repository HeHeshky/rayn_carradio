Config = {}

-- Language: 'en', 'pl', 'fr', 'de', 'ru' (files in /locales)
Config.Locale               = 'en'

-- Opening the radio
Config.OpenCommand          = 'carradio'   -- chat command
Config.OpenKey              = ''          -- default key, e.g. 'F7' ('' = no default, players bind it in Settings > Key Bindings > FiveM)

-- Seats allowed to control the radio: -1 = driver, 0 = front passenger, 1/2 = rear
Config.ControlSeats         = { -1, 0 }

-- Vehicle classes without a radio (13 = cycles, 8 = motorcycles)
Config.BlockedVehicleClasses = {
    [13] = true,
    -- [8] = true,
}

-- Sound
Config.DefaultVolume        = 0.5    -- default radio volume (0.0 - 1.0)
Config.MaxDistance          = 35.0   -- how far (m) the music can be heard outside the vehicle
Config.OutsideVolume        = 0.6    -- volume multiplier for players standing outside the vehicle
Config.MaxStreams           = 4      -- max vehicles playing at once for a single player (closest first)

-- Performance (leave as is unless you know what you are doing)
Config.TickMs               = 200    -- how often (ms) volume is recalculated (locally, no network)
Config.ScanMs               = 1000   -- how often (ms) nearby vehicles with music are scanned

-- Limits
Config.MaxQueue             = 100    -- max tracks in a vehicle queue
Config.MaxPlaylists         = 15     -- max playlists per character
Config.MaxTracksPerPlaylist = 100    -- max tracks per playlist

-- Personal volume command for all radios (e.g. /radiovol 30). false = disabled
Config.PersonalVolumeCommand = 'radiovol'
