{ backend ? "http://127.0.0.1:3417" }:
''
  bind 127.0.0.1
  @metrics {
    method GET
    path /metrics
  }
  handle @metrics {
    reverse_proxy ${backend}
  }
  handle {
    respond 404
  }
''
