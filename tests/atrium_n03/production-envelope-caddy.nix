{ fixture }:
let
  f = fixture;
in
assert f.qualification.kind == "atrium.n02-production-envelope";
(import ./caddy.nix { inherit fixture; }) + ''
  ${f.endpoints.providerPersonal} {
    import isolated_tls
    reverse_proxy ${f.qualification.provider_upstreams."personal:ryan"} {
      transport http {
        network_proxy none
        compression off
      }
    }
  }
  ${f.endpoints.providerFamily} {
    import isolated_tls
    reverse_proxy ${f.qualification.provider_upstreams."family:holt"} {
      transport http {
        network_proxy none
        compression off
      }
    }
  }
''
