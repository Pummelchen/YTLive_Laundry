#!/bin/zsh
# Build a full SSH key mesh ("family") between Macs: every machine can ssh to every
# other one with keys, no passwords.
#
#   ssh_mesh.sh USER1@host1 USER2@host2 USER3@host3 ...
#
# The machine you run this on must ALREADY be able to reach each listed host with a key
# (do the one-time  ssh-copy-id USER@host  for each first - that needs the password once).
# Then this script, for every host including this one:
#   1. makes sure an ed25519 key exists (generates one if not)
#   2. collects all public keys
#   3. appends every public key to every host's ~/.ssh/authorized_keys (idempotent)
#   4. verifies the full matrix: for each pair A,B runs  ssh A 'ssh B hostname'
# Tailscale MagicDNS names work as hosts (e.g. macbook-maria, macbook-ab).
set -u
[[ $# -ge 2 ]] || { print -u2 "usage: $0 USER@host USER@host [USER@host ...]"; exit 2; }
SSHO=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
ME="$(whoami)@$(hostname -s)"
HOSTS=("$@")

say() { print -r -- "==> $*"; }

# --- 1+2: ensure a key on every host, collect public keys ------------------------------
typeset -A PUB
ensure_key='mkdir -p ~/.ssh && chmod 700 ~/.ssh && [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C "$(whoami)@$(hostname -s)" -f ~/.ssh/id_ed25519; cat ~/.ssh/id_ed25519.pub'
# local
PUB[$ME]=$(zsh -c "$ensure_key")
say "local  $ME : ${PUB[$ME]##* }"
for h in "${HOSTS[@]}"; do
  k=$(ssh "${SSHO[@]}" "$h" "$ensure_key" 2>/dev/null)
  if [[ -z "$k" ]]; then
    print -u2 "ERROR: cannot reach $h with key auth. Run first:  ssh-copy-id $h   (asks for that Mac's password once)"
    exit 1
  fi
  PUB[$h]="$k"; say "remote $h : ${k##* }"
done

# --- 3: install every key on every host (idempotent) ------------------------------------
ALLKEYS=""; for k in "${(@v)PUB}"; do ALLKEYS+="$k"$'\n'; done
install_keys='mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
while IFS= read -r line; do [ -n "$line" ] && ! grep -qxF "$line" ~/.ssh/authorized_keys && echo "$line" >> ~/.ssh/authorized_keys; done
wc -l < ~/.ssh/authorized_keys'
n=$(print -r -- "$ALLKEYS" | zsh -c "$install_keys"); say "local  $ME : authorized_keys has $n keys"
for h in "${HOSTS[@]}"; do
  n=$(print -r -- "$ALLKEYS" | ssh "${SSHO[@]}" "$h" "$install_keys" 2>/dev/null); say "remote $h : authorized_keys has ${n:-?} keys"
done

# --- 4: verify the matrix -----------------------------------------------------------------
say "verifying every pair (A -> B)"
ALL=("$ME" "${HOSTS[@]}")
ok=0; bad=0
for a in "${ALL[@]}"; do
  for b in "${ALL[@]}"; do
    [[ "$a" == "$b" ]] && continue
    if [[ "$a" == "$ME" ]]; then
      r=$(ssh "${SSHO[@]}" "$b" 'hostname -s' 2>/dev/null)
    else
      r=$(ssh "${SSHO[@]}" "$a" "ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new $b 'hostname -s'" 2>/dev/null)
    fi
    if [[ -n "$r" ]]; then printf "  %-28s -> %-28s OK (%s)\n" "$a" "$b" "$r"; ok=$((ok+1))
    else                   printf "  %-28s -> %-28s FAILED\n" "$a" "$b"; bad=$((bad+1)); fi
  done
done
say "matrix: $ok links OK, $bad failed"
(( bad == 0 ))
