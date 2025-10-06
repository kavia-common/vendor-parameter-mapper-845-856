(function() {
  /*
   PUBLIC_INTERFACE
   init.js
   This Mongo shell script initializes the database schema:
   - Creates collections with $jsonSchema validators
   - Creates indexes for performance and uniqueness
   - Runs idempotently (checks a marker collection and existing indexes)
   Usage:
     mongo --host localhost --port 5000 -u appuser -p dbuser123 --authenticationDatabase admin myapp init.js
  */

  function log(msg) { print(new Date().toISOString() + " - " + msg); }

  // Resolve target DB from the current connection context
  var targetDb = db.getName() || "myapp";
  log("Initializing database: " + targetDb);

  // Read schemas from filesystem
  function loadSchema(path) {
    try {
      var content = cat(path);
      return JSON.parse(content);
    } catch (e) {
      throw new Error("Failed to load schema from " + path + ": " + e.message);
    }
  }

  var schemaRoot = "vendor-parameter-mapper-845-856/vendor_parameter_mapping_database/schemas";

  var schemas = {
    vendors: loadSchema(schemaRoot + "/vendors.json"),
    standard_parameters: loadSchema(schemaRoot + "/standard_parameters.json"),
    vendor_parameters: loadSchema(schemaRoot + "/vendor_parameters.json"),
    mappings: loadSchema(schemaRoot + "/mappings.json"),
    audit_logs: loadSchema(schemaRoot + "/audit_logs.json")
  };

  // Use a marker collection to track initialization
  var markerColl = db.getSiblingDB(targetDb).getCollection("_init_markers");
  var alreadyInitialized = markerColl.findOne({ key: "schema_initialized" });

  if (alreadyInitialized) {
    log("Initialization previously completed at: " + alreadyInitialized.completed_at);
    log("Ensuring indexes exist and re-applying validators if needed...");
  } else {
    log("No initialization marker found. Proceeding with first-time setup.");
  }

  // Helper to create or update collection with validator
  function ensureCollectionWithValidator(name, schema) {
    var exists = db.getCollectionNames().indexOf(name) !== -1;

    if (!exists) {
      log("Creating collection: " + name);
      db.createCollection(name, { validator: { $jsonSchema: schema.$jsonSchema }, validationLevel: "moderate" });
    } else {
      log("Collection exists: " + name + " - applying validator (collMod)");
      db.runCommand({
        collMod: name,
        validator: { $jsonSchema: schema.$jsonSchema },
        validationLevel: "moderate"
      });
    }
  }

  // Ensure collections and validators
  ensureCollectionWithValidator("vendors", schemas.vendors);
  ensureCollectionWithValidator("standard_parameters", schemas.standard_parameters);
  ensureCollectionWithValidator("vendor_parameters", schemas.vendor_parameters);
  ensureCollectionWithValidator("mappings", schemas.mappings);
  ensureCollectionWithValidator("audit_logs", schemas.audit_logs);

  // Index helpers
  function ensureIndex(coll, keys, options) {
    options = options || {};
    // Build a descriptive name if not provided
    if (!options.name) {
      var nameParts = [];
      for (var k in keys) {
        nameParts.push(k + "_" + keys[k]);
      }
      options.name = nameParts.join("_");
    }
    var existing = db.getCollection(coll).getIndexes()
      .map(function(i) { return i.name; });
    if (existing.indexOf(options.name) === -1) {
      log("Creating index on " + coll + ": " + options.name + " keys=" + tojson(keys));
      db.getCollection(coll).createIndex(keys, options);
    } else {
      log("Index already exists on " + coll + ": " + options.name);
    }
  }

  // vendors: unique indexes on name and code
  ensureIndex("vendors", { name: 1 }, { unique: true, name: "uniq_name" });
  ensureIndex("vendors", { code: 1 }, { unique: true, name: "uniq_code" });

  // standard_parameters: text index on name and description; index on category
  ensureIndex("standard_parameters", { name: "text", description: "text" }, { name: "text_name_description" });
  ensureIndex("standard_parameters", { category: 1 }, { name: "idx_category" });
  // also often helpful: unique on key
  ensureIndex("standard_parameters", { key: 1 }, { unique: true, name: "uniq_key" });

  // vendor_parameters: unique compound index {vendor_id: 1, name: 1}; text index on name and description
  ensureIndex("vendor_parameters", { vendor_id: 1, name: 1 }, { unique: true, name: "uniq_vendor_name" });
  ensureIndex("vendor_parameters", { name: "text", description: "text" }, { name: "text_name_description" });
  ensureIndex("vendor_parameters", { vendor_id: 1 }, { name: "idx_vendor_id" });

  // mappings: unique compound index {vendor_id: 1, vendor_param_id: 1, standard_param_id: 1}; indexes on vendor_id, vendor_param_id, standard_param_id; created_at desc
  ensureIndex("mappings", { vendor_id: 1, vendor_param_id: 1, standard_param_id: 1 }, { unique: true, name: "uniq_vendor_vendorparam_standardparam" });
  ensureIndex("mappings", { vendor_id: 1 }, { name: "idx_vendor_id" });
  ensureIndex("mappings", { vendor_param_id: 1 }, { name: "idx_vendor_param_id" });
  ensureIndex("mappings", { standard_param_id: 1 }, { name: "idx_standard_param_id" });
  ensureIndex("mappings", { created_at: -1 }, { name: "idx_created_at_desc" });

  // audit_logs: index on created_at desc; optional compound index on entity and entity_id
  ensureIndex("audit_logs", { created_at: -1 }, { name: "idx_created_at_desc" });
  ensureIndex("audit_logs", { entity: 1, entity_id: 1 }, { name: "idx_entity_entity_id" });

  if (!alreadyInitialized) {
    markerColl.insertOne({
      key: "schema_initialized",
      completed_at: new Date(),
      version: 1
    });
    log("Initialization marker inserted.");
  } else {
    markerColl.updateOne(
      { key: "schema_initialized" },
      { $set: { checked_at: new Date() }, $inc: { runs: 1 } },
      { upsert: true }
    );
    log("Initialization marker updated.");
  }

  log("Database initialization finished successfully.");
  // Explicit success
  quit(0);
})();
