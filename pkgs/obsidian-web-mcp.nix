# jimprosser/obsidian-web-mcp — streamable-HTTP MCP server over a markdown vault.
#
# Pinned at 0.4.0, which is past the 0.2.0 floor for CVE-2026-54618
# (GHSA-hwhg-mrjc-8g43): earlier releases auto-approved /oauth/authorize and
# exchanged the approval for the static bearer token.
#
# Upstream ships no container image. This is a native Python application,
# not a mylib.mkContainerService unit.
{ lib
, python3
, fetchFromGitHub
}:

python3.pkgs.buildPythonApplication rec {
  pname = "obsidian-web-mcp";
  version = "0.4.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "jimprosser";
    repo = "obsidian-web-mcp";
    tag = "v${version}";
    hash = "sha256-VfQAtGpsxiKFAv7h93ZGZrpcmgjDVlo/SyNMs/CTUMk=";
  };

  build-system = [ python3.pkgs.hatchling ];

  dependencies = [
    python3.pkgs.mcp
    python3.pkgs."python-frontmatter"
    python3.pkgs."ruamel-yaml"
    python3.pkgs.pydantic
    python3.pkgs.watchdog
  ];

  # Upstream tests need pytest-asyncio and a fixture vault. The import check
  # is what the service unit actually executes (vault-mcp -> obsidian_vault_mcp).
  doCheck = false;

  pythonImportsCheck = [ "obsidian_vault_mcp" ];

  meta = {
    description = "Streamable-HTTP MCP server for an Obsidian vault";
    homepage = "https://github.com/jimprosser/obsidian-web-mcp";
    license = lib.licenses.mit;
    mainProgram = "vault-mcp";
    platforms = lib.platforms.linux;
  };
}
