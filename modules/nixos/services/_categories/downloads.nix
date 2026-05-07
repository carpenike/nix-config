# Download client services (torrent, usenet, automation)
# Import this category for hosts that handle media downloads
{ ... }:
{
  imports = [
    ../autobrr # IRC announce bot for torrent racing
    ../qbittorrent # Torrent download client
    ../qui # Modern qBittorrent web interface (cross-seeding + lifecycle automations live here)
    ../sabnzbd # Usenet download client
    ../unpackerr # Archive extraction for Starr apps
  ];
}
