# Productivity and self-hosted applications
# Import this category for general-purpose app hosting
{ ... }:
{
  imports = [
    ../actual # Actual Budget personal finance
    ../bichon # Email archiving system
    ../coachiq # Coach IQ management
    ../cooklang # Recipe management server
    ../cooklang-federation # Recipe discovery service
    ../enclosed # Encrypted note sharing
    ../homepage # Dashboard
    ../it-tools # Developer utilities
    ../mealie # Recipe manager
    ../miniflux # RSS reader
    ../n8n # Workflow automation
    ../paperless # Document management
    ../paperless-ai # Document tagging AI
    ../searxng # Meta search engine
    ../termix # SSH web terminal
    ../thelounge # IRC web client
    ../tududi # Task and productivity management
  ];
}
