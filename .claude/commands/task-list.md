# /task-list

Discover available Task commands directly from the Taskfile.

## Usage

```
/task-list [--all]
```

## Parameters

- `--all` (optional): Show verbose task descriptions and details

## Examples

```bash
# List available tasks
/task-list

# List with detailed descriptions
/task-list --all
```

## Implementation

### Default listing
```bash
task --list
```

### Verbose listing
```bash
task --list-all
```

## Available Tasks

Based on your current Taskfile structure:

### Nix Operations
- `nix:build-darwin` - Build Darwin configuration
- `nix:apply-darwin` - Apply Darwin configuration
- `nix:build-nixos` - Build NixOS configuration
- `nix:apply-nixos` - Apply NixOS configuration

### Secrets Management
- `sops:re-encrypt` - Re-encrypt all SOPS secrets

### Default
- `default` - Show task list (same as `task` with no arguments)

## Notes

- Tasks are organized by namespace (nix:, sops:)
- Use `task <taskname> --help` for specific task details
- Tasks automatically handle host-specific logic
- See individual task files in `.taskfiles/` for implementation details
