#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# BookStack user & role management via API
# Version: 1.1.0
# Date: 2026-04-23
#
# This script manages BookStack users and roles using the official REST API.
# It supports:
#   - Adding/removing/moving users between roles
#   - Creating users from CSV
#   - Updating users from CSV
#   - Deleting users from TXT or CSV
#   - Listing all users with their roles
#   - Listing all users for a given role
#
# Author: Sascha Jelinek, ADMIN INTELLIGENCE GmbH
# Website: https://www.admin-intelligence.de

set -uo pipefail

# =============================
# Configuration (defaults)
# =============================

# Base URL for BookStack API.
# Default is localhost, ideal when running on the BookStack host itself.
: "${BOOKSTACK_URL:=http://127.0.0.1}"

# API token credentials (must be overridden in environment).
: "${BOOKSTACK_TOKEN_ID:=HERE_YOUR_TOKEN_ID}"
: "${BOOKSTACK_TOKEN_SECRET:=HERE_YOUR_TOKEN_SECRET}"

# Number of items per API list request.
API_LIST_COUNT=500

# Logging & behavior flags.
LOG_CSV=""
ASSUME_YES=0           # auto-confirm destructive ops
DRY_RUN=0              # simulate write operations
EXPORT_MODE=0          # mark run as export (for list modes)
GENERATE_PASSWORD_LENGTH=20

# Record separator used between Python and Bash to preserve empty fields.
RECORD_SEP=$'\x1f'

# =============================
# Colors & messaging helpers
# =============================

init_colors() {
  if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
    return
  fi
  if command -v tput >/dev/null 2>&1 && [[ -n "${TERM:-}" ]] && tput colors >/dev/null 2>&1; then
    BOLD="$(tput bold)"
    DIM="$(tput dim 2>/dev/null || true)"
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 6)"
    RESET="$(tput sgr0)"
  else
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
  fi
}

msg_info()   { printf "%b\n" "${BLUE}${BOLD}[INFO]${RESET} $*"; }
msg_ok()     { printf "%b\n" "${GREEN}${BOLD}[ OK ]${RESET} $*"; }
msg_warn()   { printf "%b\n" "${YELLOW}${BOLD}[WARN]${RESET} $*"; }
msg_error()  { printf "%b\n" "${RED}${BOLD}[FAIL]${RESET} $*"; } >&2
msg_header() { printf "%b\n" "${CYAN}${BOLD}$*${RESET}"; }
msg_sub()    { printf "%b\n" "${BOLD}$*${RESET}"; }
msg_dim()    { printf "%b\n" "${DIM}$*${RESET}"; }

die() { msg_error "$*"; exit 1; }

# =============================
# Generic helpers
# =============================

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

csv_escape() {
  local s="$1"
  s=${s//$'\r'/ }
  s=${s//$'\n'/ }
  s=${s//\"/\"\"}
  printf '"%s"' "$s"
}

now_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

# =============================
# CSV logging
# =============================

init_log() {
  [[ -z "$LOG_CSV" ]] && return 0
  if [[ ! -f "$LOG_CSV" ]]; then
    printf 'timestamp,mode,target,status,message,user_name,email,user_id,roles_before,roles_after,payload\n' > "$LOG_CSV"
  fi
}

write_log() {
  [[ -z "$LOG_CSV" ]] && return 0
  local timestamp="$1" mode="$2" target="$3" status="$4" message="$5"
  local user_name="$6" email="$7" user_id="$8" roles_before="$9"
  local roles_after="${10}" payload="${11}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$timestamp")" \
    "$(csv_escape "$mode")" \
    "$(csv_escape "$target")" \
    "$(csv_escape "$status")" \
    "$(csv_escape "$message")" \
    "$(csv_escape "$user_name")" \
    "$(csv_escape "$email")" \
    "$(csv_escape "$user_id")" \
    "$(csv_escape "$roles_before")" \
    "$(csv_escape "$roles_after")" \
    "$(csv_escape "$payload")" >> "$LOG_CSV"
}

# =============================
# Input validation
# =============================

validate_email_plain() {
  local email="$1"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

# =============================
# HTTP / API helpers
# =============================

api_request() {
  local method="$1" path="$2" body="${3-}"
  local tmp_body http_code curl_rc
  tmp_body="$(mktemp)"

  if [[ -n "$body" ]]; then
    http_code="$(curl -g -sS -o "$tmp_body" -w '%{http_code}' \
      -X "$method" -H "$AUTH_HEADER" -H "$JSON_HEADER" \
      --data "$body" "$BOOKSTACK_URL$path")"
    curl_rc=$?
  else
    http_code="$(curl -g -sS -o "$tmp_body" -w '%{http_code}' \
      -X "$method" -H "$AUTH_HEADER" "$BOOKSTACK_URL$path")"
    curl_rc=$?
  fi

  API_LAST_BODY="$(cat "$tmp_body")"
  API_LAST_HTTP_CODE="$http_code"
  rm -f "$tmp_body"

  if [[ $curl_rc -ne 0 ]]; then
    return $curl_rc
  fi
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    return 22
  fi
  return 0
}

api_error_message() {
  local body="${API_LAST_BODY:-}"
  local code="${API_LAST_HTTP_CODE:-unknown}"
  local msg
  msg="$(jq -r '.error.message // .message // empty' 2>/dev/null <<<"$body")"
  if [[ -n "$msg" ]]; then
    printf 'HTTP %s: %s' "$code" "$msg"
  else
    printf 'HTTP %s' "$code"
  fi
}

api_get()    { api_request GET "$1" || return $?; printf "%s" "$API_LAST_BODY"; }
api_post()   { api_request POST "$1" "$2" || return $?; printf "%s" "$API_LAST_BODY"; }
api_put()    { api_request PUT "$1" "$2" || return $?; printf "%s" "$API_LAST_BODY"; }
api_delete() { api_request DELETE "$1" || return $?; printf "%s" "$API_LAST_BODY"; }

api_preflight_check() {
  local ok=0

  if [[ "$BOOKSTACK_URL" == "" || "$BOOKSTACK_URL" == "https://bookstack.example.com" || \
        "$BOOKSTACK_TOKEN_ID" == "HERE_YOUR_TOKEN_ID" || "$BOOKSTACK_TOKEN_SECRET" == "HERE_YOUR_TOKEN_SECRET" ]]; then
    msg_error "BOOKSTACK_URL / BOOKSTACK_TOKEN_ID / BOOKSTACK_TOKEN_SECRET still use placeholder values. Please configure them."
    cat >&2 <<EOF
Examples:
  export BOOKSTACK_URL="http://127.0.0.1"
  export BOOKSTACK_TOKEN_ID="YOUR_TOKEN_ID"
  export BOOKSTACK_TOKEN_SECRET="YOUR_TOKEN_SECRET"
EOF
    exit 1
  fi

  msg_info "Checking API reachability and authentication"
  if api_get "/api/users?count=1" >/dev/null 2>&1; then
    ok=1
  fi

  if [[ "$ok" -ne 1 ]]; then
    msg_error "API preflight failed: $(api_error_message)"
    cat >&2 <<EOF
Possible reasons:
- BOOKSTACK_URL is empty, wrong or does not point at the BookStack instance
- BOOKSTACK_TOKEN_ID or BOOKSTACK_TOKEN_SECRET are wrong
- The API user does not have 'Access System API' permission
- Reverse proxy / TLS / network issues prevent API access
EOF
    exit 1
  fi

  msg_ok "API preflight successful"
}

# =============================
# BookStack-specific helpers
# =============================

get_role_id_by_name() {
  local role_name="$1" encoded
  encoded="$(printf '%s' "$role_name" | jq -sRr @uri)"
  api_get "/api/roles?count=${API_LIST_COUNT}&filter[display_name]=${encoded}" \
    | jq -r --arg rn "$role_name" '.data[] | select((.display_name // .name) == $rn) | .id' \
    | head -n1
}

get_user_by_email() {
  local email="$1" encoded
  encoded="$(printf '%s' "$email" | jq -sRr @uri)"
  api_get "/api/users?count=${API_LIST_COUNT}&filter[email]=${encoded}" \
    | jq -c --arg em "$email" '.data[] | select(.email == $em)' \
    | head -n1
}

get_user_detail() {
  local user_id="$1"
  api_get "/api/users/${user_id}"
}

get_all_users() {
  # Fetch all users using pagination.
  local page=1
  local result data count
  local users_json='[]'

  while :; do
    result="$(api_get "/api/users?count=${API_LIST_COUNT}&page=${page}" 2>/dev/null || true)"
    [[ -z "$result" ]] && break

    data="$(jq -c '.data // []' <<<"$result")"
    count="$(jq -r '.data | length' <<<"$result")"

    users_json="$(jq -c --argjson chunk "$data" '. + $chunk' <<<"$users_json")"

    if [[ "$count" -lt "$API_LIST_COUNT" ]]; then
      break
    fi
    ((page++))
  done

  printf '%s' "$users_json"
}

# =============================
# Password generation
# =============================

generate_password() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required to generate passwords."
  python3 - <<PY
import secrets, string
length = ${GENERATE_PASSWORD_LENGTH}
alphabet = string.ascii_letters + string.digits + '!@#%^*_-+='
while True:
    pw = ''.join(secrets.choice(alphabet) for _ in range(length))
    if (any(c.islower() for c in pw) and any(c.isupper() for c in pw)
        and any(c.isdigit() for c in pw) and any(c in '!@#%^*_-+=' for c in pw)):
        print(pw)
        break
PY
}

# =============================
# Role resolution
# =============================

resolve_roles_to_ids_json() {
  # Convert comma-separated role names into a JSON array of role IDs.
  local roles_csv="$1"
  local ids_json='[]'
  local raw_role role role_id

  if [[ -z "$(trim "$roles_csv")" ]]; then
    printf '[]'
    return 0
  fi

  IFS=',' read -ra raw_roles <<< "$roles_csv"
  for raw_role in "${raw_roles[@]}"; do
    role="$(trim "$raw_role")"
    [[ -z "$role" ]] && continue
    role_id="$(get_role_id_by_name "$role" 2>/dev/null || true)"
    # If the role does not exist, silently skip. Handling is done by caller.
    [[ -z "${role_id:-}" ]] && continue
    ids_json="$(jq -c --argjson rid "$role_id" '. + [$rid] | unique' <<<"$ids_json")"
  done

  printf '%s' "$ids_json"
}

# =============================
# CSV loading for create/update
# =============================

load_csv_rows() {
  # Read user-create/update CSV and emit name, email, password, roles
  # separated by RECORD_SEP to Bash.
  local csv_file="$1"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for CSV parsing."
  python3 - <<'PY' "$csv_file"
import csv, sys, os, re
SEP = "\x1f"

path = sys.argv[1]
if not os.path.isfile(path):
    print("__ERROR__" + SEP + "CSV file not found: " + path)
    raise SystemExit(0)

with open(path, newline='', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f, delimiter=';')
    required = ['name', 'email', 'password', 'roles']
    if reader.fieldnames is None:
        print("__ERROR__" + SEP + "CSV file is empty or invalid")
        raise SystemExit(0)
    missing = [r for r in required if r not in reader.fieldnames]
    if missing:
        print("__ERROR__" + SEP + "Missing CSV columns: " + ", ".join(missing))
        raise SystemExit(0)

    for row in reader:
        name = (row.get('name') or '').replace('\t', ' ').strip()
        email_raw = (row.get('email') or '').replace('\t', ' ').strip()
        password = (row.get('password') or '').replace('\t', ' ').strip()
        roles = (row.get('roles') or '').replace('\t', ' ').strip()

        m = re.search(r'([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[A-Za-z]{2,})', email_raw)
        if m:
            email = m.group(1)
        else:
            print("__ERROR__" + SEP + "Email field does not contain a valid address: " + email_raw)
            continue

        print(SEP.join([name, email, password, roles]))
PY
}

# =============================
# Generic email extraction (TXT or CSV)
# =============================

extract_emails_from_input() {
  local input_file="$1"

  case "${input_file##*.}" in
    csv|CSV)
      command -v python3 >/dev/null 2>&1 || die "python3 is required for CSV parsing."
      python3 - <<'PY' "$input_file"
import csv, sys, os, re

path = sys.argv[1]
if not os.path.isfile(path):
    print("__ERROR__")
    print("File not found: " + path)
    raise SystemExit(0)

with open(path, newline='', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f, delimiter=';')
    if reader.fieldnames is None:
        print("__ERROR__")
        print("CSV file is empty or invalid")
        raise SystemExit(0)
    if 'email' not in reader.fieldnames:
        print("__ERROR__")
        print("CSV file needs an 'email' column")
        raise SystemExit(0)
    for row in reader:
        email_raw = (row.get('email') or '').strip()
        if not email_raw:
            continue
        m = re.search(r'([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[A-Za-z]{2,})', email_raw)
        if m:
            print(m.group(1))
        else:
            print(email_raw)
PY
      ;;
    *)
      cat "$input_file"
      ;;
  esac
}

# =============================
# Confirmation for destructive ops
# =============================

confirm_delete() {
  if [[ "$ASSUME_YES" -eq 1 ]] || [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  printf "%b" "${YELLOW}${BOLD}Confirm:${RESET} Really delete all users from this file? [y/N] "
  read -r answer
  [[ "$answer" =~ ^([Yy]|[Jj]|[Yy][Ee][Ss]|[Jj][Aa])$ ]]
}

# =============================
# Role change processing
# =============================

process_role_change_user() {
  local mode="$1" email="$2" source_role_id="$3" target_role_id="$4"
  local ts
  ts="$(now_ts)"
  msg_header "Processing: $email"

  if ! validate_email_plain "$email"; then
    msg_error "Invalid email: '$email' (plain email required)"
    write_log "$ts" "$mode" "$email" "error" "Invalid email" "" "$email" "" "" "" ""
    ((ERROR_COUNT++))
    echo
    return 0
  fi

  local user_json user_id user_name detail_json current_roles_json current_role_names new_roles_json payload
  user_json="$(get_user_by_email "$email" 2>/dev/null || true)"
  if [[ -z "${user_json:-}" ]]; then
    msg_warn "User not found"
    write_log "$ts" "$mode" "$email" "not_found" "User not found" "" "$email" "" "" "" ""
    ((NOT_FOUND_COUNT++))
    echo
    return 0
  fi

  user_id="$(jq -r '.id' <<<"$user_json")"
  user_name="$(jq -r '.name // "<no name>"' <<<"$user_json")"
  detail_json="$(get_user_detail "$user_id" 2>/dev/null || true)"
  if [[ -z "${detail_json:-}" ]]; then
    msg_error "Failed to load user details for user ID $user_id"
    write_log "$ts" "$mode" "$email" "error" "Could not load user details" "$user_name" "$email" "$user_id" "" "" ""
    ((ERROR_COUNT++))
    echo
    return 0
  fi

  current_roles_json="$(jq -c '[.roles[]?.id]' <<<"$detail_json")"
  current_role_names="$(jq -r '[.roles[]? | (.display_name // .name // ("ID:" + (.id|tostring)))] | join(", ")' <<<"$detail_json")"
  [[ -z "$current_roles_json" || "$current_roles_json" == "null" ]] && current_roles_json="[]"
  [[ -z "$current_role_names" || "$current_role_names" == "null" ]] && current_role_names="-"

  msg_info "User ID: $user_id"
  msg_info "Name:    $user_name"
  msg_info "Roles:   $current_role_names"

  case "$mode" in
    role-add)
      new_roles_json="$(jq -c --argjson dst "$target_role_id" 'if index($dst) == null then . + [$dst] else . end' <<<"$current_roles_json")"
      ;;
    role-remove)
      new_roles_json="$(jq -c --argjson src "$source_role_id" 'map(select(. != $src))' <<<"$current_roles_json")"
      ;;
    role-move)
      new_roles_json="$(
        jq -c --argjson src "$source_role_id" --argjson dst "$target_role_id" \
          'map(select(. != $src)) | if index($dst) == null then . + [$dst] else . end' \
          <<<"$current_roles_json"
      )"
      ;;
  esac

  if [[ "$new_roles_json" == "$current_roles_json" ]]; then
    msg_warn "No change required"
    write_log "$ts" "$mode" "$email" "skipped" "No change required" "$user_name" "$email" "$user_id" "$current_roles_json" "$new_roles_json" ""
    ((SKIPPED_COUNT++))
    echo
    return 0
  fi

  payload="$(
    jq -cn \
      --arg name "$(jq -r '.name' <<<"$detail_json")" \
      --arg email "$(jq -r '.email' <<<"$detail_json")" \
      --argjson roles "$new_roles_json" \
      '{name: $name, email: $email, roles: $roles}'
  )"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    msg_warn "DRY-RUN: No update executed"
    write_log "$ts" "$mode" "$email" "dry_run" "Planned role update" "$user_name" "$email" "$user_id" "$current_roles_json" "$new_roles_json" "$payload"
    ((CHANGED_COUNT++))
  else
    if api_put "/api/users/${user_id}" "$payload" >/dev/null 2>&1; then
      msg_ok "User '$user_name' updated"
      write_log "$ts" "$mode" "$email" "success" "User updated" "$user_name" "$email" "$user_id" "$current_roles_json" "$new_roles_json" "$payload"
      ((CHANGED_COUNT++))
    else
      msg_error "Update failed for user '$user_name'"
      write_log "$ts" "$mode" "$email" "error" "Update failed" "$user_name" "$email" "$user_id" "$current_roles_json" "$new_roles_json" "$payload"
      ((ERROR_COUNT++))
    fi
  fi

  echo
}

# =============================
# user-create / user-update from CSV
# =============================

process_user_create_or_update_csv() {
  local mode="$1" csv_file="$2"
  local name email password roles generated_password roles_json payload
  local existing_user_json user_id user_name detail_json current_roles_json ts

  while IFS="$RECORD_SEP" read -r name email password roles; do
    ts="$(now_ts)"

    if [[ "$name" == "__ERROR__" ]]; then
      msg_error "$email"
      write_log "$ts" "$mode" "$csv_file" "error" "$email" "" "$email" "" "" "" ""
      ((ERROR_COUNT++))
      continue
    fi

    [[ -z "$(trim "$name")" && -z "$(trim "$email")" && -z "$(trim "$password")" && -z "$(trim "$roles")" ]] && continue

    msg_header "${mode/user-/}: $email"
    msg_info "Name:   $name"
    msg_info "Roles:  ${roles:--}"

    if ! validate_email_plain "$email"; then
      msg_error "Invalid email: '$email' (plain email required)"
      write_log "$ts" "$mode" "$csv_file" "error" "Invalid email" "$name" "$email" "" "" "" ""
      ((ERROR_COUNT++))
      echo
      continue
    fi

    if [[ -z "$(trim "$name")" || -z "$(trim "$email")" ]]; then
      msg_error "Missing required fields for '$email' (name,email required)"
      write_log "$ts" "$mode" "$csv_file" "error" "Missing required fields" "$name" "$email" "" "" "" ""
      ((ERROR_COUNT++))
      echo
      continue
    fi

    existing_user_json="$(get_user_by_email "$email" 2>/dev/null || true)"

    if [[ "$mode" == "user-create" && -n "${existing_user_json:-}" ]]; then
      msg_warn "User already exists, skipped"
      write_log "$ts" "$mode" "$csv_file" "skipped" "User already exists" "$name" "$email" "$(jq -r '.id' <<<"$existing_user_json")" "" "" ""
      ((SKIPPED_COUNT++))
      echo
      continue
    fi

    if [[ "$mode" == "user-update" && -z "${existing_user_json:-}" ]]; then
      msg_warn "User not found, skipped"
      write_log "$ts" "$mode" "$csv_file" "not_found" "User not found" "$name" "$email" "" "" "" ""
      ((NOT_FOUND_COUNT++))
      echo
      continue
    fi

    roles_json='[]'
    if [[ -n "$(trim "$roles")" ]]; then
      roles_json="$(resolve_roles_to_ids_json "$roles" | tr -d '\r')"
      if ! jq -e . >/dev/null 2>&1 <<<"$roles_json"; then
        msg_error "roles_json is not valid JSON: $roles_json"
        write_log "$ts" "$mode" "$csv_file" "error" "roles_json invalid" "$name" "$email" "" "" "" "$roles_json"
        ((ERROR_COUNT++))
        echo
        continue
      fi
      if [[ "$roles_json" == "[]" ]]; then
        if [[ "$mode" == "user-create" ]]; then
          msg_warn "None of the requested roles exist, user will be created without extra roles"
        else
          msg_error "None of the requested roles exist, user update aborted"
          write_log "$ts" "$mode" "$csv_file" "error" "No roles exist" "$name" "$email" "$(jq -r '.id' <<<"$existing_user_json")" "" "" ""
          ((ERROR_COUNT++))
          echo
          continue
        fi
      fi
    fi

    generated_password=""
    if [[ "$mode" == "user-create" && -z "$(trim "$password")" ]]; then
      generated_password="$(generate_password)"
      password="$generated_password"
      msg_warn "No password in CSV, generated one automatically"
      msg_dim "Generated password: $generated_password"
    fi

    if [[ "$mode" == "user-create" ]]; then
      if [[ -z "$(trim "$password")" ]]; then
        msg_error "Password is required for '$email'"
        write_log "$ts" "$mode" "$csv_file" "error" "Password missing" "$name" "$email" "" "" "" ""
        ((ERROR_COUNT++))
        echo
        continue
      fi

      payload="$(
        jq -cn \
          --arg name "$name" \
          --arg email "$email" \
          --arg password "$password" \
          --argjson roles "$roles_json" \
          '{name: $name, email: $email, password: $password, roles: $roles}'
      )"

      if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_warn "DRY-RUN: No user created"
        local status="dry_run" message="Planned create"
        if [[ "$roles_json" == "[]" && -n "$(trim "$roles")" ]]; then
          message="Planned create without extra roles (no roles found)"
        fi
        write_log "$ts" "$mode" "$csv_file" "$status" "$message" "$name" "$email" "" "" "$roles_json" "$payload"
        ((CHANGED_COUNT++))
      else
        if api_post "/api/users" "$payload" >/dev/null 2>&1; then
          local status="success" message="User created"
          if [[ "$roles_json" == "[]" && -n "$(trim "$roles")" ]]; then
            status="success_no_roles"
            message="User created but none of the requested roles exist"
          fi
          msg_ok "User '$email' created"
          if [[ -n "$generated_password" ]]; then
            msg_warn "Please store the generated password securely"
          fi
          write_log "$ts" "$mode" "$csv_file" "$status" "$message" "$name" "$email" "" "" "$roles_json" "$payload"
          ((CHANGED_COUNT++))
        else
          msg_error "Creating user '$email' failed"
          write_log "$ts" "$mode" "$csv_file" "error" "Create failed" "$name" "$email" "" "" "$roles_json" "$payload"
          ((ERROR_COUNT++))
        fi
      fi

    else
      user_id="$(jq -r '.id' <<<"$existing_user_json")"
      user_name="$(jq -r '.name // "<no name>"' <<<"$existing_user_json")"
      detail_json="$(get_user_detail "$user_id" 2>/dev/null || true)"
      current_roles_json="$(jq -c '[.roles[]?.id]' <<<"${detail_json:-{}}")"
      [[ -z "$current_roles_json" || "$current_roles_json" == "null" ]] && current_roles_json="[]"

      if [[ -n "$(trim "$password")" ]]; then
        payload="$(
          jq -cn \
            --arg name "$name" \
            --arg email "$email" \
            --arg password "$password" \
            --argjson roles "$roles_json" \
            '{name: $name, email: $email, password: $password, roles: $roles}'
        )"
      else
        payload="$(
          jq -cn \
            --arg name "$name" \
            --arg email "$email" \
            --argjson roles "$roles_json" \
            '{name: $name, email: $email, roles: $roles}'
        )"
      fi

      if [[ "$DRY_RUN" -eq 1 ]]; then
        msg_warn "DRY-RUN: No user updated"
        write_log "$ts" "$mode" "$csv_file" "dry_run" "Planned update" "$user_name" "$email" "$user_id" "$current_roles_json" "$roles_json" "$payload"
        ((CHANGED_COUNT++))
      else
        if api_put "/api/users/${user_id}" "$payload" >/dev/null 2>&1; then
          msg_ok "User '$email' updated"
          write_log "$ts" "$mode" "$csv_file" "success" "User updated" "$user_name" "$email" "$user_id" "$current_roles_json" "$roles_json" "$payload"
          ((CHANGED_COUNT++))
        else
          msg_error "Updating user '$email' failed"
          write_log "$ts" "$mode" "$csv_file" "error" "Update failed" "$user_name" "$email" "$user_id" "$current_roles_json" "$roles_json" "$payload"
          ((ERROR_COUNT++))
        fi
      fi
    fi

    echo
  done < <(load_csv_rows "$csv_file")
}

# =============================
# user-delete from TXT or CSV
# =============================

process_user_delete_file() {
  local input_file="$1"
  local email user_json user_id user_name ts next_line

  if ! confirm_delete; then
    die "Delete operation aborted. Use --yes for unattended runs."
  fi

  while IFS= read -r email || [[ -n "$email" ]]; do
    ts="$(now_ts)"
    email="$(trim "$email")"
    [[ -z "$email" ]] && continue

    if [[ "$email" == "__ERROR__" ]]; then
      IFS= read -r next_line || true
      die "$next_line"
    fi

    [[ "$email" =~ ^# ]] && continue

    msg_header "Delete: $email"

    if ! validate_email_plain "$email"; then
      msg_error "Invalid email: '$email' (plain email required)"
      write_log "$ts" "user-delete" "$input_file" "error" "Invalid email" "" "$email" "" "" "" ""
      ((ERROR_COUNT++))
      echo
      continue
    fi

    user_json="$(get_user_by_email "$email" 2>/dev/null || true)"
    if [[ -z "${user_json:-}" ]]; then
      msg_warn "User not found"
      write_log "$ts" "user-delete" "$input_file" "not_found" "User not found" "" "$email" "" "" "" ""
      ((NOT_FOUND_COUNT++))
      echo
      continue
    fi

    user_id="$(jq -r '.id' <<<"$user_json")"
    user_name="$(jq -r '.name // "<no name>"' <<<"$user_json")"
    msg_info "User ID: $user_id"
    msg_info "Name:    $user_name"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      msg_warn "DRY-RUN: No user deleted"
      write_log "$ts" "user-delete" "$input_file" "dry_run" "Planned delete" "$user_name" "$email" "$user_id" "" "" ""
      ((CHANGED_COUNT++))
    else
      if api_delete "/api/users/${user_id}" >/dev/null 2>&1; then
        msg_ok "User '$user_name' deleted"
        write_log "$ts" "user-delete" "$input_file" "success" "User deleted" "$user_name" "$email" "$user_id" "" "" ""
        ((CHANGED_COUNT++))
      else
        msg_error "Deleting user '$user_name' failed"
        write_log "$ts" "user-delete" "$input_file" "error" "Delete failed" "$user_name" "$email" "$user_id" "" "" ""
        ((ERROR_COUNT++))
      fi
    fi

    echo
  done < <(extract_emails_from_input "$input_file")
}

# =============================
# Listing users and role members
# =============================

process_user_list() {
  local users_json user id name email roles_list

  msg_header "Listing users"
  users_json="$(get_all_users)"

  # CSV header to stdout
  printf 'id;name;email;roles\n'

  jq -c '.[]' <<<"$users_json" | while read -r user; do
    id="$(jq -r '.id' <<<"$user")"
    name="$(jq -r '.name' <<<"$user")"
    email="$(jq -r '.email' <<<"$user")"
    roles_list="$(
      jq -r '[.roles[]? | (.display_name // .name // ("ID:" + (.id|tostring)))] | join(",")' \
        <<<"$user"
    )"
    printf '%s;%s;%s;%s\n' "$id" "$name" "$email" "$roles_list"
  done
}

process_role_list() {
  local result roles_json role id name desc

  msg_header "Listing roles"

  # Fetch all roles in a single call; API typically supports count param.
  result="$(api_get "/api/roles?count=${API_LIST_COUNT}" 2>/dev/null || true)"
  roles_json="$(jq -c '.data // []' <<<"$result")"

  # CSV header
  printf 'id;name;description\n'

  jq -c '.[]' <<<"$roles_json" | while read -r role; do
    id="$(jq -r '.id' <<<"$role")"
    name="$(jq -r '.display_name // .name' <<<"$role")"
    desc="$(jq -r '.description // ""' <<<"$role")"
    printf '%s;%s;%s\n' "$id" "$name" "$desc"
  done
}

process_role_users() {
  local role_name="$1" role_id users_json user id name email roles_list

  msg_header "Users for role: $role_name"

  role_id="$(get_role_id_by_name "$role_name" || true)"
  [[ -n "$role_id" ]] || die "Role not found: $role_name"

  users_json="$(get_all_users)"

  # CSV header to stdout
  printf 'id;name;email;roles\n'

  jq -c --argjson rid "$role_id" '.[] | select([.roles[]?.id] | index($rid) != null)' \
    <<<"$users_json" | while read -r user; do
      id="$(jq -r '.id' <<<"$user")"
      name="$(jq -r '.name' <<<"$user")"
      email="$(jq -r '.email' <<<"$user")"
      roles_list="$(
        jq -r '[.roles[]? | (.display_name // .name // ("ID:" + (.id|tostring)))] | join(",")' \
          <<<"$user"
      )"
      printf '%s;%s;%s;%s\n' "$id" "$name" "$email" "$roles_list"
    done
}

# =============================
# CLI help text
# =============================

show_help() {
  msg_header "BookStack user & role management via API"
  printf "%b\n" "${BOLD}Version:${RESET} 1.3.3"
  printf "%b\n" "${BOLD}Date:${RESET} 2026-04-23}"
  printf "%b\n" "${BOLD}Website:${RESET} https://www.admin-intelligence.de"
  printf "%b\n" "${BOLD}License:${RESET} MIT (SPDX-License-Identifier: MIT)"
  echo

  msg_sub "DESCRIPTION"
  cat <<EOF
This script manages BookStack users and roles via the REST API.
It uses API tokens through the 'Authorization: Token <id>:<secret>' header.
The API user must have the 'Access System API' permission.
EOF
  echo

  msg_sub "SUPPORTED MODES"
  cat <<EOF
  role-add    - Add users to a target role (TXT or CSV)
  role-remove - Remove users from a source role (TXT or CSV)
  role-move   - Move users from a source role to a target role (TXT or CSV)
  role-users  - List users that have a given role (CSV to stdout)
  role-list   - List all roles (CSV to stdout)
  user-create - Create users from a CSV file (CSV only)
  user-update - Update existing users from a CSV file (CSV only)
  user-delete - Delete users from a TXT or CSV file
  user-list   - List all users with their roles (CSV to stdout)
EOF
  echo

  msg_sub "OPTIONS"
  cat <<EOF
  --dry-run
      Perform no write operations; show only planned changes.

  --yes
      Auto-confirm destructive actions, especially user-delete.

  --log-csv <file.csv>
      Write a CSV log with timestamp, mode, status, user and role details,
      and payload for each processed entry.

  --export
      Mark this run as an export. Intended for list modes (user-list,
      role-users) where CSV is printed to stdout. Has no effect on
      write modes.

  -h | --help | -?
      Show this help.
EOF
  echo

  msg_sub "ENVIRONMENT VARIABLES"
  cat <<EOF
  BOOKSTACK_URL
      Base URL of the BookStack instance for API requests.
      Default: http://127.0.0.1

  BOOKSTACK_TOKEN_ID / BOOKSTACK_TOKEN_SECRET
      API token ID and secret from the BookStack user profile.
EOF
  echo

  msg_sub "INPUT FORMATS"
  cat <<EOF
TXT file:
  - one plain email address per line
  - empty lines are ignored
  - lines starting with # are treated as comments

CSV file (semicolon-separated):
  - for user-create/user-update: header 'name;email;password;roles'
  - for role-add/role-remove/role-move/user-delete: at least 'email'
  - additional columns for role*/user-delete are ignored
  - roles are comma-separated in the 'roles' field, e.g. "Staff,Wiki-Reader"
  - for user-create, an empty password triggers automatic password generation
  - for user-update, an empty password keeps the current password
EOF
  echo

  msg_sub "MODE BEHAVIOR"
  cat <<EOF
role-add / role-remove / role-move:
  - accept TXT or CSV
  - when CSV is used, only the 'email' column is read
  - source/target roles must exist, otherwise the run aborts before changes

role-users:
  - read-only mode, lists all users that have a given role as semicolon CSV

role-list:
  - read-only mode, lists all roles as semicolon CSV
  - columns: id;name;description

user-create:
  - accepts only CSV
  - if requested roles do not exist, the user is still created
    but with no extra roles
  - that case is logged with status 'success_no_roles'

user-update:
  - accepts only CSV
  - if roles are provided and none exist, the update for that user is aborted
    to avoid accidental role loss

user-delete:
  - accepts TXT or CSV
  - when CSV is used, only the 'email' column is read

user-list:
  - read-only mode, lists all users with their roles as semicolon CSV
EOF
  echo

  msg_sub "EXAMPLES"
  cat <<EOF
  $(basename "$0") --dry-run role-add "Editors" users.txt
  $(basename "$0") role-move "External" "Staff" users.csv
  $(basename "$0") --dry-run user-create users.csv
  $(basename "$0") user-update users.csv
  $(basename "$0") --yes user-delete users.csv
  $(basename "$0") user-list > all-users.csv
  $(basename "$0") role-users "Editors" > editors-users.csv
  $(basename "$0") --log-csv log.csv role-remove "Wiki-Reader" users.csv
  $(basename "$0") role-list > roles.csv
EOF
}

# =============================
# main()
# =============================

main() {
  init_colors

  # Parse global options.
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --log-csv)
        [[ $# -ge 2 ]] || die "--log-csv requires a file name"
        LOG_CSV="$2"
        shift 2
        ;;
      --export)
        EXPORT_MODE=1
        shift
        ;;
      -h|--help|-?)
        show_help
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || die "jq is required."
  [[ $# -ge 1 ]] || { show_help; exit 1; }

  MODE="$1"
  shift
  INPUT_FILE=""
  SOURCE_ROLE_NAME=""
  TARGET_ROLE_NAME=""

  # Parse mode-specific arguments.
  case "$MODE" in
    role-add)
      [[ $# -eq 2 ]] || die "Usage: $(basename "$0") [--dry-run] role-add <target-role> <emails.txt|users.csv>"
      TARGET_ROLE_NAME="$1"; INPUT_FILE="$2"
      ;;
    role-remove)
      [[ $# -eq 2 ]] || die "Usage: $(basename "$0") [--dry-run] role-remove <source-role> <emails.txt|users.csv>"
      SOURCE_ROLE_NAME="$1"; INPUT_FILE="$2"
      ;;
    role-move)
      [[ $# -eq 3 ]] || die "Usage: $(basename "$0") [--dry-run] role-move <source-role> <target-role> <emails.txt|users.csv>"
      SOURCE_ROLE_NAME="$1"; TARGET_ROLE_NAME="$2"; INPUT_FILE="$3"
      ;;
    user-create|user-update|user-delete)
      [[ $# -eq 1 ]] || die "Usage: $(basename "$0") [options] $MODE <file>"
      INPUT_FILE="$1"
      ;;
    user-list)
      [[ $# -eq 0 ]] || die "Usage: $(basename "$0") user-list"
      ;;
    role-users)
      [[ $# -eq 1 ]] || die "Usage: $(basename "$0") role-users <role-name>"
      TARGET_ROLE_NAME="$1"
      ;;
    role-list)
      [[ $# -eq 0 ]] || die "Usage: $(basename "$0") role-list"
      ;;
    *)
      die "Unknown mode '$MODE'. See --help."
      ;;
  esac

  # Enforce CSV for create/update.
  if [[ "$MODE" == "user-create" || "$MODE" == "user-update" ]]; then
    case "${INPUT_FILE##*.}" in
      csv|CSV) ;;
      *) die "$MODE accepts only CSV files in semicolon format." ;;
    esac
  fi

  AUTH_HEADER="Authorization: Token ${BOOKSTACK_TOKEN_ID}:${BOOKSTACK_TOKEN_SECRET}"
  JSON_HEADER="Content-Type: application/json"

  init_log
  api_preflight_check

  # Resolve source/target roles if provided (for role-* and role-users).
  SOURCE_ROLE_ID=""
  TARGET_ROLE_ID=""
  if [[ -n "$SOURCE_ROLE_NAME" ]]; then
    SOURCE_ROLE_ID="$(get_role_id_by_name "$SOURCE_ROLE_NAME" || true)"
    [[ -n "$SOURCE_ROLE_ID" ]] || die "Source role not found: $SOURCE_ROLE_NAME"
  fi
  if [[ -n "$TARGET_ROLE_NAME" && "$MODE" != "role-users" ]]; then
    TARGET_ROLE_ID="$(get_role_id_by_name "$TARGET_ROLE_NAME" || true)"
    [[ -n "$TARGET_ROLE_ID" ]] || die "Target role not found: $TARGET_ROLE_NAME"
  fi

  CHANGED_COUNT=0
  SKIPPED_COUNT=0
  NOT_FOUND_COUNT=0
  ERROR_COUNT=0

  echo
  msg_header "Run parameters"
  msg_info "Mode: $MODE"
  msg_info "API list count: $API_LIST_COUNT"
  msg_info "BOOKSTACK_URL: $BOOKSTACK_URL"
  [[ -n "$LOG_CSV" ]] && msg_info "CSV log: $LOG_CSV"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    msg_warn "Execution: DRY-RUN (no changes will be written)"
  else
    msg_warn "Execution: LIVE"
  fi
  if [[ "$EXPORT_MODE" -eq 1 ]]; then
    msg_info "Export mode: ON (list modes print CSV to stdout)"
  fi
  if [[ -n "$SOURCE_ROLE_NAME" ]]; then
    msg_info "Source role: $SOURCE_ROLE_NAME (ID: $SOURCE_ROLE_ID)"
  fi
  if [[ -n "$TARGET_ROLE_NAME" && "$MODE" != "role-users" ]]; then
    msg_info "Target role: $TARGET_ROLE_NAME (ID: $TARGET_ROLE_ID)"
  fi
  echo

  # Note: --export is informational for list modes; it has no effect on writes.
  if [[ "$EXPORT_MODE" -eq 1 ]]; then
    case "$MODE" in
      user-list|role-users) ;;  # OK
      *) msg_warn "--export has no effect on write modes." ;;
    esac
  fi

  # Dispatch to mode-specific handler.
  case "$MODE" in
    role-add|role-remove|role-move)
      while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        email="$(trim "$raw_line")"
        [[ -z "$email" ]] && continue
        if [[ "$email" == "__ERROR__" ]]; then
          IFS= read -r err || true
          die "$err"
        fi
        [[ "$email" =~ ^# ]] && continue
        process_role_change_user "$MODE" "$email" "$SOURCE_ROLE_ID" "$TARGET_ROLE_ID"
      done < <(extract_emails_from_input "$INPUT_FILE")
      ;;
    user-create|user-update)
      process_user_create_or_update_csv "$MODE" "$INPUT_FILE"
      ;;
    user-delete)
      process_user_delete_file "$INPUT_FILE"
      ;;
    user-list)
      process_user_list
      ;;
    role-users)
      process_role_users "$TARGET_ROLE_NAME"
      ;;
    role-list)
      process_role_list
      ;;
  esac

  # Only summarize for modes that can change things; list-modes are read-only.
  case "$MODE" in
    role-add|role-remove|role-move|user-create|user-update|user-delete)
      msg_header "Summary"
      msg_ok   "Planned/performed changes: $CHANGED_COUNT"
      msg_warn "Skipped: $SKIPPED_COUNT"
      msg_warn "Not found: $NOT_FOUND_COUNT"
      if [[ "$ERROR_COUNT" -gt 0 ]]; then
        msg_error "Errors: $ERROR_COUNT"
        exit 1
      else
        msg_ok "Errors: 0"
      fi
      ;;
    user-list|role-users|role-list)
      : # read-only: CSV output is the result
      ;;
  esac
}

main "$@"