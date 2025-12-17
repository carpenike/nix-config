# Media management services (*arr stack, streaming, metadata)
# Import this category for media server hosts
{ ... }:
{
  imports = [
    ../bazarr # Subtitle management
    ../kometa # Plex metadata manager (formerly PMM)
    ../lidarr # Music collection manager
    ../pinchflat # YouTube media manager
    ../plex # Plex media server
    ../prowlarr # Indexer manager (feeds *arr apps)
    ../radarr # Movie collection manager
    ../readarr # Book/audiobook collection manager
    ../seerr # Media request management
    ../sonarr # TV collection manager
    ../tautulli # Plex monitoring/statistics
    ../tdarr # Transcoding automation
    ../tracearr # Account sharing detection
  ];
}
