# Development and CI/CD services
# Import this category for hosts supporting development workflows
{ ... }:
{
  imports = [
    ../attic.nix       # Nix binary cache
    ../attic-admin.nix # Attic administration
    ../attic-push.nix  # Attic push automation
    ../github-runner   # GitHub Actions self-hosted runner
    ../netvisor        # Network discovery/visualization
    ../pgweb           # PostgreSQL web browser
  ];
}
