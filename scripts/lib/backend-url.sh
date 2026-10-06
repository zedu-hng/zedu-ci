# shellcheck shell=bash
# The backend a PR builds against, from a "Backend URL: https://api.<team>.groups.zedu.chat" line in
# its body. The fork's build gate and the review repo's Fork build relay both use this, so they can't
# disagree about a PR.
#
#   backend_from_body <body>
#     Prints the API host (api.<team>.groups.zedu.chat), nothing when the body has no Backend URL
#     line, or "invalid" when the line doesn't hold a valid URL.

backend_from_body() {
  local line url
  line=$(printf '%s\n' "$1" | tr -d '\r' | grep -iE '^[[:space:]]*backend url:' | head -1 || true)
  [ -n "$line" ] || return 0
  url=$(sed -E 's/^[[:space:]]*[Bb][Aa][Cc][Kk][Ee][Nn][Dd] [Uu][Rr][Ll]:[[:space:]]*//; s/[[:space:]`<>]//g; s#/+$##' <<< "$line")
  if [[ "$url" =~ ^https://(api\.[a-z0-9-]+\.groups\.zedu\.chat)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo invalid
  fi
}
