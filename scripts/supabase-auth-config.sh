#!/bin/zsh
# Liest oder setzt ausgewaehlte Felder der Supabase-Auth-Konfiguration (Management API).
# Token kommt aus dem Schluesselbund der Supabase CLI und wird nie ausgegeben.
#
#   scripts/supabase-auth-config.sh get                 -> nur Hook-Felder und jwt_exp
#   scripts/supabase-auth-config.sh patch '<json>'      -> PATCH, danach wieder get
set -euo pipefail
REF=sxpfetwrqqwqijapgkcd
API="https://api.supabase.com/v1/projects/$REF/config/auth"

T=$(security find-generic-password -s "Supabase CLI" -w)
case "$T" in go-keyring-base64:*) T=$(printf %s "${T#go-keyring-base64:}" | base64 -d);; esac

show() {
  curl -sf -H "Authorization: Bearer $T" "$API" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(json.dumps({k: v for k, v in d.items() if k.startswith("hook_custom_access_token") or k == "jwt_exp"}, indent=2))'
}

case "${1:-get}" in
  get) show ;;
  patch)
    curl -sf -X PATCH -H "Authorization: Bearer $T" -H "Content-Type: application/json" -d "$2" "$API" > /dev/null
    show ;;
  *) echo "Aufruf: $0 get|patch '<json>'" >&2; exit 2 ;;
esac
