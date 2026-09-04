# AI and machine learning services
# Import this category for hosts running AI workloads
{ ... }:
{
  imports = [
    ../copilot-api # GitHub Copilot subscription as an Anthropic/OpenAI-compatible API
    ../litellm # Unified AI gateway
    ../open-webui # AI chat interface
  ];
}
