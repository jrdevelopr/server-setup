#!/usr/bin/env bash
# board.sh — drive a GitHub Projects v2 board for an app repo.
#
#   board.sh additem <repo> <issue#>            add issue to its project (idempotent)
#   board.sh status  <repo> <issue#> "<Name>"   set the item's Status single-select
#   board.sh start   <repo> <issue#>            Status -> In Progress
#   board.sh done    <repo> <issue#>            close issue + Status -> Done
#
# The project is matched by title == <repo> under $GITHUB_OWNER (new-app.sh
# names the project after the repo). Field/option IDs are resolved per-project
# by name (they are NOT stable across projects). See skill: gh-project-status.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

CMD="${1:-}"; REPO="${2:-}"; ISSUE="${3:-}"; ARG4="${4:-}"
[ -n "$CMD" ] && [ -n "$REPO" ] || die "usage: board.sh {additem|status|start|done} <repo> <issue#> [status]"

# Resolve project node id by title (== repo name).
project_id() {
	gh api graphql -f query='
	query($owner:String!){ user(login:$owner){ projectsV2(first:50){ nodes{ id title } } } }' \
		-f owner="$GITHUB_OWNER" \
		--jq ".data.user.projectsV2.nodes[] | select(.title==\"$REPO\") | .id" | head -1
}

# Resolve issue node id.
issue_id() {
	gh api graphql -f query='
	query($owner:String!,$repo:String!,$num:Int!){
	  repository(owner:$owner,name:$repo){ issue(number:$num){ id } } }' \
		-f owner="$GITHUB_OWNER" -f repo="$REPO" -F num="$ISSUE" \
		--jq '.data.repository.issue.id'
}

# Ensure the issue is an item on the project; echo the item id.
ensure_item() {
	local pid="$1" iid="$2"
	# Already present?
	local existing
	existing=$(gh api graphql -f query='
	query($pid:ID!){ node(id:$pid){ ... on ProjectV2 { items(first:100){ nodes{ id content{ ... on Issue { id } } } } } } }' \
		-f pid="$pid" --jq ".data.node.items.nodes[] | select(.content.id==\"$iid\") | .id" | head -1)
	if [ -n "$existing" ]; then echo "$existing"; return; fi
	gh api graphql -f query='
	mutation($pid:ID!,$cid:ID!){ addProjectV2ItemById(input:{projectId:$pid,contentId:$cid}){ item{ id } } }' \
		-f pid="$pid" -f cid="$iid" --jq '.data.addProjectV2ItemById.item.id'
}

# Status field id + an option id by option name.
status_field_id() {
	gh api graphql -f query='
	query($pid:ID!){ node(id:$pid){ ... on ProjectV2 { field(name:"Status"){ ... on ProjectV2SingleSelectField { id } } } } }' \
		-f pid="$1" --jq '.data.node.field.id'
}
status_option_id() {
	gh api graphql -f query='
	query($pid:ID!){ node(id:$pid){ ... on ProjectV2 { field(name:"Status"){ ... on ProjectV2SingleSelectField { options{ id name } } } } } }' \
		-f pid="$1" --jq ".data.node.field.options[] | select(.name==\"$2\") | .id" | head -1
}

set_status() {
	local pid iid item fid oid name="$1"
	pid=$(project_id);   [ -n "$pid" ]  || die "no project titled '$REPO' under $GITHUB_OWNER"
	iid=$(issue_id);     [ -n "$iid" ]  || die "issue #$ISSUE not found in $GITHUB_OWNER/$REPO"
	item=$(ensure_item "$pid" "$iid")
	fid=$(status_field_id "$pid")
	oid=$(status_option_id "$pid" "$name"); [ -n "$oid" ] || die "no Status option named '$name'"
	gh api graphql -f query='
	mutation($pid:ID!,$item:ID!,$fid:ID!,$oid:String!){
	  updateProjectV2ItemFieldValue(input:{projectId:$pid,itemId:$item,fieldId:$fid,
	    value:{singleSelectOptionId:$oid}}){ projectV2Item{ id } } }' \
		-f pid="$pid" -f item="$item" -f fid="$fid" -f oid="$oid" >/dev/null
	ok "Status of $REPO#$ISSUE -> $name"
}

case "$CMD" in
	additem)
		pid=$(project_id); iid=$(issue_id); ensure_item "$pid" "$iid" >/dev/null
		ok "Added $REPO#$ISSUE to board" ;;
	status) [ -n "$ARG4" ] || die "status needs a name"; set_status "$ARG4" ;;
	start)  set_status "In Progress" ;;
	done)   set_status "Done"; gh issue close "$ISSUE" --repo "$GITHUB_OWNER/$REPO" >/dev/null 2>&1 || true
	        ok "Closed $REPO#$ISSUE" ;;
	*) die "unknown command '$CMD'" ;;
esac
