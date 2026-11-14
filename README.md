# RAYN CarRadio – free car radio for FiveM

A double-DIN car radio with a modern touchscreen. Players paste YouTube or direct
audio links, build a queue and save playlists. Everyone in and around the vehicle hears the
same moment of the track with distance-based volume.

**Free & open source.** Documentation: https://rayn-scripts.gitbook.io/rayn-scripts-docs/rayn_carradio/

## Features
- YouTube (videos, shorts, youtu.be, live) and direct audio / internet radio links (.mp3, .ogg, streams)
- Queue: play now, add to queue, jump, remove, shuffle, repeat (all / one / off), seek
- Playlists saved per character (ESX / QBCore / standalone license)
- Synced for all players: music starts from the server clock, no audio streaming between players
- 3D volume: full inside the vehicle, fades with distance outside
- No lag at any speed: vehicle positions are never sent over the network
- Personal volume command (`/radiovol 0-100`)
- 5 languages: English, Polish, French, German, Russian

## Requirements
- oxmysql
- ESX, QBCore or standalone (see `bridge/server.lua`)

## Installation
1. Put `rayn_carradio` into your `resources` folder.
2. Add to `server.cfg` **after** oxmysql:
   ```
   ensure rayn_carradio
   ```
3. Database tables are created automatically (fallback: `sql/carradio.sql`).
4. Set the language in `config.lua`: `Config.Locale = 'en'` (`en`, `pl`, `fr`, `de`, `ru`).

## Usage
- `/carradio` (or the key set in `Config.OpenKey`, rebindable in Settings > Key Bindings > FiveM) – open the radio.
  Only seats listed in `Config.ControlSeats` can control it (driver and front passenger by default).
- `/radiovol 0-100` – personal volume of every radio you hear.

## Files
| File | Purpose |
|------|---------|
| `config.lua` | All settings |
| `locales/*.lua` | Translations – copy `en.lua` to add a new language |
| `bridge/server.lua` | Character identifier (framework support) |
| `bridge/client.lua` | Notifications |
| `html/*` | UI |

## Notes
- Some YouTube videos disable embedding – the radio skips them automatically.
- The radio keeps playing after leaving the vehicle; turn it off with the power button.

## Disclaimer
This resource is free. It does not host or distribute any music – players play content from
links they provide, and server owners are responsible for the content played on their servers.
RAYN CarRadio is not affiliated with or endorsed by YouTube, Google or Apple.
