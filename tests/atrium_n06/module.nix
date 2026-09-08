{ config, lib, pkgs, ... }:
let
  cfg = config.services.atriumWhiskeyEgressFixture;
  policyFile = pkgs.writeText "atrium-n06-egress-policy.json" (builtins.toJSON cfg.policy);
in
{
  options.services.atriumWhiskeyEgressFixture = {
    enable = lib.mkEnableOption "isolated Whiskey network-namespace egress fixture";
    isolatedHarness = lib.mkOption { type = lib.types.bool; default = false; };
    namespacePath = lib.mkOption { type = lib.types.str; };
    namespaceIdentity = lib.mkOption { type = lib.types.str; };
    bindingsFile = lib.mkOption { type = lib.types.str; };
    policy = lib.mkOption { type = lib.types.attrs; };
    consumerUnit = lib.mkOption {
      type = lib.types.str;
      default = "atrium-whiskey-fixture";
    };
    modelConfigFile = lib.mkOption { type = lib.types.str; };
    imageEnvironmentFile = lib.mkOption { type = lib.types.str; };
    credentialPaths = lib.mkOption { type = lib.types.listOf lib.types.str; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.isolatedHarness
          && (cfg.policy.isolated or false)
          && lib.hasPrefix "/run/atrium-n06/" cfg.namespacePath
          && lib.hasPrefix "/run/atrium-n06/" cfg.bindingsFile
          && lib.hasPrefix "/run/atrium-n06/" cfg.modelConfigFile
          && lib.hasPrefix "/run/atrium-n06/" cfg.imageEnvironmentFile
          && lib.all (lib.hasPrefix "/run/atrium-n06/") cfg.credentialPaths
          && builtins.match "[a-z0-9-]+-fixture" cfg.consumerUnit != null;
        message = "N06 egress may join only explicitly isolated runtime fixture namespaces.";
      }
      {
        assertion = (cfg.policy.service_uid or 0) >= 1000;
        message = "N06 requires a dedicated non-root synthetic consumer UID.";
      }
    ];
    systemd.services.atrium-whiskey-egress-fixture = {
      description = "Install isolated Whiskey address-level egress policy";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        NetworkNamespacePath = cfg.namespacePath;
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        NoNewPrivileges = true;
        ExecStart = "${pkgs.python3}/bin/python ${./egress.py} --policy ${policyFile}"
          + " --bindings ${lib.escapeShellArg cfg.bindingsFile}"
          + " --expected-netns ${lib.escapeShellArg cfg.namespaceIdentity}"
          + " --nft ${pkgs.nftables}/bin/nft";
      };
    };
    systemd.services.${cfg.consumerUnit} = {
      requires = [ "atrium-whiskey-egress-fixture.service" ];
      after = [ "atrium-whiskey-egress-fixture.service" ];
      environment.WWW_ATRIUM_MODEL_CONFIG = cfg.modelConfigFile;
      serviceConfig = {
        User = toString cfg.policy.service_uid;
        NetworkNamespacePath = cfg.namespacePath;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ ];
        AmbientCapabilities = [ ];
        EnvironmentFile = cfg.imageEnvironmentFile;
        UnsetEnvironment = [ "ANTHROPIC_API_KEY" "ANTHROPIC_MODEL" ];
        ReadOnlyPaths = cfg.credentialPaths;
      };
    };
  };
}
