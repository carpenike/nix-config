# Dataset protection policy type definition
{ lib }:
let
  inherit (lib) mkOption types;
  positiveSeconds = types.ints.positive;
in
{
  protectionPolicySubmodule = types.submodule {
    options = {
      class = mkOption {
        type = types.enum [ "system" "critical" "standard" "ephemeral" ];
        description = "Recovery criticality assigned to this dataset.";
      };

      objectives = {
        onsiteRpoSeconds = mkOption {
          type = types.nullOr positiveSeconds;
          description = "Maximum acceptable onsite data loss in seconds, or null when not guaranteed.";
        };

        offsiteRpoSeconds = mkOption {
          type = types.nullOr positiveSeconds;
          description = "Maximum acceptable offsite data loss in seconds, or null when not guaranteed.";
        };

        rtoSeconds = mkOption {
          type = types.nullOr positiveSeconds;
          description = "Maximum acceptable recovery time in seconds, or null when not guaranteed.";
        };
      };

      requiredTiers = mkOption {
        type = types.listOf (types.enum [
          "local-snapshot"
          "replication"
          "nas-backup"
          "offsite-backup"
          "automated-restore"
          "independent-restore"
          "external-bootstrap"
        ]);
        description = "Protection mechanisms required to satisfy this dataset's recovery objectives.";
      };

      consistency = mkOption {
        type = types.enum [
          "crash-consistent"
          "application-consistent"
          "transaction-consistent"
        ];
        default = "crash-consistent";
        description = "Consistency guarantee required from a recovery point.";
      };

      validator = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "sqlite-integrity";
        description = "Identifier for the semantic validator required after restore.";
      };

      allowEmptyBootstrap = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the dataset may initialize without restored data.";
      };

      mechanism = {
        name = mkOption {
          type = types.enum [ "standard" "pgbackrest" "external-bootstrap" "none" ];
          default = "standard";
          description = "Primary recovery mechanism implementing this policy.";
        };

        reason = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Reason for using a non-standard recovery mechanism.";
        };
      };

      notes = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Operator context that does not affect policy evaluation.";
      };
    };
  };
}
