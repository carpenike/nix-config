# Atrium is retired on Forge (2026-11-08): the platform it wrapped
# (homelab-mcp) moves to the k8s cluster with per-URL views, and Atrium will
# be rebuilt there as a k8s service. Everything Atrium adds is gated on
# services.atriumForge.enable, so turning it off here removes its units,
# vhosts, header overrides, egress rules and backups while keeping the code
# (and the atrium-native-final tags) to rebuild from. Its datasets are not
# destroyed.
#
# What each consumer falls back to:
#   - Whiskey: WWW_ATRIUM_CONFIG and WWW_ATRIUM_MODEL_CONFIG go away, so WWW
#     serves its native routes only and text generation uses its own
#     ANTHROPIC_API_KEY again (still in whiskey-whiskey-whiskey-env).
#   - LiteLLM on Forge: back to hosts/forge/services/litellm.nix's own
#     configuration, without Atrium's cc.* reconciliation.
#   - homelab-mcp on Forge: no native profile; atrium-* scopes drop out.
#   - Ambit: its Atrium overview route stays closed (no deny feed); the
#     Pocket ID login is unaffected.
{ lib, ... }: {
  # Still imported: github-runner.nix reads its reviewed resolver list.
  imports = [ ./whiskey-egress.nix ];
  services.atriumForge.enable = lib.mkForce false;
  services.atriumForge.adoption.models = false;
  services.atriumForge.adoption.native = false;
  services.atriumForge.adoption.whiskey = false;
  services.atriumForge.adoption.whiskeyText = false;
}
