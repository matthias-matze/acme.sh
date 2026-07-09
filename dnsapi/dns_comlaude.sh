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

  # Try to get token from account.conf
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
  #Prevent api timeout
  sleep 3

  COMLAUDE_ACCESS_TOKEN=$(echo "$response" | _egrep_o '"access_token":"[^"]*"' | cut -d'"' -f4)
  # store expiracy from api reply l'API (souvent "expires_in" en secondes)
  _expires_in=$(echo "$response" | _egrep_o '"expires_in":[0-9]*' | cut -d: -f2)
  [ -z "$_expires_in" ] && _expires_in=3000  # fallback if no info

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
    d=$(printf "%s" "$domain" | cut -d . -f "$i-")
    [ -z "$d" ] && {
      _debug "No matching domain found for $domain"
      return 1
    }

    # don't test unnecessary levels
    # registered domain : TLD only (no dot after cut).
    case "$d" in
    *.*) : ;;
    *)
      _debug "Skipping bare TLD candidate: $d"
      i=$((i + 1))
      continue
      ;;
    esac

    _debug "Checking domain: $d"

    retry=0
    max_retry=3           # to avoid network errors
    DOMAIN_ID=""
    ZONE_ID=""

    while [ "$retry" -lt "$max_retry" ]; do
      export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
      _debug "Full URL: $COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/domains?filter[name]=$d&fields=id,name,active_zone"
      response="$(_get "$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/domains?filter[name]=$d&fields=id,name,active_zone")"
      _H1=""

      _debug "RAW response for $d (try $((retry + 1))): $response"

      # If empty -> true network issue, we retry
      if [ -z "$response" ]; then
        retry=$((retry + 1))
        [ "$retry" -lt "$max_retry" ] && sleep 2
        continue
      fi

      # 404 -> domain not found in that level. no retry : continue
      if echo "$response" | grep -q '"status_code":404'; then
        _debug "404 for $d, moving to next level (not retrying)"
        break
      fi

      # Domain missing (200 reply, data empty) -> continue
      if echo "$response" | grep -q '"data":\[\]'; then
        _debug "Empty data for $d, moving to next level"
        break
      fi

      # Extraction via _egrep_o
      DOMAIN_ID="$(echo "$response" | _egrep_o '"id":"[^"]*"' | head -n1 | cut -d':' -f2 | tr -d '"')"
      ZONE_ID="$(echo "$response" | _egrep_o '"active_zone":\{"id":"[^"]*"' | _egrep_o '"id":"[^"]*"$' | cut -d':' -f2 | tr -d '"')"

      if [ -n "$DOMAIN_ID" ] && [ -n "$ZONE_ID" ]; then
        break
      fi

      # 200 reply but malformed data /  noid -> retry transport
      retry=$((retry + 1))
      [ "$retry" -lt "$max_retry" ] && sleep 2
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

  if [ -z "$COMLAUDE_USERNAME" ] || [ -z "$COMLAUDE_PASSWORD" ] || [ -z "$COMLAUDE_API_KEY" ]; then
    _err "You didn't specify ComLaude credentials (COMLAUDE_USERNAME, COMLAUDE_PASSWORD, COMLAUDE_API_KEY)."
    return 1
  fi

  # Backup variable after validation
  _saveaccountconf_mutable COMLAUDE_USERNAME "$COMLAUDE_USERNAME"
  _saveaccountconf_mutable COMLAUDE_PASSWORD "$COMLAUDE_PASSWORD"
  _saveaccountconf_mutable COMLAUDE_API_KEY "$COMLAUDE_API_KEY"
  _saveaccountconf_mutable COMLAUDE_GROUP_ID "$COMLAUDE_GROUP_ID"

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

  _info "Removing TXT: $fulldomain"

  _comlaude_auth || return 1
  _comlaude_get_root "$fulldomain" || return 1

  export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
  _encoded_name="$(printf '%s' "$fulldomain" | _url_encode)"
  _encoded_value="$(printf '%s' "$txtvalue" | _url_encode)"
  url="$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/zones/$_zone_id/records?filter[type]=TXT&filter[name]=$_encoded_name&filter[value]=$_encoded_value"
  response="$(_get "$url")"
  _H1=""

  _debug "Filtered records response: $response"

  # first "id" top-level of reply (record itself,
  # always on first position of each data[] object)
  record_id="$(echo "$response" | _egrep_o '"data":\[\{"id":"[^"]*"' | _egrep_o '"[^"]*"$' | tr -d '"')"

  if [ -z "$record_id" ]; then
    _err "No matching TXT record found to delete for $fulldomain / $txtvalue"
    return 1
  fi

  _debug "Deleting record $record_id"

  export _H1="Authorization: Bearer $COMLAUDE_ACCESS_TOKEN"
  del_url="$COMLAUDE_API/groups/$COMLAUDE_GROUP_ID/zones/$_zone_id/records/$record_id"
  del_resp="$(_post "" "$del_url" "" "DELETE")"
  _H1=""

  if echo "$del_resp" | grep -q '"error"'; then
    _err "Delete failed for $record_id"
    _debug "$del_resp"
    return 1
  fi

  _info "Deleted record $record_id"
  return 0
}

