#!/bin/zsh
# Richtet den eigenen SMTP Server fuer die Supabase Auth Mails ein (Projekt tpos-pilot).
# Das Passwort wird im Terminal unsichtbar abgefragt. Es steht nie in einem Argument, einer Datei,
# dem Chat oder einem Log und wird nach dem Aufruf nicht wieder ausgegeben (nur "gesetzt: ja").
#
#   scripts/supabase-smtp-setup.sh <host> <port> <benutzer> <absender@adresse> "<Absender Name>" [mails_pro_stunde]
#   scripts/supabase-smtp-setup.sh status
#
# Beispiel: scripts/supabase-smtp-setup.sh w01234567.kasserver.com 587 m01234567 noreply@c-klan.de "TPOS" 30
# Der Token der Supabase CLI kommt aus dem Schluesselbund und wird nie ausgegeben.
set -euo pipefail
REF=sxpfetwrqqwqijapgkcd
API="https://api.supabase.com/v1/projects/$REF/config/auth"

T=$(security find-generic-password -s "Supabase CLI" -w)
case "$T" in go-keyring-base64:*) T=$(printf %s "${T#go-keyring-base64:}" | base64 -d);; esac

status() {
  curl -sf -H "Authorization: Bearer $T" "$API" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("smtp_host         :", d.get("smtp_host") or "(keiner, Supabase Standard)")
print("smtp_port         :", d.get("smtp_port"))
print("smtp_user         :", d.get("smtp_user"))
print("smtp_admin_email  :", d.get("smtp_admin_email"))
print("smtp_sender_name  :", d.get("smtp_sender_name"))
print("smtp_pass gesetzt :", "ja" if d.get("smtp_pass") else "nein")
print("rate_limit_email_sent:", d.get("rate_limit_email_sent"))
print("smtp_max_frequency:", d.get("smtp_max_frequency"))'
}

if [[ "${1:-}" == "status" ]]; then status; exit 0; fi
if [[ $# -lt 5 ]]; then
  echo "Aufruf: $0 <host> <port> <benutzer> <absender@adresse> \"<Absender Name>\" [mails_pro_stunde]" >&2
  echo "        $0 status" >&2
  exit 2
fi

HOST="$1"; PORT="$2"; USER_="$3"; FROM="$4"; NAME="$5"; RATE="${6:-30}"
if [[ ! -t 0 ]]; then echo "Das Passwort wird im Terminal abgefragt, bitte direkt im Terminal ausfuehren." >&2; exit 2; fi
printf "SMTP Passwort fuer %s (Eingabe unsichtbar): " "$USER_"
read -rs SMTP_PASS; echo
[[ -n "$SMTP_PASS" ]] || { echo "Kein Passwort eingegeben, Abbruch." >&2; exit 1; }

BODY=$(SMTP_PASS="$SMTP_PASS" HOST="$HOST" PORT="$PORT" USER_="$USER_" FROM="$FROM" NAME="$NAME" RATE="$RATE" python3 -c '
import os, json
print(json.dumps({
  "smtp_host": os.environ["HOST"],
  "smtp_port": os.environ["PORT"],
  "smtp_user": os.environ["USER_"],
  "smtp_pass": os.environ["SMTP_PASS"],
  "smtp_admin_email": os.environ["FROM"],
  "smtp_sender_name": os.environ["NAME"],
  "rate_limit_email_sent": int(os.environ["RATE"]),
}))')
unset SMTP_PASS
curl -sf -X PATCH -H "Authorization: Bearer $T" -H "Content-Type: application/json" -d "$BODY" "$API" > /dev/null
unset BODY
echo "Gespeichert. Stand laut Supabase:"
status
