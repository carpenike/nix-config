#!/usr/bin/env bash
set -euo pipefail

configure_script=${1:?Usage: music-assistant-config.sh /nix/store/...-configure-music-assistant}
base_url=http://10.20.0.30:8095
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
settings_file="$work_dir/settings.json"

"$configure_script" "$settings_file" "$base_url" 8095
test ! -e "$settings_file"

jq -n '{
  core: {webserver: {values: {base_url: "https://music.holthome.net", bind_port: 443, other: "preserved"}}},
  users: [{token: "synthetic-ha-token"}],
  providers: {
    legacy: {domain: "spotify", values: {refresh_token: "synthetic-legacy-token"}},
    empty_client: {domain: "spotify", values: {client_id: "", refresh_token: "synthetic-empty-client-token", refresh_token_global: ""}},
    custom: {domain: "spotify", values: {client_id: "custom-client", refresh_token: "synthetic-custom-token"}},
    migrated: {domain: "spotify", values: {refresh_token: "synthetic-old-token", refresh_token_global: "synthetic-current-token"}},
    sonos: {domain: "sonos", values: {enabled: true}},
    no_token: {domain: "spotify", values: {}}
  }
}' > "$settings_file"
chmod 600 "$settings_file"

"$configure_script" "$settings_file" "$base_url" 8095
jq -e --arg base_url "$base_url" '
  .core.webserver.values == {base_url: $base_url, bind_port: 8095, other: "preserved"}
  and .users == [{token: "synthetic-ha-token"}]
  and .providers == {
    legacy: {domain: "spotify", values: {refresh_token_global: "synthetic-legacy-token"}},
    empty_client: {domain: "spotify", values: {client_id: "", refresh_token_global: "synthetic-empty-client-token"}},
    custom: {domain: "spotify", values: {client_id: "custom-client", refresh_token: "synthetic-custom-token"}},
    migrated: {domain: "spotify", values: {refresh_token: "synthetic-old-token", refresh_token_global: "synthetic-current-token"}},
    sonos: {domain: "sonos", values: {enabled: true}},
    no_token: {domain: "spotify", values: {}}
  }
' "$settings_file" > /dev/null
test "$(stat -c %a "$settings_file")" = 600

cp "$settings_file" "$work_dir/expected.json"
original_inode=$(stat -c %i "$settings_file")
"$configure_script" "$settings_file" "$base_url" 8095
"$configure_script" "$settings_file" "$base_url" 8095
cmp "$settings_file" "$work_dir/expected.json"
test "$(stat -c %i "$settings_file")" = "$original_inode"

jq '.core.webserver.values.base_url = "https://music.holthome.net"' \
  "$settings_file" > "$work_dir/drift.json"
mv "$work_dir/drift.json" "$settings_file"
"$configure_script" "$settings_file" "$base_url" 8095
cmp "$settings_file" "$work_dir/expected.json"

jq '.core.webserver.values.bind_port = 443' \
  "$settings_file" > "$work_dir/drift.json"
mv "$work_dir/drift.json" "$settings_file"
"$configure_script" "$settings_file" "$base_url" 8095
cmp "$settings_file" "$work_dir/expected.json"

printf '%s\n' 'Music Assistant managed configuration regressions passed.'
