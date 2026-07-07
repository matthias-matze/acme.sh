#!/usr/bin/env sh

# ===== CONFIG =====
COMLAUDE_API="https://api.comlaude.com"

########## AUTH ##########

_comlaude_auth() {
  if [ -z "$COMLAUDE_USERNAME" ] || [ -z "$COMLAUDE_PASSWORD" ] || [ -z "$COMLAUDE_API_KEY" ]; then
    _err "Missing COMLAUDE credentials"
    return 1
  fi

  export _H1="Content-Type: application/json"

  _info "ComLaude auth..."

  data="{\"username\":\"$COMLAUDE_USERNAME\",\"password\":\"$COMLAUDE_PASSWORD\",\"api_key\":\"$COMLAUDE_API_KEY\"}"

  response="$(_post "$data" "$COMLAUDE_API/api_login" "" "POST")"

  COMLAUDE_ACCESS_TOKEN="$(echo "$response" | _egrep_o '"access_token":"[^"]*"' | cut -d':' -f2 | tr -d '"')"

  if [ -z "$COMLAUDE_ACCESS_TOKEN" ]; then
    _err "Auth failed"
    _debug "$response"
    return 1
  fi

  export COMLAUDE_ACCESS_TOKEN
  _H1=""
}

########## DOMAIN RESOLUTION ##########

_comlaude_get_root() {
  _readaccountconf_mutable COMLAUDE_GROUP_ID

  COMLAUDE_GROUP_ID="${COMLAUDE_GROUP_ID:-$(_readaccountconf_mutable COMLAUDE_GROUP_ID)}"

  if [ -z "$COMLAUDE_GROUP_ID" ]; then
    _err "Missing COMLAUDE_GROUP_ID"
    return 1
  fi

  domain="$1"

  # strip wildcard
  domain="${domain#*.}"

  # strip _acme-challenge
  domain="${domain#_acme-challenge.}"

  _debug "Normalized domain: $domain"

  i=1

  while true; do
    d=$(printf "%s" "$domain" | cut -d . -f $i-)
    [ -z "$d" ] && {
      _debug "No matching domain found for $domain"
      return 1
    }

    _debug "Checking domain: $d"

    export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
    response="$(_get "$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/domains?filter[name]=$d&fields=id,name,active_zone")"
    _H1=""

    if echo "$response" | grep -q '"data":\[\]'; then
      _debug "Domain not found: $d"
      i=$((i + 1))
      continue
    fi

    DOMAIN_ID="$(echo "$response" | sed -n 's/.*"data":[^[]*\[\([^]]*\)\].*/\1/p' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    ZONE_ID="$(echo "$response" | sed -n 's/.*"active_zone":[^{]*{[^}]*"id":"\([^"]*\)".*/\1/p' | head -n1)"
    _debug "DOMAIN_ID=$DOMAIN_ID"
    _debug "ZONE_ID=$ZONE_ID"

    if [ -z "$DOMAIN_ID" ]; then
      _debug "Response was: $response"
      _debug "DOMAIN_ID not found"
    fi

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
  
  # sauver dès qu'on les a (important pour acmetest)
  [ -n "$COMLAUDE_USERNAME" ] && _saveaccountconf_mutable COMLAUDE_USERNAME "$COMLAUDE_USERNAME"
  [ -n "$COMLAUDE_PASSWORD" ] && _saveaccountconf_mutable COMLAUDE_PASSWORD "$COMLAUDE_PASSWORD"
  [ -n "$COMLAUDE_API_KEY" ] && _saveaccountconf_mutable COMLAUDE_API_KEY "$COMLAUDE_API_KEY"
  [ -n "$COMLAUDE_GROUP_ID" ] && _saveaccountconf_mutable COMLAUDE_GROUP_ID "$COMLAUDE_GROUP_ID"

  _readaccountconf_mutable COMLAUDE_USERNAME
  _readaccountconf_mutable COMLAUDE_PASSWORD
  _readaccountconf_mutable COMLAUDE_API_KEY
  _readaccountconf_mutable COMLAUDE_GROUP_ID

  _info "Adding TXT: $fulldomain"

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

  _readaccountconf_mutable COMLAUDE_USERNAME
  _readaccountconf_mutable COMLAUDE_PASSWORD
  _readaccountconf_mutable COMLAUDE_API_KEY
  _readaccountconf_mutable COMLAUDE_GROUP_ID

  _info "Removing TXT: $fulldomain"

  _comlaude_auth || return 1
  _comlaude_get_root "$fulldomain" || return 1

  export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
  response="$(_get "$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/zones/$_zone_id/records")"
  _H1=""

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

    _debug "Deleted: $record_id"

  done

  return 0
}
