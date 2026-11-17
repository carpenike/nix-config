{ pkgs, ... }:

# Hank, Ryan's homelab engineer bot (Hermes, in the k8s cluster), over SSH.
# The same shape as grokbot in ./users.nix, plus one thing grokbot does not
# have: restarting and reloading services through polkit, for incident
# response. Everything else Hank changes goes through a pull request that Ryan
# merges (k8s-gitops docs/apps/hermes.md, "Host SSH").
#
# - Key only: locked password, mutableUsers = false. The private key lives in
#   1Password (hermes-hank/ssh_key) and is mounted only in Hank's screen pod.
# - `from=` pins the key to the cluster nodes: pod traffic leaves the cluster
#   with its node's address (10.20.10.20-23). It narrows the key to "from the
#   cluster"; the key itself is the boundary.
# - No forwarding of any kind, so a session cannot pivot or use an agent for
#   doas (security.pam.sshAgentAuth).
# - Not in wheel: no doas, so no nixos-rebuild, package installs or /etc
#   edits. systemd-journal for reading logs.
let
  # Units Hank may NOT restart or reload, even though the rest are allowed.
  # `systemctl restart` also starts a stopped unit, so this covers anything
  # whose start is itself dangerous:
  # - access paths: sshd, networking, WireGuard, the firewall, cloudflared;
  # - deploys and upgrades (nixos-upgrade, nixos-on-demand-upgrade, guards);
  # - every systemd-* unit (systemd-reboot, -poweroff, -networkd, -journald);
  # - storage: ZFS import/mount, snapshots, sanoid/syncoid replication;
  # - rescue/emergency, dbus, polkit itself, nix-daemon, logins.
  denied = builtins.concatStringsSep "|" [
    "sshd.*"
    "cloudflared.*"
    "wireguard.*"
    "wg-quick.*"
    "tailscaled"
    "nftables"
    "firewall"
    "network-.*"
    "dhcpcd"
    "systemd-.*"
    "nixos-.*"
    ".*upgrade.*"
    ".*deploy.*"
    ".*guard.*"
    "zfs-.*"
    "zpool-.*"
    "sanoid.*"
    "syncoid.*"
    "rescue"
    "emergency"
    "dbus.*"
    "polkit"
    "nix-daemon"
    "user@.*"
    "user-runtime-dir@.*"
    "getty@.*"
    "serial-getty@.*"
    "autovt@.*"
    "notify@.*"
  ];

  # The restart-only key (ssh alias forge-svc in Hank's sandbox). sshd forces
  # every login with it into this wrapper, which runs exactly
  # `systemctl restart|reload <unit>` and refuses everything else. No shell
  # ever parses the command, so Hermes may allowlist
  # `ssh forge-svc systemctl restart *` without a prompt. polkit (below) still
  # decides which units.
  hankSvc = pkgs.writeShellApplication {
    name = "hank-svc";
    runtimeInputs = [ pkgs.systemd pkgs.util-linux ];
    text = ''
      cmd="''${SSH_ORIGINAL_COMMAND:-}"
      re='^systemctl (restart|reload) ([A-Za-z0-9][A-Za-z0-9@._:-]*)$'
      if [[ ! "$cmd" =~ $re ]]; then
        echo "hank-svc: only 'systemctl restart|reload <unit>' is allowed with this key" >&2
        exit 2
      fi
      verb="''${BASH_REMATCH[1]}"
      unit="''${BASH_REMATCH[2]}"
      logger -t hank-svc "$verb $unit"
      exec systemctl "$verb" -- "$unit"
    '';
  };
in
{
  users.users.hank = {
    isNormalUser = true;
    description = "Hank, Hermes homelab engineer (SSH from the k8s cluster)";
    group = "hank";
    extraGroups = [ "systemd-journal" ];
    shell = pkgs.bash;
    hashedPassword = "!"; # locked: no password login
    openssh.authorizedKeys.keys = [
      # Restart-only: forced into hank-svc; `restrict` = no pty, no forwarding.
      ''command="${hankSvc}/bin/hank-svc",restrict,from="10.20.10.20,10.20.10.21,10.20.10.22,10.20.10.23" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBB/HZJLxBhGtzzeARVrp9v+YgA3ufY/eSV4vfCA8ANu hank-svc@hermes''
      ''from="10.20.10.20,10.20.10.21,10.20.10.22,10.20.10.23",no-agent-forwarding,no-X11-forwarding,no-port-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDetDxQqVN14Ksfsw68nTOjvHEx0wn+1nUpkX73YMUQs hank@hermes''
    ];
  };

  users.groups.hank = { };

  # polkit is what lets a non-root user ask systemd to restart a unit. Hank
  # may restart or reload any .service unit not in `denied`; every other
  # systemd action, and every other unit type (targets, timers, sockets,
  # mounts), is refused. Ryan's own access (wheel + doas) is unchanged.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (subject.user !== "hank") {
        return polkit.Result.NOT_HANDLED;
      }
      if (action.id !== "org.freedesktop.systemd1.manage-units") {
        return polkit.Result.NO;
      }
      var verb = action.lookup("verb");
      var unit = action.lookup("unit") || "";
      var verbs = ["restart", "try-restart", "reload", "reload-or-restart", "reload-or-try-restart"];
      if (verbs.indexOf(verb) < 0) {
        return polkit.Result.NO;
      }
      if (!/\.service$/.test(unit) || /^(${denied})\.service$/.test(unit)) {
        return polkit.Result.NO;
      }
      return polkit.Result.YES;
    });
  '';

  # A no-op service for Hank's acceptance test: restarting it changes nothing.
  systemd.services.hank-canary = {
    description = "No-op target for Hank's SSH restart test";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      DynamicUser = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
  };
}
