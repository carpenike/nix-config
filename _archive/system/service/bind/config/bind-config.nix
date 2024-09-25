{
  config,
  ...
}:
''
include "${config.sops.secrets."networking/bind/rndc-key".path}";
include "${config.sops.secrets."networking/bind/externaldns-key".path}";
include "${config.sops.secrets."networking/bind/ddnsupdate-key".path}";
controls {
  inet 127.0.0.1 allow {localhost;} keys {"rndc-key";};
};

# Only define known networks as trusted
acl trusted {
  10.10.0.0/16;   # LAN
  10.20.0.0/16;   # Servers
  10.30.0.0/16;   # WIRELESS
  10.40.0.0/16;   # IoT
};
acl badnetworks {  };

options {
  listen-on port 5391 { any; };
  directory "${config.services.bind.directory}";
  pid-file "${config.services.bind.directory}/named.pid";

  allow-recursion { trusted; };
  allow-transfer { none; };
  allow-update { none; };
  blackhole { badnetworks; };
  dnssec-validation auto;
};

logging {
  channel stdout {
    stderr;
    severity info;
    print-category yes;
    print-severity yes;
    print-time yes;
  };
  category security { stdout; };
  category dnssec   { stdout; };
  category default  { stdout; };
};

zone "holthome.net." {
  type master;
  file "${config.sops.secrets."networking/bind/zones/holthome.net".path}";
  journal "${config.services.bind.directory}/db.holthome.net.jnl";
  allow-transfer {
    key "externaldns";
  };
  update-policy {
    grant externaldns zonesub ANY;
    grant ddnsupdate zonesub ANY;
    grant * self * A;
  };
};

zone "10.in-addr.arpa." {
  type master;
  file "${config.sops.secrets."networking/bind/zones/10.in-addr.arpa".path}";
  journal "${config.services.bind.directory}/db.10.in-addr.arpa.jnl";
  update-policy {
    grant ddnsupdate zonesub ANY;
    grant * self * A;
  };
};
''
