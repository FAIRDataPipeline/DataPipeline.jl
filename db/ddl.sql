const DDL_SQL = """
CREATE TABLE IF NOT EXISTS session(
	sn_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	data_dir	TEXT NOT NULL,
	pkg_version TEXT NOT NULL,
	row_added TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS access_log(
	log_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	offline_mode INTEGER NOT NULL,
	row_added TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
	log_finished TIMESTAMP
);
CREATE TABLE IF NOT EXISTS access_log_data(
	log_id	INTEGER NOT NULL,
	dp_id	INTEGER NOT NULL,
	comp_id	INTEGER
);

CREATE TABLE IF NOT EXISTS data_product(
	dp_id	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	namespace TEXT NOT NULL,
	dp_name	TEXT NOT NULL,
	filepath	TEXT NOT NULL,
	dp_hash	TEXT NOT NULL,
	dp_version TEXT NOT NULL,
	sr_url TEXT,
	sl_path TEXT,
	description TEXT,
	registered INTEGER DEFAULT 0,
	dp_url TEXT,
	row_added TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);
CREATE TABLE IF NOT EXISTS component(
	comp_id	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	dp_id	INTEGER NOT NULL,
	comp_name TEXT NOT NULL,
	comp_type TEXT NOT NULL,
	meta_src INTEGER NOT NULL,
	data_obj TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS toml_keyval(
	comp_id	INTEGER NOT NULL,
	key	TEXT NOT NULL,
	val	TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS code_repo_rel(
	crr_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	crr_name TEXT NOT NULL,
	crr_version TEXT NOT NULL,
	crr_repo TEXT NOT NULL,
	crr_hash TEXT NOT NULL,
	crr_desc TEXT,
	crr_website TEXT,
	storage_root_url NOT NULL,
	storage_root_id NOT NULL,
	registered INTEGER DEFAULT 0,
	crr_url TEXT,
	row_added TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);
CREATE TABLE IF NOT EXISTS code_run(
	run_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	crr_id INTEGER NOT NULL,
	model_config TEXT NOT NULL,
	run_desc TEXT NOT NULL,
	ss_text TEXT NOT NULL,
	registered INTEGER DEFAULT 0,
	run_url TEXT,
	row_added TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

DROP VIEW IF EXISTS session_view;
DROP VIEW IF EXISTS dpc_view;
DROP VIEW IF EXISTS toml_view;
DROP VIEW IF EXISTS total_runs_staging;
DROP VIEW IF EXISTS total_runs_registry;
DROP VIEW IF EXISTS crr_view;
DROP VIEW IF EXISTS component_view;
DROP VIEW IF EXISTS log_component_view;

CREATE VIEW session_view AS
SELECT * FROM session
WHERE sn_id=(SELECT max(sn_id) FROM session);

CREATE VIEW dpc_view AS
SELECT d.namespace, d.dp_name, d.dp_version
, d.filepath, c.*
FROM data_product d
INNER JOIN component c ON(d.dp_id = c.dp_id);

CREATE VIEW toml_view AS
SELECT d.namespace, d.dp_name, d.dp_version
, t.*, k.key, k.val
FROM data_product d
INNER JOIN component t ON(d.dp_id = t.dp_id)
INNER JOIN toml_keyval k ON(t.comp_id = k.comp_id);

CREATE VIEW total_runs_staging AS
SELECT crr_id, count(run_id) AS staged_runs
FROM code_run WHERE registered=FALSE
GROUP BY crr_id;

CREATE VIEW total_runs_registry AS
SELECT crr_id, count(run_id) AS registered_runs
FROM code_run WHERE registered=TRUE
GROUP BY crr_id;

CREATE VIEW crr_view AS
SELECT c.crr_id AS staging_id, crr_name AS name, crr_version AS version
, registered, crr_repo AS repo, row_added
, IFNULL(s.staged_runs,0) AS staged_runs
, IFNULL(r.registered_runs,0) AS registered_runs
FROM code_repo_rel c
LEFT OUTER JOIN total_runs_staging s ON(c.crr_id=s.crr_id)
LEFT OUTER JOIN total_runs_registry r ON(c.crr_id=r.crr_id);

CREATE VIEW log_component_view AS
SELECT DISTINCT l.log_id, dp.namespace, dp.dp_name, dp.dp_version, c.comp_name
FROM access_log_data l
INNER JOIN data_product dp ON(l.dp_id=dp.dp_id)
INNER JOIN component c ON(l.dp_id=c.dp_id AND l.comp_id=c.comp_id);
"""
