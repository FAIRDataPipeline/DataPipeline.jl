DROP VIEW IF EXISTS toml_view;

CREATE VIEW toml_view AS
SELECT d.dp_name, t.comp_name, k.key, k.val
FROM data_product d
INNER JOIN toml_component t ON(d.dp_id = t.dp_id)
INNER JOIN toml_keyval k ON(t.comp_id = k.comp_id);
