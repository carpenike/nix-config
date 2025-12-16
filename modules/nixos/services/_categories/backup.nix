# Backup and data protection services
# Import this category for hosts that manage backups
{ ... }:
{
  imports = [
    ../backup              # Unified backup management system
    ../backup-integration.nix # Legacy auto-discovery
    ../resilio-sync        # Peer-to-peer sync
  ];
}
