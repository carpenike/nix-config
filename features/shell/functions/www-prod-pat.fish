# Load the WWW prod PAT from macOS Keychain into the current shell.
# One-time setup: security add-generic-password -a "$USER" -s www-prod-pat -w
# Revoke at https://whiskeywhiskeywhiskey.org/#/me/tokens when done.
set -l pat (security find-generic-password -a "$USER" -s www-prod-pat -w 2>/dev/null)
if test -z "$pat"
    echo "No PAT stored. Run: security add-generic-password -a \$USER -s www-prod-pat -w" >&2
    return 1
end
set -gx WWW_PROD_PAT $pat
echo "WWW_PROD_PAT loaded — revoke at https://whiskeywhiskeywhiskey.org/#/me/tokens when done."
