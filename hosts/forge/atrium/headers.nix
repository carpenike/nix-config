''
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
''
