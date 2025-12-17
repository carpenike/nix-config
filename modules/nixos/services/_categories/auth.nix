# Authentication and identity services
# Import this category for hosts that provide auth services
{ ... }:
{
  imports = [
    ../onepassword-connect # 1Password Connect API server
    ../pocketid # Pocket ID authentication portal
  ];
}
