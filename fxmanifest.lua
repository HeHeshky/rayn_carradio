fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'rayn_carradio'
author 'RAYN Scripts'
description 'RAYN CarRadio - car radio: YouTube / MP3 links, queue, playlists, synced 3D sound for everyone'
version '1.0.0'

shared_scripts {
    'config.lua',
    'locales/*.lua',
    'shared/locale.lua',
}

client_scripts {
    'bridge/client.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependency 'oxmysql'
