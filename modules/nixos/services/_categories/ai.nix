# AI and machine learning services
# Import this category for hosts running AI workloads
{ ... }:
{
  imports = [
    ../litellm # Unified AI gateway
    ../open-webui # AI chat interface
  ];
}
