#!/usr/bin/env sh
# Blocks committing env files, keys, Aptos CLI profiles and Aptos private keys in file contents.
# Usage: guard-env.sh <file>...   (lefthook passes staged files)
status=0
key_pattern='ed25519-priv-0x[0-9a-fA-F]{64}|(private_key|PRIVATE_KEY)[[:space:]]*[:=][[:space:]]*["'"'"']?0x[0-9a-fA-F]{64}'
for f in "$@"; do
  base=$(basename "$f")
  case "$f" in
    .aptos/* | */.aptos/*) blocked=1 ;;
    *) case "$base" in
         .env.example | .env.sample | .env.template) blocked=0 ;;
         .env | .env.* | *.pem | *.key | *.p12 | id_rsa* | id_ed25519*) blocked=1 ;;
         *) blocked=0 ;;
       esac ;;
  esac
  if [ "$blocked" = 1 ]; then
    echo "guard-env: refusing to commit secret-bearing file: $f" >&2
    status=1
  elif [ -f "$f" ] && grep -qE "$key_pattern" -- "$f" 2>/dev/null; then
    echo "guard-env: Aptos private key found in: $f" >&2
    status=1
  fi
done
[ "$status" = 0 ] || echo "guard-env: unstage with 'git restore --staged <file>'; commit an .env.example instead." >&2
exit $status
