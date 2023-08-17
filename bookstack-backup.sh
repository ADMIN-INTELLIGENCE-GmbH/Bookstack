#!/bin/bash

# Directory to store backups within
# Should not end with a slash and not be stored within
# the BookStack directory
BACKUP_ROOT_DIR="$HOME"

# Directory of the BookStack install
# Should not end with a slash.
BOOKSTACK_DIR="/var/www/bookstack"

# Get database options from BookStack .env file
export $(cat "$BOOKSTACK_DIR/.env" | grep ^DB_ | xargs)

# Create an export name and location
DATE=$(date "+%Y-%m-%d_%H-%M-%S")
BACKUP_NAME="bookstack_backup_$DATE"
BACKUP_DIR="$BACKUP_ROOT_DIR/$BACKUP_NAME"
mkdir -p "$BACKUP_DIR"

# Dump database to backup dir using the values
# we got from the BookStack .env file.
mysqldump --single-transaction \
 --no-tablespaces \
 -u "$DB_USERNAME" \
 -p"$DB_PASSWORD" \
 "$DB_DATABASE" > "$BACKUP_DIR/database.sql"

# Create backup archive
tar -zcf "$BACKUP_DIR.tar.gz" \
 "$BOOKSTACK_DIR/.env" \
 "$BOOKSTACK_DIR/storage/uploads" \
 "$BOOKSTACK_DIR/public/uploads" \
 "$BOOKSTACK_DIR/themes" \
 "$BACKUP_DIR/database.sql"

# Cleanup non-archive directory
rm -rf "$BACKUP_DIR"

echo "Backup complete, archive stored at:"
echo "$BACKUP_DIR.tar.gz"
