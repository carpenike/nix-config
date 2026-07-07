# Backup and data protection services
# Import this category for hosts that manage backups
{ ... }:
{
  imports = [
    ../backup # Unified backup management system
    ../resilio-sync # Peer-to-peer sync
  ];
}
