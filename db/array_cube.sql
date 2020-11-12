DROP TABLE IF EXISTS data_product;
DROP TABLE IF EXISTS toml_component;
DROP TABLE IF EXISTS toml_keyval;

-- WIP
CREATE TABLE h5_array(
	arr_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	dp_id	INTEGER NOT NULL,
	tbl_cube TEXT NOT NULL
);
CREATE TABLE arr_dim(
	dim_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	arr_id INTEGER NOT NULL,
	dim_title TEXT NOT NULL
);
CREATE TABLE arr_dim_name(
	dim_name_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
	dim_id INTEGER NOT NULL,
	dim_key INTEGER NOT NULL,
	dim_val TEXT NOT NULL
);