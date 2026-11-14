-- Tables are created automatically on resource start. This file is only a fallback.
CREATE TABLE IF NOT EXISTS `carradio_playlists` (
    `id` INT(11) NOT NULL AUTO_INCREMENT,
    `owner` VARCHAR(80) NOT NULL,
    `name` VARCHAR(40) NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    INDEX `owner` (`owner`)
);

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
);
