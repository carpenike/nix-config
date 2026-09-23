# rymac

## YubiKey unlock

`yku` is a Bash alias and Fish abbreviation for the Home Manager
`yubikey-unlock` helper in `home/ryan/hosts/rymac.nix`. It exercises GPG signing,
SSH authentication, and SOPS decryption once each to unlock the card for those
operations.

Card discovery retries transient errors up to three times. If GnuPG still
reports `OpenPGP card not available: Operation not supported by device`, the
helper restarts only `scdaemon` and retries discovery. On macOS this error can
mask a PC/SC sharing violation: another smartcard application, or a stale
connection, is holding the reader.

If normal recovery fails, close other smartcard applications and run:

```bash
yku --recover
```

This explicitly permits one recovery pass over your user-owned macOS PC/SC
helpers. It checks each process's owner and full executable path again before
sending SIGTERM to that PID. Root-owned services, other users' processes, and
unrelated executables are not stopped. Do not use `sudo`.

**Recovery disconnects other smartcard sessions running as your user.** It only
runs for the persistent card-selection error, not when the card is healthy,
absent, or a signing/PIN operation fails. After recovery, discovery gets up to
three more attempts; if it still fails, unplug and reinsert the YubiKey.

The helper never restarts `gpg-agent`, changes keys or PIN settings, enables
`pcsc-shared`, or automatically retries signing, SSH authentication, or
decryption. Restarting card services may still require fresh PIN/touch
authorization. Enter a PIN only through the normal pinentry dialog.

### Updating and checking the helper

```bash
# Mocked regressions; no card access, process signals, or PIN prompts.
bash tests/yubikey-unlock.sh

# Standard validation and deployment.
task nix:validate
task nix:apply-darwin host=rymac
```

Both shell shortcuts resolve through the active Home Manager profile, so they
pick up the rebuilt helper after deployment without redefining the alias.
