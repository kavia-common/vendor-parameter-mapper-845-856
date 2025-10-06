#!/usr/bin/env bash
# MongoDB startup and initialization script (idempotent)
# - Waits for mongod to be available
# - Ensures admin/app users exist
# - Executes init.js only if needed (marker/index check)
# - Safe to re-run multiple times

set -euo pipefail

DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_PORT="${DB_PORT:-5000}"
MONGO_HOST="${MONGO_HOST:-localhost}"

echo "[startup] Starting MongoDB setup for DB=${DB_NAME} on ${MONGO_HOST}:${DB_PORT}..."

# Determine if mongod is already running and reachable
if mongosh --host "${MONGO_HOST}" --port "${DB_PORT}" --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
  echo "[startup] MongoDB reachable at ${MONGO_HOST}:${DB_PORT}"
else
  echo "[startup] MongoDB not reachable; attempting local launch on port ${DB_PORT}..."

  # If mongod is already running on another port, don't kill it; just proceed to wait for the target port
  # Start a local mongod if one is not running on the desired port
  if ! pgrep -x mongod >/dev/null 2>&1; then
    echo "[startup] Launching mongod..."
    nohup mongod --dbpath /var/lib/mongodb --port "${DB_PORT}" --bind_ip 127.0.0.1 > /var/lib/mongodb/mongod.log 2>&1 &
    sleep 1
  fi

  echo "[startup] Waiting for MongoDB to start on ${DB_PORT}..."
  for i in {1..60}; do
    if mongosh --host "${MONGO_HOST}" --port "${DB_PORT}" --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
      echo "[startup] MongoDB is ready."
      break
    fi
    echo "[startup] Waiting... ($i/60)"
    sleep 1
  done
fi

# Ensure users exist (idempotent). We treat DB_USER as an admin-like user for convenience and also create appuser on target DB.
echo "[startup] Ensuring users exist..."
mongosh --host "${MONGO_HOST}" --port "${DB_PORT}" --quiet <<'EOF'
const env = (k, d) => (typeof process !== 'undefined' && process.env[k]) ? process.env[k] : d;
const DB_NAME   = env('DB_NAME', 'myapp');
const DB_USER   = env('DB_USER', 'appuser');
const DB_PASS   = env('DB_PASSWORD', 'dbuser123');

function ensureAdminUser() {
  db.getSiblingDB('admin');
  const exists = db.getUser(DB_USER);
  if (!exists) {
    db.createUser({
      user: DB_USER,
      pwd: DB_PASS,
      roles: [
        { role: 'userAdminAnyDatabase', db: 'admin' },
        { role: 'readWriteAnyDatabase', db: 'admin' }
      ]
    });
    print(`[startup] Created admin user ${DB_USER}`);
  } else {
    print(`[startup] Admin user ${DB_USER} already exists`);
  }
}

function ensureAppUser() {
  const appDb = db.getSiblingDB(DB_NAME);
  const exists = appDb.getUser('appuser');
  if (!exists) {
    appDb.createUser({
      user: 'appuser',
      pwd: DB_PASS,
      roles: [{ role: 'readWrite', db: DB_NAME }]
    });
    print('[startup] Created DB user appuser');
  } else {
    print('[startup] DB user appuser already exists');
  }
}

ensureAdminUser();
ensureAppUser();
EOF

# Save connection string helper (optional)
echo "mongosh mongodb://${DB_USER}:${DB_PASSWORD}@${MONGO_HOST}:${DB_PORT}/${DB_NAME}?authSource=admin" > db_connection.txt
echo "[startup] Connection helper written to db_connection.txt"

# Prepare environment file for tooling
mkdir -p db_visualizer
cat > db_visualizer/mongodb.env <<EOF
export MONGODB_URL="mongodb://${DB_USER}:${DB_PASSWORD}@${MONGO_HOST}:${DB_PORT}/?authSource=admin"
export MONGODB_DB="${DB_NAME}"
EOF

# Determine if init.js needs to run by checking a marker collection and a known index presence
echo "[startup] Evaluating whether init.js needs to run..."
NEED_INIT=1
if mongosh "mongodb://${DB_USER}:${DB_PASSWORD}@${MONGO_HOST}:${DB_PORT}/${DB_NAME}?authSource=admin" --quiet --eval 'db.getCollection("_init_markers") && db._init_markers.findOne({key:"schema_initialized"}) ? print("OK") : print("MISSING")' | grep -q "OK"; then
  # Also verify a representative index exists (adjust name if your init.js creates a specific index)
  HAS_INDEX=$(mongosh "mongodb://${DB_USER}:${DB_PASSWORD}@${MONGO_HOST}:${DB_PORT}/${DB_NAME}?authSource=admin" --quiet --eval 'var names=db.vendors ? db.vendors.getIndexes().map(i=>i.name) : []; print(names.indexOf("uniq_code")>=0?"YES":"NO")')
  if [ "${HAS_INDEX}" = "YES" ]; then
    NEED_INIT=0
  fi
fi

INIT_JS_PATH="vendor-parameter-mapper-845-856/vendor_parameter_mapping_database/init.js"
if [ "${NEED_INIT}" -eq 1 ]; then
  if [ -f "${INIT_JS_PATH}" ]; then
    echo "[startup] Running init.js to initialize database schema and indexes..."
    mongo --host "${MONGO_HOST}" --port "${DB_PORT}" -u "${DB_USER}" -p "${DB_PASSWORD}" --authenticationDatabase admin "${DB_NAME}" "${INIT_JS_PATH}" || {
      rc=$?
      echo "[startup] init.js failed with exit code ${rc}"
      exit "${rc}"
    }
    echo "[startup] init.js execution complete."
  else
    echo "[startup] init.js not found at ${INIT_JS_PATH}; skipping initialization."
  fi
else
  echo "[startup] init.js skipped (already initialized)."
fi

echo "[startup] MongoDB setup complete."
echo "[startup] DB: ${DB_NAME} | Admin user: ${DB_USER} | App user: appuser | Port: ${DB_PORT}"
