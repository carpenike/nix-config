# Shared type definitions for service modules
#
# This file is a compatibility wrapper that delegates to lib/types/default.nix
# where the actual type definitions are split into focused files.
#
# See lib/types/default.nix for the full list of available types.
#
# MIGRATION NOTE (2025-12-16):
# Types were split from this monolithic file into lib/types/*.nix for maintainability.
# This wrapper ensures existing imports continue to work.

{ lib }:
import ./types { inherit lib; }
