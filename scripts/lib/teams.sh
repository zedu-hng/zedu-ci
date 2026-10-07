# shellcheck shell=bash
# Registered teams, from zedu-ci's teams.yml on main: read live when a workflow runs, so registering a
# team or changing leads needs no caller bump. Needs GH_TOKEN; CI_REPO defaults to zedu-hng/zedu-ci.
#
#   team_of <fork owner>
#     Prints "found=true", "team=<key>" and "leads=<a,b>" lines, or "found=false". Keys match the fork
#     owner case-insensitively. Fails when teams.yml can't be read.
#   team_orgs
#     Prints every registered fork org, one per line.

_teams_file() {
  if [ -z "${_teams_path:-}" ]; then
    _teams_path=$(mktemp)
    gh api -H "Accept: application/vnd.github.raw" \
      "repos/${CI_REPO:-zedu-hng/zedu-ci}/contents/teams.yml?ref=main" > "$_teams_path" || { _teams_path=""; return 1; }
  fi
  echo "$_teams_path"
}

team_of() {
  local file
  file=$(_teams_file) || return 1
  OWNER=$1 ruby -ryaml -e '
    cfg = YAML.load_file(ARGV[0]) || {}
    owner = ENV.fetch("OWNER", "").downcase
    name, team = (cfg["teams"] || {}).find { |k, _| k.to_s.downcase == owner }
    if team
      puts "found=true", "team=#{name}", "leads=#{Array(team["leads"]).join(",")}"
    else
      puts "found=false"
    end
  ' "$file"
}

team_orgs() {
  local file
  file=$(_teams_file) || return 1
  ruby -ryaml -e 'puts ((YAML.load_file(ARGV[0]) || {})["teams"] || {}).keys' "$file"
}
