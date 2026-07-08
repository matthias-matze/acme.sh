#!/usr/bin/env sh

# ===== CONFIG =====
COMLAUDE_API="https://api.comlaude.com"

# acmetest compatibility
COMLAUDE_USERNAME="${COMLAUDE_USERNAME:-$TokenName1}"
COMLAUDE_PASSWORD="${COMLAUDE_PASSWORD:-$TokenName2}"
COMLAUDE_API_KEY="${COMLAUDE_API_KEY:-$TokenName3}"
COMLAUDE_GROUP_ID="${COMLAUDE_GROUP_ID:-$TokenName4}"
########## AUTH ##########

_comlaude_auth() {
  _debug "Checking cached ComLaude token"

  # essaie de charger le token en cache depuis account.conf
  if [ -z "$COMLAUDE_ACCESS_TOKEN" ]; then
    COMLAUDE_ACCESS_TOKEN="$(_readaccountconf_mutable COMLAUDE_ACCESS_TOKEN)"
    COMLAUDE_TOKEN_EXPIRY="$(_readaccountconf_mutable COMLAUDE_TOKEN_EXPIRY)"
  fi

  _now=$(_time)
  if [ -n "$COMLAUDE_ACCESS_TOKEN" ] && [ -n "$COMLAUDE_TOKEN_EXPIRY" ] && [ "$_now" -lt "$COMLAUDE_TOKEN_EXPIRY" ]; then
    _debug "Using cached ComLaude token (valid ${COMLAUDE_TOKEN_EXPIRY} > ${_now})"
    return 0
  fi

  _info "ComLaude auth..."
  body="{\"username\":\"$COMLAUDE_USERNAME\",\"password\":\"$COMLAUDE_PASSWORD\",\"api_key\":\"$COMLAUDE_API_KEY\"}"
  response="$(_post "$body" "https://api.comlaude.com/api_login" "" "POST" "application/json")"

  if ! _contains "$response" "access_token"; then
    _err "Auth failed: $response"
    return 1
  fi

  COMLAUDE_ACCESS_TOKEN=$(echo "$response" | _egrep_o '"access_token":"[^"]*"' | cut -d'"' -f4)
  # Ajuste selon la durée réelle de vie du token retournée par l'API (souvent "expires_in" en secondes)
  _expires_in=$(echo "$response" | _egrep_o '"expires_in":[0-9]*' | cut -d: -f2)
  [ -z "$_expires_in" ] && _expires_in=3000  # fallback si l'API ne donne pas cette info

  COMLAUDE_TOKEN_EXPIRY=$(( $(_time) + _expires_in - 60 ))  # marge de sécurité de 60s

  _saveaccountconf_mutable COMLAUDE_ACCESS_TOKEN "$COMLAUDE_ACCESS_TOKEN"
  _saveaccountconf_mutable COMLAUDE_TOKEN_EXPIRY "$COMLAUDE_TOKEN_EXPIRY"

  return 0
}

########## DOMAIN RESOLUTION ##########

_comlaude_get_root() {
  COMLAUDE_GROUP_ID="${COMLAUDE_GROUP_ID:-$(_readaccountconf_mutable COMLAUDE_GROUP_ID)}"
  if [ -z "$COMLAUDE_GROUP_ID" ]; then
    _err "Missing COMLAUDE_GROUP_ID"
    return 1
  fi

  domain="$1"
  domain="${domain#_acme-challenge.}"
  case "$domain" in
  \*.*) domain="${domain#*.}" ;;
  esac

  _debug "Normalized domain: $domain"

  i=1
  while true; do
    d=$(printf "%s" "$domain" | cut -d . -f $i-)
    [ -z "$d" ] && {
      _debug "No matching domain found for $domain"
      return 1
    }

    _debug "Checking domain: $d"

    # retry loop pour absorber les 404 transitoires de l'API ComLaude
    retry=0
    DOMAIN_ID=""
    ZONE_ID=""
    while [ "$retry" -lt 3 ]; do
      export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
      response="$(_get "$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/domains?filter[name]=$d&fields=id,name,active_zone")"
      _H1=""

      _debug "RAW response for $d (try $((retry + 1))): $response"

      if echo "$response" | grep -q '"data":\[\]'; then
        retry=$((retry + 1))
        [ "$retry" -lt 3 ] && sleep 2
        continue
      fi

      DOMAIN_ID="$(echo "$response" | sed -n 's/.*"data":[^[]*\[\([^]]*\)\].*/\1/p' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
      ZONE_ID="$(echo "$response" | sed -n 's/.*"active_zone":[^{]*{[^}]*"id":"\([^"]*\)".*/\1/p' | head -n1)"
      break
    done

    _debug "DOMAIN_ID=$DOMAIN_ID"
    _debug "ZONE_ID=$ZONE_ID"

    if [ -n "$DOMAIN_ID" ] && [ -n "$ZONE_ID" ]; then
      _domain="$d"
      _domain_id="$DOMAIN_ID"
      _zone_id="$ZONE_ID"
      return 0
    fi

    i=$((i + 1))
  done
}

########## ADD TXT ##########

dns_comlaude_add() {
  fulldomain="$1"
  txtvalue="$2"

  COMLAUDE_USERNAME="${COMLAUDE_USERNAME:-$(_readaccountconf_mutable COMLAUDE_USERNAME)}"
  COMLAUDE_PASSWORD="${COMLAUDE_PASSWORD:-$(_readaccountconf_mutable COMLAUDE_PASSWORD)}"
  COMLAUDE_API_KEY="${COMLAUDE_API_KEY:-$(_readaccountconf_mutable COMLAUDE_API_KEY)}"
  COMLAUDE_GROUP_ID="${COMLAUDE_GROUP_ID:-$(_readaccountconf_mutable COMLAUDE_GROUP_ID)}"

  if [ -z "$COMLAUDE_USERNAME" ] || [ -z "$COMLAUDE_PASSWORD" ] || [ -z "$COMLAUDE_API_KEY" ]; then
    _err "You didn't specify ComLaude credentials (COMLAUDE_USERNAME, COMLAUDE_PASSWORD, COMLAUDE_API_KEY)."
    return 1
  fi

  # Sauvegarde uniquement APRÈS validation, jamais avant
  _saveaccountconf_mutable COMLAUDE_USERNAME "$COMLAUDE_USERNAME"
  _saveaccountconf_mutable COMLAUDE_PASSWORD "$COMLAUDE_PASSWORD"
  _saveaccountconf_mutable COMLAUDE_API_KEY "$COMLAUDE_API_KEY"
  _saveaccountconf_mutable COMLAUDE_GROUP_ID "$COMLAUDE_GROUP_ID"

  _info "Adding TXT: $fulldomain"
  # _debug "DEBUG COMLAUDE_USERNAME set=[$([ -n "$COMLAUDE_USERNAME" ] && echo yes || echo no)] len=${#COMLAUDE_USERNAME}"
  # _debug "DEBUG COMLAUDE_PASSWORD set=[$([ -n "$COMLAUDE_PASSWORD" ] && echo yes || echo no)] len=${#COMLAUDE_PASSWORD}"
  # _debug "DEBUG COMLAUDE_API_KEY set=[$([ -n "$COMLAUDE_API_KEY" ] && echo yes || echo no)] len=${#COMLAUDE_API_KEY}"
  # _debug "DEBUG COMLAUDE_GROUP_ID set=[$([ -n "$COMLAUDE_GROUP_ID" ] && echo yes || echo no)] len=${#COMLAUDE_GROUP_ID}"

  _comlaude_auth || return 1
  _comlaude_get_root "$fulldomain" || return 1

  subdomain="${fulldomain%."$_domain"}"
  [ -z "$subdomain" ] && subdomain="@"

  _debug "Root: $_domain"
  _debug "Sub: $subdomain"

  data="{\"type\":\"TXT\",\"name\":\"$fulldomain\",\"value\":\"$txtvalue\",\"ttl\":60}"

  export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
  export _H2="Content-Type: application/json"

  response="$(_post "$data" "$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/zones/$_zone_id/records")"

  _H1=""
  _H2=""
  if ! echo "$response" | grep -q '"id"'; then
    _err "Failed to create TXT"
    _debug "$response"
    return 1
  fi

  return 0
}

########## REMOVE TXT ##########

dns_comlaude_rm() {
  fulldomain="$1"
  txtvalue="$2"

  COMLAUDE_USERNAME="${COMLAUDE_USERNAME:-$(_readaccountconf_mutable COMLAUDE_USERNAME)}"
  COMLAUDE_PASSWORD="${COMLAUDE_PASSWORD:-$(_readaccountconf_mutable COMLAUDE_PASSWORD)}"
  COMLAUDE_API_KEY="${COMLAUDE_API_KEY:-$(_readaccountconf_mutable COMLAUDE_API_KEY)}"
  COMLAUDE_GROUP_ID="${COMLAUDE_GROUP_ID:-$(_readaccountconf_mutable COMLAUDE_GROUP_ID)}"

  _info "Removing TXT: $fulldomain"

  _comlaude_auth || return 1
  _comlaude_get_root "$fulldomain" || return 1

  deleted_count=0
  page=1

  while true; do
    export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
    response="$(_get "$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/zones/$_zone_id/records?page=$page")"
    _H1=""

    _debug "Fetching page $page"

    records="$(echo "$response" | _egrep_o '\{[^}]*\}')"

    for record in $records; do
      type="$(echo "$record" | _egrep_o '"type":"[^"]*"' | cut -d':' -f2 | tr -d '"')"
      name="$(echo "$record" | _egrep_o '"name":"[^"]*"' | cut -d':' -f2 | tr -d '"')"
      value="$(echo "$record" | _egrep_o '"value":"[^"]*"' | cut -d':' -f2 | tr -d '"')"
      record_id="$(echo "$record" | _egrep_o '"id":"[^"]*"' | cut -d':' -f2 | tr -d '"')"

      [ "$type" != "TXT" ] && continue
      [ "$name" != "$fulldomain" ] && continue
      [ "$value" != "$txtvalue" ] && continue
      [ -z "$record_id" ] && continue

      _debug "Deleting record $record_id"
      export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
      url="$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/zones/$_zone_id/records/$record_id"
      del_resp="$(_post "" "$url" "" "DELETE")"
      _H1=""

      if echo "$del_resp" | grep -q '"error"'; then
        _err "Delete failed for $record_id"
        _debug "$del_resp"
        return 1
      fi

      deleted_count=$((deleted_count + 1))
    done

    # vérifie s'il y a une page suivante
    has_next="$(echo "$response" | _egrep_o '"next":"[^"]*"')"
    [ -z "$has_next" ] && break
    page=$((page + 1))
  done

  if [ "$deleted_count" -eq 0 ]; then
    _err "No matching TXT record found to delete for $fulldomain / $txtvalue"
    return 1
  fi

  _info "Deleted $deleted_count record(s)"
  return 0
}
