# BookStack User & Role Management via API

Bash utility to manage [BookStack](https://www.bookstackapp.com/) users and roles via the official REST API. It supports:

- Adding, removing and moving users between roles
- Creating users from CSV
- Updating existing users from CSV
- Deleting users from TXT or CSV
- Listing all users with their roles
- Listing users that have a given role

The script uses API tokens via the header `Authorization: Token <id>:<secret>`, as documented in the BookStack API reference.

> **Status:** Tested against the user and role endpoints of the BookStack API. Requires a user with the `Access System API` permission.

---

## Features

- **Role operations**:
  - `role-add` – add users to a target role (TXT or CSV input)
  - `role-remove` – remove users from a source role (TXT or CSV input)
  - `role-move` – move users from a source role to a target role (TXT or CSV input)

- **User operations**:
  - `user-create` – create users from a semicolon‑separated CSV file
  - `user-update` – update existing users from a semicolon‑separated CSV file
  - `user-delete` – delete users based on a TXT or CSV file

- **Listing / export**:
  - `user-list` – list all users with their roles (semicolon CSV to stdout)
  - `role-users` – list users that have a given role (semicolon CSV to stdout)
  - `role-list` – list all roles (semicolon CSV to stdout)

- **Safety & tooling**:
  - `--dry-run` to simulate changes without writing anything
  - `--export` to mark runs that are used purely for export (list modes)
  - `--log-csv` to write a detailed audit log
  - API preflight check (`/api/users?count=1`) before doing any work

CSV parsing is done with Python’s `csv.DictReader` using `delimiter=';'`, which is well‑suited for locales where Excel/LibreOffice export semicolon‑separated CSV files.

---

## Requirements

**System tools**

- `bash`
- `curl`
- `jq`
- `python3` (for CSV parsing and password generation)

**BookStack**

- A running BookStack instance
- An API token created in a user profile with the `Access System API` permission
- Network access from the system running the script to the BookStack API endpoint

---

## Installation

Clone this repository and make the script executable:

```bash
git clone https://github.com/ADMIN-INTELLIGENCE-GmbH/Bookstack.git
cd Bookstack/user_management
chmod +x bookstack-manage-users.sh
```

---

## Configuration

Set the following environment variables before running the script:

```bash
export BOOKSTACK_URL="http://127.0.0.1"
export BOOKSTACK_TOKEN_ID="YOUR_TOKEN_ID"
export BOOKSTACK_TOKEN_SECRET="YOUR_TOKEN_SECRET"
```

- `BOOKSTACK_URL`  
  Base URL of the BookStack instance for API requests.  
  Defaults to `http://127.0.0.1`, which is ideal when running directly on the BookStack server behind a reverse proxy.

- `BOOKSTACK_TOKEN_ID` / `BOOKSTACK_TOKEN_SECRET`  
  API token ID and secret from the BookStack user profile.

Before each run, the script performs a preflight request to `/api/users?count=1` to verify URL, token and permissions.

---

## Usage

Basic syntax:

```bash
./bookstack-manage-users.sh [global options] <mode> [mode arguments]
```

### Global options

- `--dry-run`  
  Simulate all actions without performing any write operations.

- `--yes`  
  Automatically confirm destructive actions (especially `user-delete`).

- `--log-csv <file.csv>`  
  Write a CSV log containing timestamp, mode, status, user and role data, and JSON payload for each processed entry.

- `--export`  
  Mark the run as an export. Intended for list modes (`user-list`, `role-users`) where semicolon CSV is printed to stdout. Has no effect on write modes.

- `-h`, `--help`, `-?`  
  Show built‑in CLI help.

---

## Input Formats

### TXT files

TXT files contain **one email address per line**. Empty lines and lines starting with `#` are ignored. This format is supported by:

- `role-add`
- `role-remove`
- `role-move`
- `user-delete`

Example:

```text
max.mustermann@example.com
erika.musterfrau@example.com
# comment line
third.user@example.com
```

### CSV files (semicolon-separated)

All CSV files are parsed as **semicolon‑separated** using `csv.DictReader(..., delimiter=';')`.

#### CSV for `user-create` / `user-update`

Expected header:

```text
name;email;password;roles
```

Example:

```csv
name;email;password;roles
Max Mustermann;max.mustermann@example.com;Start123!;"Staff,Wiki-Reader"
Erika Musterfrau;erika.musterfrau@example.com;;"Editors"
```

Rules:

- `name` – user’s display name.
- `email` – plain email address (no markdown, no `mailto:`).
- `password` – plain password:
  - For `user-create`: If empty, the script generates a strong password automatically.
  - For `user-update`: If empty, the existing password is left unchanged.
- `roles` – comma‑separated list of **role names** (not IDs), e.g. `"Staff,Wiki-Reader"`.

If `roles` contains multiple roles, the field must be quoted to keep the comma as part of the field (standard CSV convention).

#### CSV for `role-add` / `role-remove` / `role-move` / `user-delete`

For these email‑based modes, only an `email` column is required; additional columns are ignored.

Example:

```csv
email
max.mustermann@example.com
erika.musterfrau@example.com
```

The script extracts the first valid email from `email` using a regular expression, which makes it robust against accidentally copied markdown or HTML.

---

## Modes and Behavior

### `role-add`

Add users to a target role.

```bash
./bookstack-manage-users.sh role-add "Editors" users.txt
./bookstack-manage-users.sh role-add "Editors" users.csv
```

- Accepts TXT or CSV.
- For CSV, only the `email` column is used.
- The target role is resolved by display name to its role ID via the roles API.
- Existing roles are preserved; the target role is added if missing.

### `role-remove`

Remove users from a source role.

```bash
./bookstack-manage-users.sh role-remove "Wiki-Reader" users.csv
```

- Accepts TXT or CSV.
- Removes the specified role from each user if present.
- Other roles remain unchanged.

### `role-move`

Move users from one role to another.

```bash
./bookstack-manage-users.sh role-move "External" "Staff" users.txt
```

- Accepts TXT or CSV.
- Source and target roles must exist.
- Removes the source role and adds the target role for each user.

### `role-users`

List users that have a given role.

```bash
./bookstack-manage-users.sh --export role-users "Editors" > editors-users.csv
```

Behavior:

- Read‑only mode.
- Resolves the given role name to a role ID.
- Outputs a semicolon‑separated CSV with `id;name;email;roles` for all users that have that role.

### `role-list`

List all roles.

```bash
./bookstack-manage-users.sh --export role-list > roles.csv
```

Behavior:

- Read‑only mode.
- Outputs a semicolon‑separated CSV with columns: `id;name;description`.
- `name` is the role display name, `description` is the optional role description from BookStack.

### `user-create`

Create users from CSV (semicolon-separated).

```bash
./bookstack-manage-users.sh user-create users.csv
```

Behavior:

- Only CSV input is accepted.
- If `password` is empty, a strong password is generated (letters, digits, special characters).
- Roles:
  - Role names are resolved to role IDs.
  - If **none** of the requested roles exist, the user is still created but with **no extra roles**.
  - That case is logged with status `success_no_roles` so you can find these users later.

### `user-update`

Update existing users from CSV.

```bash
./bookstack-manage-users.sh user-update users.csv
```

Behavior:

- Only CSV input is accepted.
- Users are matched by `email` via the `/api/users` list endpoint.
- If `password` is empty, the existing password is kept.
- Roles:
  - If `roles` is empty, role assignments are not changed.
  - If `roles` is provided and **none** of the listed roles exist in BookStack, the update for that user is **aborted** to avoid losing valid roles.

### `user-delete`

Delete users from TXT or CSV.

```bash
./bookstack-manage-users.sh --yes user-delete users.txt
./bookstack-manage-users.sh --yes user-delete users.csv
```

Behavior:

- Accepts TXT or CSV.
- For CSV, only the `email` column is read.
- Each email is resolved to a user ID; deletion is done via `/api/users/{id}`.
- A confirmation prompt is shown unless `--yes` or `--dry-run` is used.

### `user-list`

List all users with their roles.

```bash
./bookstack-manage-users.sh --export user-list > all-users.csv
```

Behavior:

- Read‑only mode.
- Outputs a semicolon‑separated CSV with columns: `id;name;email;roles`.
- `roles` is a comma‑separated list of role display names for each user.

---

## Dry-Run and Logging

### Dry run

```bash
./bookstack-manage-users.sh --dry-run role-move "External" "Staff" users.csv
```

- No write operations are performed.
- All planned changes and payloads are printed.
- Useful for testing large imports or role migrations.

### CSV logging

```bash
./bookstack-manage-users.sh --log-csv audit.csv user-update users.csv
```

The log CSV contains:

- Timestamp
- Mode
- Target (e.g. file or email)
- Status (`success`, `dry_run`, `skipped`, `not_found`, `error`, `success_no_roles`)
- Message
- User name
- Email
- User ID
- Roles before / after (where applicable)
- JSON payload

The log is CSV-escaped, so it can be opened in Excel/LibreOffice or imported into other tools.

---

## Examples

Create users from a semicolon‑separated CSV:

```bash
./bookstack-manage-users.sh user-create bookstack-users-example.csv
```

Simulate a role move from `External` to `Staff`:

```bash
./bookstack-manage-users.sh --dry-run role-move "External" "Staff" users.csv
```

Remove the `Wiki-Reader` role and log all actions:

```bash
./bookstack-manage-users.sh --log-csv role-changes.csv role-remove "Wiki-Reader" users.csv
```

Delete users defined in a CSV file:

```bash
./bookstack-manage-users.sh --yes user-delete users.csv
```

Export all users with their roles:

```bash
./bookstack-manage-users.sh --export user-list > all-users.csv
```

Export all users that have the `Editors` role:

```bash
./bookstack-manage-users.sh --export role-users "Editors" > editors-users.csv
```

Export all roles:

```bash
./bookstack-manage-users.sh --export role-list > roles.csv
```

---

## API Details

The script uses BookStack’s API endpoints as documented in the instance’s `/api/docs` page.

Key points:

- Authentication via `Authorization: Token <token_id>:<token_secret>`.
- User lookup via `/api/users?filter[email]=...`.
- Role lookup via `/api/roles?filter[display_name]=...`.

Before executing changes, the script calls `/api/users?count=1` to verify API availability, token validity, and permissions early.

---

## Operational Notes

- When BookStack runs behind a reverse proxy or CDN, it’s often best to execute this script on the BookStack host and use `BOOKSTACK_URL=http://127.0.0.1`. This avoids extra TLS/HTTP layers for administrative automation.
- Always test with `--dry-run` before large changes, especially for `role-move` and `user-delete`.
- Consider using a service account token with limited permissions and track all runs via `--log-csv`.

---

## License

This project is licensed under the MIT License.

Each source file contains an SPDX short‑form identifier:

```text
SPDX-License-Identifier: MIT
```

Using SPDX identifiers is the recommended way to express license information in a machine‑readable manner.