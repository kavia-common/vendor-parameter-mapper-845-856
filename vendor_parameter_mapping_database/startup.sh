#!/bin/bash

# MongoDB startup and initialization script
# POSIX-compliant; starts mongod, ensures users, runs init.js idempotently

DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_PORT="${DB_PORT:-5000}"

echo "Starting MongoDB setup for DB=${DB_NAME} on port ${DB_PORT}..."

# Check if MongoDB is already running
if mongosh --port "${DB_PORT}" --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
    echo "MongoDB is already running on port ${DB_PORT}"
else
    # Check if MongoDB is running on a different port and stop it
    if pgrep -x mongod >/dev/null 2>&1; then
        MONGO_PID=$(pgrep -x mongod | head -1)
        CURRENT_PORT=$(sudo lsof -Pan -p "$MONGO_PID" -i 2>/dev/null | awk -F: '/TCP/ {print $2}' | awk '{print $1}' | head -1)
        if [ -n "$CURRENT_PORT" ] && [ "$CURRENT_PORT" != "${DB_PORT}" ]; then
            echo "MongoDB running on different port ($CURRENT_PORT). Stopping..."
            sudo pkill -x mongod
            sleep 2
        fi
    fi

    # Clean up any existing socket files
    sudo rm -f /tmp/mongodb-*.sock 2>/dev/null

    echo "Starting MongoDB server on port ${DB_PORT}..."
    nohup sudo mongod --dbpath /var/lib/mongodb --port "${DB_PORT}" --bind_ip 127.0.0.1 --unixSocketPrefix /var/run/mongodb > /var/lib/mongodb/mongod.log 2>&1 &
    echo "Waiting for MongoDB to start..."
    # Wait for MongoDB to start (max ~30s)
    i=0
    while [ $i -lt 15 ]; do
        if mongosh --port "${DB_PORT}" --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
            echo "MongoDB is ready!"
            break
        fi
        i=$((i+1))
        echo "Waiting... ($i/15)"
        sleep 2
    done
fi

# Create admin and app users (idempotent)
echo "Ensuring users exist..."
mongosh --port "${DB_PORT}" << EOF
use admin
if (db.getUser("${DB_USER}") == null) {
    db.createUser({
        user: "${DB_USER}",
        pwd: "${DB_PASSWORD}",
        roles: [
            { role: "userAdminAnyDatabase", db: "admin" },
            { role: "readWriteAnyDatabase", db: "admin" }
        ]
    });
    print("Admin user ${DB_USER} created");
} else {
    print("Admin user ${DB_USER} already exists");
}

use ${DB_NAME}
if (db.getUser("appuser") == null) {
    db.createUser({
        user: "appuser",
        pwd: "${DB_PASSWORD}",
        roles: [{ role: "readWrite", db: "${DB_NAME}" }]
    });
    print("DB user appuser created");
} else {
    print("DB user appuser already exists");
}
EOF

# Save connection command to a file
echo "mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file for db_visualizer
cat > db_visualizer/mongodb.env << EOF
export MONGODB_URL="mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/?authSource=admin"
export MONGODB_DB="${DB_NAME}"
EOF

# Run init.js idempotently
echo "Running database initialization script (init.js)..."
INIT_CMD="mongo --host localhost --port ${DB_PORT} -u ${DB_USER} -p ${DB_PASSWORD} --authenticationDatabase admin ${DB_NAME} vendor-parameter-mapper-845-856/vendor_parameter_mapping_database/init.js"
# Guard: check marker document; if not present, or if indexes missing, run script
NEED_INIT=1
mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin --quiet --eval 'db._init_markers && db._init_markers.findOne({key:"schema_initialized"}) ? print("OK") : print("MISSING")' | grep -q "OK" && NEED_INIT=0

if [ "$NEED_INIT" -eq 0 ]; then
  echo "Initialization marker found. Ensuring a key index exists as a sanity check..."
  # Quick check for one expected index; if missing, re-run init
  HAS_INDEX=$(mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin --quiet --eval 'var idx=db.vendors.getIndexes().map(i=>i.name); print(idx.indexOf("uniq_code")>=0?"YES":"NO")')
  if [ "$HAS_INDEX" != "YES" ]; then
    echo "Expected index missing; re-running init.js"
    NEED_INIT=1
  fi
fi

if [ "$NEED_INIT" -eq 1 ]; then
  echo "Executing: $INIT_CMD"
  sh -c "$INIT_CMD"
  INIT_RC=$?
  if [ $INIT_RC -ne 0 ]; then
    echo "init.js failed with exit code $INIT_RC"
    exit $INIT_RC
  fi
else
  echo "init.js execution skipped (already initialized)."
fi

echo "MongoDB setup complete!"
echo "Database: ${DB_NAME}"
echo "Admin user: ${DB_USER} (password: ${DB_PASSWORD})"
echo "App user: appuser (password: ${DB_PASSWORD})"
echo "Port: ${DB_PORT}"
echo ""
echo "Environment variables saved to db_visualizer/mongodb.env"
echo "To use with Node.js viewer, run: source db_visualizer/mongodb.env"
echo "To connect to the database, use one of the following commands:"
echo "mongosh -u ${DB_USER} -p ${DB_PASSWORD} --port ${DB_PORT} --authenticationDatabase admin ${DB_NAME}"
echo "$(cat db_connection.txt)"
echo ""
echo "MongoDB is running in the background."
echo "You can now start your application."