const DDL_SQL = """
CREATE TABLE IF NOT EXISTS data_product(
	dp_id	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	dp_name	TEXT NOT NULL,
	dp_path	TEXT NOT NULL,
	dp_hash	TEXT NOT NULL,
	dp_version TEXT NOT NULL,
	added TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);
CREATE TABLE IF NOT EXISTS h5_component(
	comp_id	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	dp_id	INTEGER NOT NULL,
	meta_src INTEGER NOT NULL,
	comp_type TEXT NOT NULL,
	data_obj TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS toml_component(
	comp_id	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	dp_id	INTEGER NOT NULL,
	comp_name	TEXT
);
CREATE TABLE IF NOT EXISTS toml_keyval(
	comp_id	INTEGER NOT NULL,
	key	TEXT NOT NULL,
	val	TEXT NOT NULL
);

DROP VIEW IF EXISTS h5_view;
DROP VIEW IF EXISTS toml_view;

CREATE VIEW h5_view AS
SELECT d.dp_name, d.dp_path, c.*
FROM data_product d
INNER JOIN h5_component c ON(d.dp_id = c.dp_id);

CREATE VIEW toml_view AS
SELECT d.dp_name, t.*, k.key, k.val
FROM data_product d
INNER JOIN toml_component t ON(d.dp_id = t.dp_id)
INNER JOIN toml_keyval k ON(t.comp_id = k.comp_id);
"""
