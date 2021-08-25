####  Simple examples for new FAIR version of the DP  ####
# This implements:
# https://fairdatapipeline.github.io/docs/interface/example0/
# Steps:                                                    Code:
# 0. preliminaries                                          L21
# 1. Empty code run                                         L30
# 2. Write data product (Array)                             L35
# 3. Read data product (Array)                              L46
# 4. Write data product (Tables.jl)                         L53
# 5. Read data product (Tables.jl)                          L62
# 6. Write data product (point estimate)                    L69
# 7. Read data product (point estimate)                     L76
# 8. Write data product (distribution)                      L82
# 9. Read data product (distribution)                       L88
# 10. Register issues (various)                             L95
# 11. Aliasing                                              L116
#
# Author:   Martin Burke (martin.burke@bioss.ac.uk)
# Date:     20-Jul-2021
#### #### #### #### ####

##  *** NB. REMEMBER TO UPDATE CONFIG FILE DETAILS ***  ##

## LOCAL DR INSTRUCTIONS:
# - start using: ~/.scrc/scripts/run_scrc_server
# - stop using: ~/.scrc/scripts/stop_scrc_server
# - view tcp using: sudo netstat -ntap | grep LISTEN
import DataPipeline
import CSV
import DataFrames
import Random

## 1. Empty code run
wc = "examples/simple2/working_config1.yaml"
handle = DataPipeline.initialise(wc)
DataPipeline.finalise(handle; comments="Empty code run example.")

## 2. Write data product (HDF5)
# NB. you need to update the version number in
# the config file when registering *new* data
# (hint: that includes HDF5 files with a different timestamp)
wc = "examples/simple2/working_config2.yaml"
handle = DataPipeline.initialise(wc)
Random.seed!(0)
tmp = reshape(rand(10), 2, :)       # create an array
DataPipeline.write_array(handle, tmp, "test/array", "component1/a/s/d/f/s")
DataPipeline.finalise(handle; comments="Write HDF5 example.")

## 3. Read data product (HDF5)
wc = "examples/simple2/working_config3.yaml"
handle = DataPipeline.initialise(wc)
tmp = DataPipeline.read_array(handle, "test/array", "component1/a/s/d/f/s")
println("ARRAY: ", tmp)
DataPipeline.finalise(handle; comments="Read HDF5 example.")

## 4. Write data product (csv)
wc = "examples/simple2/working_config4.yaml"
handle = DataPipeline.initialise(wc)
# println(typeof(handle.config["write"][1]["use"]["public"]))
# println(typeof(handle.config["write"][1]["use"]["public2"]))
tmp = CSV.read("examples/register/tbl.csv", DataFrames.DataFrame)
DataPipeline.write_table(handle, tmp, "test/csv")
DataPipeline.finalise(handle; comments="Write CSV example.")

## 5. Read data product (csv)
wc = "examples/simple2/working_config5.yaml"
handle = DataPipeline.initialise(wc)
tmp = DataPipeline.read_table(handle, "test/csv")
println("TABLE: ", DataFrames.first(tmp, 3))
DataPipeline.finalise(handle; comments="Read CSV example.")

## 6. Write data product (point estimate)
wc = "examples/simple2/working_config6.yaml"
handle = DataPipeline.initialise(wc)
DataPipeline.write_estimate(handle, 222822951599, "test/estimate/asymptomatic-period", "asymptomatic-period")
DataPipeline.finalise(handle; comments="Write point estimate example.")

## 7. Read data product (point estimate)
wc = "examples/simple2/working_config7.yaml"
handle = DataPipeline.initialise(wc)
tmp = DataPipeline.read_estimate(handle, "test/estimate/asymptomatic-period", "asymptomatic-period")
println("nb. read estimate := ", tmp)
DataPipeline.finalise(handle; comments="Read point estimate example.")

## 8. Write data product (distribution)
wc = "examples/simple2/working_config8.yaml"
handle = DataPipeline.initialise(wc)
DataPipeline.write_distribution(handle, "Gaussian", Dict("mean" => -16.08, "SD" => 30), "test/distribution/symptom-delay", "symptom-delay")
DataPipeline.finalise(handle; comments="Write distribution example.")

## 9. Read data product (distribution)
wc = "examples/simple2/working_config9.yaml"
handle = DataPipeline.initialise(wc)
tmp = DataPipeline.read_distribution(handle, "test/distribution/symptom-delay", "symptom-delay")
println("nb. read distribution := ", tmp)
DataPipeline.finalise(handle; comments="Read distribution example.")

## 10. Register issues
wc = "examples/simple2/working_config10.yaml"
component_name = "component1/a/s/d/f/s"
handle = DataPipeline.initialise(wc)
# - write component
tmp = reshape(rand(10), 2, :)       # create an array
url = DataPipeline.write_array(handle, tmp, "test/array/issues/component", component_name)
comp_url = DataPipeline.get_object_components(url)[2]
urls = DataPipeline.finalise(handle)
# - raise issue: component
DataPipeline.raise_issue(handle, comp_url, "Some issue with a component.", 7)
# - data product
DataPipeline.raise_issue(handle, url, "Some issue with a data product.", 7)
# - config
DataPipeline.raise_issue(handle, urls.config_obj, "Some issue with a config file.", 7)
# - ss
DataPipeline.raise_issue(handle, urls.script_obj, "Some issue with a submission script.", 7)
# - GitHub repo (object)
DataPipeline.raise_issue(handle, urls.repo_obj, "Some issue with a [remote] repo.", 7)

## 11. Aliasing (TBC)
wc = "examples/simple2/working_config11.yaml"
handle = DataPipeline.initialise(wc)
tmp = CSV.read("examples/register/tbl.csv", DataFrames.DataFrame)
DataPipeline.write_table(handle, tmp, "human/outbreak-timeseries")
DataPipeline.finalise(handle)

## TBA? : Delete
# - data product
# - code run
