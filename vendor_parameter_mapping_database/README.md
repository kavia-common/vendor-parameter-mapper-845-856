# Vendor Parameter Mapping Database (MongoDB)

This container provides a MongoDB database for storing vendors, standard parameters, vendor parameters, mappings, and audit logs.

Environment assumptions:
- MongoDB listens on port 5000
- Admin credentials: user appuser, password dbuser123 (authSource admin)
- Default application database: myapp

You can override with environment variables:
- DB_NAME (default: myapp)
- DB_USER (default: appuser)
- DB_PASSWORD (default: dbuser123)
- DB_PORT (default: 5000)

Initialization flow:
- startup.sh starts mongod (if not already running), creates users, and then runs init.js
- init.js connects using the admin user and applies:
  - Collection creation with MongoDB $jsonSchema validators
  - Indexes for uniqueness, search, and query performance
  - A marker document in the _init_markers collection for idempotency
- startup.sh guards repeated runs and re-applies schema if required

Manual execution:
mongo --host localhost --port 5000 -u appuser -p dbuser123 --authenticationDatabase admin myapp vendor-parameter-mapper-845-856/vendor_parameter_mapping_database/init.js

Connection details for backend:
- Connection string: mongodb://appuser:dbuser123@localhost:5000/?authSource=admin
- Database name: myapp
Set in backend environment:
- MONGODB_URL=mongodb://appuser:dbuser123@localhost:5000/?authSource=admin
- DB_NAME=myapp

Collections and key indexes:
1. vendors
   - Validator: schemas/vendors.json
   - Unique indexes: name, code

2. standard_parameters
   - Validator: schemas/standard_parameters.json
   - Unique index: key
   - Text index: name + description
   - Index: category

3. vendor_parameters
   - Validator: schemas/vendor_parameters.json
   - Unique compound index: { vendor_id: 1, name: 1 }
   - Text index: name + description
   - Index: vendor_id

4. mappings
   - Validator: schemas/mappings.json
   - Unique compound index: { vendor_id: 1, vendor_param_id: 1, standard_param_id: 1 }
   - Indexes: vendor_id, vendor_param_id, standard_param_id, created_at (desc)

5. audit_logs
   - Validator: schemas/audit_logs.json
   - Indexes: created_at (desc), { entity: 1, entity_id: 1 }

Notes:
- Validators use MongoDB 4.4+ JSON Schema dialect
- Scripts are POSIX-compliant

Quick start:
- Run vendor_parameter_mapping_database/startup.sh
- Source db_visualizer/mongodb.env to use the simple DB viewer
- Use db_connection.txt for a ready-to-run mongosh command
