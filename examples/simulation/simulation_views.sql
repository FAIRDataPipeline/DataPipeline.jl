DROP VIEW IF EXISTS scottish_population_view;
CREATE VIEW scottish_population_view AS
SELECT age_groups
, CAST(substr(age_groups, 4, 5) AS INT) AS age
, (CAST(substr(age_groups, 4, 5) AS INT) / 10) * 10 AS age_aggr
, CAST(substr(grid_area, 1, instr(grid_area, '-') - 1) AS INT) AS grid_x
, CAST(substr(grid_area, instr(grid_area, '-') + 1) AS INT) AS grid_y
, val
FROM km_age_persons_arr;
