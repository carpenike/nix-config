# Download client services (torrent, usenet, automation)
# Import this category for hosts that handle media downloads
{ ... }:
{
  imports = [
    ../autobrr     # IRC announce bot for torrent racing
    ../cross-seed  # Automatic cross-seeding daemon
    ../qbittorrent # Torrent download client
    ../qbit-manage # Torrent lifecycle management
    ../qui         # Modern qBittorrent web interface
    ../sabnzbd     # Usenet download client
    ../tqm         # Fast torrent management for racing
    ../unpackerr   # Archive extraction for Starr apps
  ];
}
