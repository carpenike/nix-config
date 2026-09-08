{ fixture }:
let
  f = fixture;
in
''
  {
    admin off
    auto_https off
    grace_period 5s
    servers {
      strict_sni_host on
      protocols h1 h2
    }
  }

  (isolated_tls) {
    bind ${f.frontAddress}
    tls /run/credentials/caddy.service/front-cert /run/credentials/caddy.service/front-key {
      protocols tls1.2 tls1.3
    }
  }

  (native_headers) {
    header_up -Forwarded
    header_up -X-SSL-Client-Verify
    header_up -X-Forwarded-Client-Cert
    header_up -X-Client-Cert
    header_up -X-Forwarded-User
    header_up -X-Remote-User
    header_up -X-Auth-Request-User
    header_up -X-Principal
    header_up -X-Admin
    header_up X-Forwarded-For {http.request.remote.host}
    header_up X-Forwarded-Host {http.request.hostport}
    header_up X-Forwarded-Proto https
    header_up Host {http.request.hostport}
  }

  ${f.endpoints.resolver} {
    import isolated_tls
    @registration path /v1/devices/register /v1/devices/register/*
    respond @registration 404
    @native_policy path /v1/native-policy /v1/native-policy/*
    respond @native_policy 404
    reverse_proxy 127.0.0.1:18765 {
      import native_headers
      transport http {
        network_proxy none
        compression off
      }
    }
  }

  ${f.endpoints.native} {
    import isolated_tls
    @private_issue path /cc/issue /cc/issue/*
    respond @private_issue 404
    @native_policy path /v1/native-policy /v1/native-policy/*
    respond @native_policy 404
    reverse_proxy https://127.0.0.1:${toString f.port} {
      import native_headers
      header_up Host 127.0.0.1:${toString f.port}
      transport http {
        tls_server_name ${f.names.native}
        tls_trust_pool file /run/credentials/caddy.service/native-ca
        network_proxy none
        compression off
        versions 1.1
      }
    }
  }

  ${f.endpoints.whiskey} {
    import isolated_tls
    @private_metrics path /metrics /metrics/*
    respond @private_metrics 404
    reverse_proxy 127.0.0.1:13417 {
      import native_headers
      transport http {
        network_proxy none
        compression off
      }
    }
  }

  ${f.endpoints.identity} {
    import isolated_tls
    reverse_proxy 127.0.0.4:19100 {
      import native_headers
      transport http {
        network_proxy none
        compression off
      }
    }
  }

  ${f.endpoints.models} {
    import isolated_tls
    respond "Isolated model plane unavailable: protected publication interface pending." 503
  }
''
