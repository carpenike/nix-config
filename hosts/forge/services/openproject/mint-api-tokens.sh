#!/usr/bin/env bash
# Mint one OpenProject API token per bot user (API v3 cannot create tokens).
#
# Run on forge as root after bootstrap.py:
#   sudo bash hosts/forge/services/openproject/mint-api-tokens.sh [out-file]
#
# Tokens are written ONLY to the output file (mode 0600, default
# /root/openproject-bot-tokens.tsv) as "<login><TAB><token>". Move them into
# sops for the MCP server, then shred the file. Each run creates NEW tokens;
# revoke old ones under Administration -> Users -> <bot> -> Access tokens.
set -euo pipefail

out="${1:-/root/openproject-bot-tokens.tsv}"
logins="${BOT_LOGINS:-bot-executive-assistant bot-social-planner bot-finances bot-homelab-manager bot-grok}"
token_name="${TOKEN_NAME:-mcp-$(date +%Y%m%d)}"

umask 077
: >"$out"

podman exec -i \
  -e BOT_LOGINS="$logins" \
  -e TOKEN_NAME="$token_name" \
  openproject-web bundle exec rails runner - >>"$out" <<'RUBY'
ENV.fetch("BOT_LOGINS").split.each do |login|
  user = User.find_by!(login: login)
  token = Token::API.create!(user: user, token_name: ENV.fetch("TOKEN_NAME"))
  puts "#{login}\t#{token.plain_value}"
end
RUBY

echo "wrote $(wc -l <"$out") token(s) to $out (0600). Put them in sops, then: shred -u $out" >&2
