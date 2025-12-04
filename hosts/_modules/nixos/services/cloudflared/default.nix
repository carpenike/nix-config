# Declarative Cloudflare Tunnel (cloudflared) module
# Auto-discovers services from Caddy virtualHosts and generates ingress configuration
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.services.cloudflared;

  # Helper function to find all Caddy virtual hosts that have opted into a specific tunnel.
  # This makes Caddy's virtualHosts the single source of truth for web services.
  findTunneledVhosts = tunnelName:
    attrValues (filterAttrs
      (_name: vhost:
        vhost.enable
        && (vhost.cloudflare or null) != null
        && vhost.cloudflare.enable
        && vhost.cloudflare.tunnel == tunnelName
      )
      config.modules.services.caddy.virtualHosts);

  registrationHelper = pkgs.writeScript "cloudflared-dns-register.py" ''
    #!${pkgs.python3}/bin/python3
    import argparse
    import json
    import os
    from pathlib import Path
    import shutil
    import subprocess
    import sys
    import tempfile
    import time
    import traceback
    import urllib.request

    def write_metrics(path, tunnel, status, total, counts):
      if not path:
        return
      path_obj = Path(path)
      path_obj.parent.mkdir(parents=True, exist_ok=True)
      tmp_path = path_obj.with_name(path_obj.name + ".tmp")
      timestamp = int(time.time())
      with tmp_path.open("w", encoding="utf-8") as fh:
        fh.write("# HELP cloudflared_dns_registration_last_run_timestamp_seconds Unix timestamp of the last DNS automation run\n")
        fh.write("# TYPE cloudflared_dns_registration_last_run_timestamp_seconds gauge\n")
        fh.write(f'cloudflared_dns_registration_last_run_timestamp_seconds{{tunnel="{tunnel}"}} {timestamp}\n')
        fh.write("# HELP cloudflared_dns_registration_run_status Exit status of the most recent DNS automation run (0=success)\n")
        fh.write("# TYPE cloudflared_dns_registration_run_status gauge\n")
        fh.write(f'cloudflared_dns_registration_run_status{{tunnel="{tunnel}"}} {status}\n')
        fh.write("# HELP cloudflared_dns_registration_total_records Number of hostnames evaluated for registration\n")
        fh.write("# TYPE cloudflared_dns_registration_total_records gauge\n")
        fh.write(f'cloudflared_dns_registration_total_records{{tunnel="{tunnel}"}} {total}\n')
        fh.write("# HELP cloudflared_dns_registration_updates Number of DNS records updated or created\n")
        fh.write("# TYPE cloudflared_dns_registration_updates counter\n")
        fh.write(f'cloudflared_dns_registration_updates{{tunnel="{tunnel}"}} {counts["updated"]}\n')
        fh.write("# HELP cloudflared_dns_registration_unchanged Number of DNS records already up to date\n")
        fh.write("# TYPE cloudflared_dns_registration_unchanged counter\n")
        fh.write(f'cloudflared_dns_registration_unchanged{{tunnel="{tunnel}"}} {counts["unchanged"]}\n')
        fh.write("# HELP cloudflared_dns_registration_errors Number of errors encountered during the run\n")
        fh.write("# TYPE cloudflared_dns_registration_errors counter\n")
        fh.write(f'cloudflared_dns_registration_errors{{tunnel="{tunnel}"}} {counts["errors"]}\n')
      tmp_path.replace(path_obj)

    def cache_matches(cache_file, payload_file):
      if not cache_file:
        return False
      cache_path = Path(cache_file)
      payload_path = Path(payload_file)
      try:
        return cache_path.read_text(encoding="utf-8") == payload_path.read_text(encoding="utf-8")
      except FileNotFoundError:
        return False

    def update_cache(cache_file, payload_file):
      if not cache_file:
        return
      cache_path = Path(cache_file)
      cache_path.parent.mkdir(parents=True, exist_ok=True)
      shutil.copyfile(payload_file, cache_path)

    def run_cli(records, args, counts):
      if not args.origin_cert:
        raise RuntimeError("origin certificate is required for CLI registration")
      state_dir = Path(args.state_dir)
      state_dir.mkdir(parents=True, exist_ok=True)
      temp_home = None
      home_root = state_dir if args.persist_origin_cert else Path(tempfile.mkdtemp(prefix="cloudflared-cert-"))
      if not args.persist_origin_cert:
        temp_home = home_root
      try:
        cloudflared_dir = home_root / ".cloudflared"
        cloudflared_dir.mkdir(parents=True, exist_ok=True)
        dest_cert = cloudflared_dir / "cert.pem"
        if dest_cert.exists():
          dest_cert.unlink()
        shutil.copyfile(args.origin_cert, dest_cert)
        os.chmod(dest_cert, 0o400)
        env = os.environ.copy()
        env["HOME"] = str(home_root)
        for record in records:
          hostname = record["hostname"]
          print(f"[cloudflared] Registering {hostname} via CLI", flush=True)
          subprocess.run(
            [args.cloudflared_bin, "tunnel", "route", "dns", "--overwrite-dns", args.tunnel_name, hostname],
            check=True,
            env=env,
          )
          counts["updated"] += 1
        counts["unchanged"] = 0
      finally:
        if temp_home and temp_home.exists():
          shutil.rmtree(temp_home, ignore_errors=True)

    def cf_request(method, url, token, payload=None):
      data = payload.encode("utf-8") if payload else None
      req = urllib.request.Request(url, data=data, method=method)
      req.add_header("Authorization", f"Bearer {token}")
      req.add_header("Content-Type", "application/json")
      with urllib.request.urlopen(req, timeout=60) as resp:
        parsed = json.load(resp)
      if not parsed.get("success", True):
        message = parsed.get("errors")
        raise RuntimeError(f"Cloudflare API call failed: {message}")
      return parsed

    def fetch_zone_id(zone_name, token, cache):
      if zone_name in cache:
        return cache[zone_name]
      data = cf_request("GET", f"https://api.cloudflare.com/client/v4/zones?name={zone_name}&status=active", token)
      results = data.get("result") or []
      if not results:
        raise RuntimeError(f"Unable to resolve zone id for {zone_name}")
      zone_id = results[0]["id"]
      cache[zone_name] = zone_id
      return zone_id

    def fetch_existing_record(zone_id, record_type, hostname, token):
      data = cf_request(
        "GET",
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?type={record_type}&name={hostname}",
        token,
      )
      results = data.get("result") or []
      return results[0] if results else None

    def run_api(records, args, counts):
      if not args.api_token_file:
        raise RuntimeError("Cloudflare API token file is required for API mode")
      token = Path(args.api_token_file).read_text(encoding="utf-8").strip()
      if not token:
        raise RuntimeError("Cloudflare API token is empty")
      zone_cache = {}
      for record in records:
        hostname = record["hostname"]
        zone_name = record["zoneName"]
        record_type = record["recordType"]
        zone_id = fetch_zone_id(zone_name, token, zone_cache)
        desired_comment = record.get("comment") or ""
        payload = {
          "type": record_type,
          "name": hostname,
          "content": record["target"],
          "ttl": int(record["ttl"]),
          "proxied": bool(record["proxied"]),
        }
        if desired_comment:
          payload["comment"] = desired_comment

        existing = fetch_existing_record(zone_id, record_type, hostname, token)
        if existing:
          current_comment = existing.get("comment") or ""
          if (
            existing.get("content") == payload["content"]
            and bool(existing.get("proxied")) == payload["proxied"]
            and int(existing.get("ttl") or 0) == payload["ttl"]
            and current_comment == desired_comment
          ):
            counts["unchanged"] += 1
            continue
          record_id = existing["id"]
          print(f"[cloudflared] Updating {hostname} via API", flush=True)
          cf_request(
            "PUT",
            f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}",
            token,
            json.dumps(payload),
          )
        else:
          print(f"[cloudflared] Creating {hostname} via API", flush=True)
          cf_request(
            "POST",
            f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records",
            token,
            json.dumps(payload),
          )
        counts["updated"] += 1

    def main():
      parser = argparse.ArgumentParser(description="Cloudflare DNS registration helper")
      parser.add_argument("--mode", choices=["cli", "api"], required=True)
      parser.add_argument("--tunnel-name", required=True)
      parser.add_argument("--dns-records", required=True)
      parser.add_argument("--state-dir", required=True)
      parser.add_argument("--cloudflared-bin", required=True)
      parser.add_argument("--cache-file")
      parser.add_argument("--metrics-file")
      parser.add_argument("--origin-cert")
      parser.add_argument("--persist-origin-cert", action="store_true")
      parser.add_argument("--api-token-file")
      args = parser.parse_args()

      records = json.loads(Path(args.dns_records).read_text(encoding="utf-8"))
      if not isinstance(records, list):
        raise RuntimeError("DNS record payload is malformed")

      total = len(records)
      counts = {"updated": 0, "unchanged": 0, "errors": 0}

      if total == 0:
        write_metrics(args.metrics_file, args.tunnel_name, 0, total, counts)
        return 0

      if args.cache_file and cache_matches(args.cache_file, args.dns_records):
        counts["unchanged"] = total
        write_metrics(args.metrics_file, args.tunnel_name, 0, total, counts)
        return 0

      status = 0
      try:
        if args.mode == "cli":
          run_cli(records, args, counts)
        else:
          run_api(records, args, counts)
        if args.cache_file:
          update_cache(args.cache_file, args.dns_records)
      except Exception:
        status = 1
        traceback.print_exc()
      finally:
        if status != 0:
          pending = max(0, total - (counts["updated"] + counts["unchanged"]))
          counts["errors"] = pending if pending > 0 else 1
        write_metrics(args.metrics_file, args.tunnel_name, status, total, counts)

      return status

    if __name__ == "__main__":
      sys.exit(main())
  '';

in
{
  options.modules.services.cloudflared = {
    enable = mkEnableOption "Cloudflare Tunnel (cloudflared) service";

    package = mkOption {
      type = types.package;
      default = pkgs.cloudflared;
      description = "The cloudflared package to use.";
    };

    user = mkOption {
      type = types.str;
      default = "cloudflared";
      description = "User to run the cloudflared service.";
    };

    group = mkOption {
      type = types.str;
      default = "cloudflared";
      description = "Group to run the cloudflared service.";
    };

    tunnels = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          id = mkOption {
            type = types.str;
            description = "The Cloudflare Tunnel UUID.";
            example = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
          };

          credentialsFile = mkOption {
            type = types.path;
            description = "Path to the tunnel credentials JSON file (managed by SOPS).";
            example = literalExpression ''config.sops.secrets."cloudflared/homelab-credentials".path'';
          };

          defaultService = mkOption {
            type = types.str;
            # By default, point to Caddy, which handles all subsequent routing and auth.
            default = "http://127.0.0.1:${toString (config.services.caddy.httpPort or 80)}";
            description = "The default backend service to which all discovered hostnames will be routed.";
          };

          extraConfig = mkOption {
            type = with types; attrsOf (oneOf [ str int bool (listOf (attrsOf str)) ]);
            default = { };
            description = "Extra configuration options to be merged into the generated config.yaml.";
            example = {
              "log-level" = "debug";
            };
          };

          dnsApiTokenFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''Path to a Cloudflare API token file with permission to edit DNS records (Zone:DNS:Edit). Required when using API-based DNS registration.'';
          };

          originCertFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''Path to the Cloudflare origin certificate (cert.pem) created via "cloudflared login". Enables using the `cloudflared tunnel route dns` CLI to register hostnames.'';
          };

          persistOriginCert = mkOption {
            type = types.bool;
            default = true;
            description = "If true, copy the origin certificate into the tunnel state directory for reuse instead of creating a temporary HOME for each registration run.";
          };

          dnsRegistration = mkOption {
            type = types.submodule {
              options = {
                enable = (mkEnableOption "automatic DNS record management for discovered hostnames") // { default = true; };

                mode = mkOption {
                  type = types.enum [ "auto" "cli" "api" ];
                  default = "auto";
                  description = "Selects which registrar to use: cloudflared CLI, Cloudflare API, or automatically prefer CLI when an origin cert exists.";
                };

                zoneName = mkOption {
                  type = types.str;
                  default = config.networking.domain or "holthome.net";
                  description = "Default Cloudflare zone name that owns the tunneled hostnames.";
                };

                cache = mkOption {
                  type = types.submodule {
                    options = {
                      enable = (mkEnableOption "skip DNS registration when the desired payload hasn't changed") // { default = true; };

                      file = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional absolute path to cache the last DNS payload. Defaults to the tunnel state directory.";
                      };
                    };
                  };
                  default = { };
                  description = "Registration caching controls.";
                };

                defaults = mkOption {
                  type = types.submodule {
                    options = {
                      recordType = mkOption {
                        type = types.enum [ "CNAME" ];
                        default = "CNAME";
                        description = "DNS record type to create (currently CNAME for tunnel endpoints).";
                      };

                      proxied = mkOption {
                        type = types.bool;
                        default = true;
                        description = "Whether Cloudflare should proxy traffic for created records.";
                      };

                      ttl = mkOption {
                        type = types.int;
                        default = 120;
                        description = "TTL (seconds) to assign to created DNS records (use 1 for 'auto').";
                      };

                      target = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional override for the DNS record content. Defaults to <tunnel-id>.cfargotunnel.com.";
                      };

                      comment = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional comment/metadata to attach to DNS records when using the API.";
                      };
                    };
                  };
                  default = { };
                  description = "Default DNS payload values applied to every hostname unless overridden at the virtual host level.";
                };

                metrics = mkOption {
                  type = types.submodule {
                    options = {
                      enable = mkEnableOption "emit Prometheus textfile metrics describing DNS registration runs";

                      textfilePath = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional metrics output path. Defaults to a file inside the tunnel state directory when enabled.";
                      };
                    };
                  };
                  default = { };
                  description = "Observability settings for registration automation.";
                };
              };
            };
            default = { };
            description = "Controls DNS automation for hostnames routed through this tunnel.";
          };
        };
      });
      default = { };
      description = "An attribute set of Cloudflare Tunnels to configure and run.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.services = mapAttrs'
      (tunnelName: tunnel:
        let
          vhosts = findTunneledVhosts tunnelName;
          hostnames = map (vhost: vhost.hostName) vhosts;

          httpsDefaultService = builtins.match "^https://.*" tunnel.defaultService != null;

          buildIngressRule = hostname:
            let
              base = {
                inherit hostname;
                service = tunnel.defaultService;
              };
              originRequest =
                if httpsDefaultService then { originServerName = hostname; }
                else null;
            in
            if originRequest == null then base else base // { inherit originRequest; };

          configFile = pkgs.writeText "${tunnelName}-config.yaml" (builtins.toJSON (
            {
              "credentials-file" = toString tunnel.credentialsFile;
              ingress =
                let
                  ingressRules = map buildIngressRule hostnames;
                in
                ingressRules ++ [{ service = "http_status:404"; }];
            } // tunnel.extraConfig
          ));

          dnsReg = tunnel.dnsRegistration;
          dnsDefaults = dnsReg.defaults;
          defaultTarget = dnsDefaults.target or null;
          effectiveTarget = if defaultTarget != null then defaultTarget else "${tunnel.id}.cfargotunnel.com";

          dnsRecords =
            filter (record: record != null)
              (map
                (vhost:
                  let
                    hostDns = vhost.cloudflare.dns or { };
                    registerHost = hostDns.register or true;
                    hostZone = hostDns.zoneName or null;
                    hostRecordType = hostDns.recordType or null;
                    hostProxied = hostDns.proxied or null;
                    hostTtl = hostDns.ttl or null;
                    hostTarget = hostDns.target or null;
                    hostComment = hostDns.comment or null;
                  in
                  if !registerHost then null else {
                    hostname = vhost.hostName;
                    zoneName = if hostZone != null then hostZone else dnsReg.zoneName;
                    recordType = if hostRecordType != null then hostRecordType else dnsDefaults.recordType;
                    proxied = if hostProxied != null then hostProxied else dnsDefaults.proxied;
                    ttl = if hostTtl != null then hostTtl else dnsDefaults.ttl;
                    target = if hostTarget != null then hostTarget else effectiveTarget;
                    comment = if hostComment != null then hostComment else (dnsDefaults.comment or null);
                  }
                )
                vhosts);

          dnsRecordsFile = pkgs.writeText "${tunnelName}-dns-records.json" (builtins.toJSON dnsRecords);

          stateDirName = "cloudflared-${tunnelName}";
          stateDirPath = "/var/lib/${stateDirName}";

          cacheCfg = dnsReg.cache;
          cacheFile =
            if cacheCfg.enable && dnsRecords != [ ]
            then toString (cacheCfg.file or "${stateDirPath}/dns-records.json")
            else null;

          metricsCfg = dnsReg.metrics;
          metricsFile =
            if metricsCfg.enable && dnsRecords != [ ]
            then toString (metricsCfg.textfilePath or "${stateDirPath}/dns-metrics.prom")
            else null;

          registrationEnabled = dnsReg.enable && dnsRecords != [ ];

          resolvedMode =
            if !registrationEnabled then null
            else if dnsReg.mode == "cli" then
              (if tunnel.originCertFile == null then
                throw ''Cloudflare tunnel "${tunnelName}" is set to CLI DNS registration but originCertFile is missing.''
              else "cli")
            else if dnsReg.mode == "api" then
              (if tunnel.dnsApiTokenFile == null then
                throw ''Cloudflare tunnel "${tunnelName}" is set to API DNS registration but dnsApiTokenFile is missing.''
              else "api")
            else if tunnel.originCertFile != null then "cli"
            else if tunnel.dnsApiTokenFile != null then "api"
            else throw ''Cloudflare tunnel "${tunnelName}" cannot auto-register DNS without either originCertFile or dnsApiTokenFile.'';

          scriptArgs =
            if !registrationEnabled then [ ]
            else
              let
                baseArgs = [
                  registrationHelper
                  "--mode"
                  resolvedMode
                  "--tunnel-name"
                  tunnelName
                  "--dns-records"
                  dnsRecordsFile
                  "--state-dir"
                  stateDirPath
                  "--cloudflared-bin"
                  "${cfg.package}/bin/cloudflared"
                ];
              in
              baseArgs
              ++ lib.optionals (cacheFile != null) [ "--cache-file" cacheFile ]
              ++ lib.optionals (metricsFile != null) [ "--metrics-file" metricsFile ]
              ++ lib.optionals (resolvedMode == "cli") (
                [ "--origin-cert" (toString tunnel.originCertFile) ]
                ++ lib.optionals tunnel.persistOriginCert [ "--persist-origin-cert" ]
              )
              ++ lib.optionals (resolvedMode == "api") [ "--api-token-file" (toString tunnel.dnsApiTokenFile) ];

          registrationWrapper =
            if registrationEnabled then
              pkgs.writeShellScript "cloudflared-${tunnelName}-dns-pre" ''
                exec ${lib.escapeShellArgs scriptArgs}
              '' else null;

          cacheDir = if cacheFile != null then builtins.dirOf cacheFile else null;
          metricsDir = if metricsFile != null then builtins.dirOf metricsFile else null;
        in
        nameValuePair "cloudflared-${tunnelName}" {
          description = "Cloudflare Tunnel for ${tunnelName}";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" "caddy.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "notify";
            ExecStart = "${cfg.package}/bin/cloudflared tunnel --no-autoupdate --config ${configFile} run ${tunnel.id}";
            Restart = "on-failure";
            RestartSec = "5s";
            User = cfg.user;
            Group = cfg.group;
            StateDirectory = stateDirName;
            StateDirectoryMode = "0750";
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
            ReadWritePaths =
              [ stateDirPath ]
                ++ lib.optional (cacheDir != null && cacheDir != stateDirPath) cacheDir
                ++ lib.optional (metricsDir != null && metricsDir != stateDirPath) metricsDir;
          } // lib.optionalAttrs (registrationWrapper != null) {
            ExecStartPre = [ registrationWrapper ];
          };
        }
      )
      cfg.tunnels;

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = { };
  };
}
