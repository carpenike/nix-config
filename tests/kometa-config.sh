#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
config_file=$(mktemp)
trap 'rm -f "$config_file"' EXIT

nix eval --raw .#nixosConfigurations.forge.config.system.build.kometaConfig.text > "$config_file"
yq eval --exit-status '
  (.libraries.Movies.collection_files[0].template_variables.use_separator == false) and
  ((.libraries.Movies.collection_files[0].template_variables.use_separator | tag) == "!!bool") and
  (.libraries.Movies.operations.mass_genre_update == "tmdb") and
  (.libraries["TV Shows"].overlay_files[2].default == "status") and
  (.settings.sync_mode == "append") and
  ((.settings.run_order | tag) == "!!seq") and
  ((.plex.token | tag) == "!!str") and
  (.plex.token == "<<plextoken>>") and
  (.plex.url == "<<plexurl>>") and
  (.tmdb.apikey == "<<tmdbapikey>>") and
  (.trakt.client_id == "<<traktclientid>>") and
  (.trakt.client_secret == "<<traktclientsecret>>")
' "$config_file" > /dev/null

nix eval --impure --raw --expr '
  let
    flake = builtins.getFlake (toString ./.);
    fixture = flake.nixosConfigurations.forge.extendModules {
      modules = [{
        modules.services.kometa = {
          libraries."Regression: # library" = {
            collectionFiles = [{
              type = "file";
              path = "/config/collections: # test.yml";
              templateVariables = { enabled = false; count = 7; label = "value: # quoted"; };
            }];
            metadataFiles = [{ type = "url"; url = "https://example.invalid/meta.yml"; }];
            operations.splitDuplicates = true;
          };
          playlistFiles = [{ type = "repo"; name = "playlists/test"; }];
          settings.assetDirectory = "/config/assets: # directory";
        };
      }];
    };
  in fixture.config.system.build.kometaConfig.text
' > "$config_file"
yq eval --exit-status '
  (.libraries["Regression: # library"].collection_files[0].file == "/config/collections: # test.yml") and
  (.libraries["Regression: # library"].collection_files[0].template_variables.enabled == false) and
  (.libraries["Regression: # library"].collection_files[0].template_variables.count == 7) and
  (.libraries["Regression: # library"].collection_files[0].template_variables.label == "value: # quoted") and
  (.libraries["Regression: # library"].metadata_files[0].url == "https://example.invalid/meta.yml") and
  (.libraries["Regression: # library"].operations.split_duplicates == true) and
  (.playlist_files[0].repo == "playlists/test") and
  (.settings.asset_directory == "/config/assets: # directory")
' "$config_file" > /dev/null

printf '%s\n' 'Kometa generated configuration regressions passed.'
