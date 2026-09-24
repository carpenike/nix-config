{ pkgs, configuration, nativeSource, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  database = configuration.modules.services.postgresql.databases.homelab_finance;
  owner = database.owner;
  reader = "atrium-money-reader";
  ddl = pkgs.writeText "money-reporting-schema.sql"
    (builtins.replaceStrings [ "{schema}" ] [ "household_finance" ]
      (builtins.readFile (nativeSource + "/src/homelab_mcp/finances_export/overview.sql")));
  initial = pkgs.writeText "money-reporting-old-schema.sql" ''
    CREATE ROLE "${owner}" NOLOGIN;
    CREATE ROLE "${reader}" LOGIN;
    CREATE DATABASE homelab_finance OWNER "${owner}";
    \connect homelab_finance
    CREATE SCHEMA household_finance AUTHORIZATION "${owner}";
    SET ROLE "${owner}";
    CREATE TABLE household_finance.money_overview (
      singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
      payload text NOT NULL CHECK(octet_length(payload) <= 16384)
    );
    INSERT INTO household_finance.money_overview VALUES (true, '{"fixture":"retained-overview"}');
    CREATE TABLE household_finance.unrelated_fixture (value integer);
    RESET ROLE;
    GRANT CONNECT ON DATABASE homelab_finance TO "${reader}";
    GRANT USAGE ON SCHEMA household_finance TO "${reader}";
    GRANT SELECT ON household_finance.money_overview TO "${reader}";
  '';
in
assert database.additionalRoles.${reader}.passwordFile == null;
assert database.additionalRoles.${reader}.grantRoles == [ ];
assert database.tablePermissions."household_finance.money_overview".${reader} == [ "SELECT" ];
hostPkgs.testers.runNixOSTest {
  name = "atrium-money-reporting-store";
  globalTimeout = 180;
  node.pkgs = lib.mkForce pkgs;
  nodes.machine = {
    virtualisation = { memorySize = 512; cores = 2; vlans = [ ]; };
    networking.useDHCP = false;
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      authentication = lib.mkForce configuration.services.postgresql.authentication;
      identMap = lib.mkForce configuration.services.postgresql.identMap;
      initialScript = initial;
    };
    users.groups.homelab-mcp = { };
    users.users.homelab-mcp = { isSystemUser = true; group = "homelab-mcp"; };
    environment.systemPackages = [ pkgs.postgresql_17 pkgs.util-linux ];
    system.stateVersion = "25.11";
  };
  testScript = ''
    import json
    import shlex

    machine.start()
    machine.wait_for_unit("postgresql")
    dsn = "${configuration.services.homelab-mcp.settings.HOMELAB_MCP_MONEY_PG_DSN}"
    reader = "runuser -u homelab-mcp -- psql -X -qAt -v ON_ERROR_STOP=1 " + shlex.quote(dsn)
    admin = "runuser -u postgres -- psql -X -qAt -v ON_ERROR_STOP=1 -d homelab_finance"

    def select(query):
        return machine.succeed(reader + " -c " + shlex.quote(query)).strip()

    def owner_sql(query):
        return machine.succeed(admin + " -c " + shlex.quote('SET ROLE "${owner}"; ' + query)).strip()

    groups = []
    assert select("SELECT current_user") == "${reader}"
    original = select("SELECT payload FROM household_finance.money_overview")
    assert "retained-overview" in original
    machine.fail("runuser -u nobody -- psql -X -qAt " + shlex.quote(dsn) + " -c 'SELECT 1'")
    machine.fail("psql -X -qAt " + shlex.quote(dsn) + " -c 'SELECT 1'")
    groups.append("actual-peer-map-permits-service-and-refuses-foreign-identities")

    machine.succeed(admin + " -c " + shlex.quote('SET ROLE "${owner}";') + " -f ${ddl}")
    assert select("SELECT payload FROM household_finance.money_overview") == original
    assert select("SELECT cashflow_payload IS NULL FROM household_finance.money_overview") == "t"
    owner_sql("""UPDATE household_finance.money_overview SET cashflow_payload='{"fixture":"cashflow"}'""")
    assert "cashflow" in select("SELECT cashflow_payload FROM household_finance.money_overview")
    groups.append("source-ddl-adds-report-column-without-new-role-or-grant")

    for query in (
        "UPDATE household_finance.money_overview SET cashflow_payload=NULL",
        "DELETE FROM household_finance.money_overview",
        "SELECT * FROM household_finance.unrelated_fixture",
    ):
        machine.fail(reader + " -c " + shlex.quote(query))
    assert "cashflow" in select("SELECT cashflow_payload FROM household_finance.money_overview")
    groups.append("same-reader-cannot-write-or-read-unrelated-tables")

    machine.succeed(admin + " -c " + shlex.quote('SET ROLE "${owner}";') + " -f ${ddl}")
    machine.succeed("systemctl restart postgresql")
    machine.wait_for_unit("postgresql")
    assert select("SELECT payload FROM household_finance.money_overview") == original
    assert "cashflow" in select("SELECT cashflow_payload FROM household_finance.money_overview")
    groups.append("repeated-provision-and-service-restart-preserve-overview-report-and-peer-access")
    print(json.dumps({
        "kind": "atrium.money-reporting-store",
        "groups": groups,
        "actual_postgresql": True,
        "production_operations": False,
        "scope": "Actual configured peer/read-role and source schema upgrade; native authorization is qualified separately.",
    }, sort_keys=True))
  '';
}
