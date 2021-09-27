"""
    DataPipeline package

The `DataPipeline` package provides a language-specific automation layer for the  
language-agnostic RESTful API that is used to interact with the Data Registry.
"""

module DataPipeline

using CSV
using DataFrames
using Dates
using FTPClient
using HTTP
using JSON
using Plots
using SHA
using YAML
using URIs

const C_DEBUG_MODE = false
const LOCAL_DR_STEM = "http://localhost"
const LOCAL_DR_PORTLESS = string(LOCAL_DR_STEM, "/api/")
const STR_ROOT = string(LOCAL_DR_PORTLESS, "storage_root/")
const API_ROOT = string(LOCAL_DR_STEM, ":8000", "/api/")
const SL_ROOT = string(LOCAL_DR_PORTLESS, "storage_location/")
const DATA_OUT = "./out/"

include("core.jl")

include("api.jl")
export initialise, finalise
export link_read!, link_write!
export read_array, read_table, read_distribution, read_estimate
export write_array, write_table, write_distribution, write_estimate
export raise_issue

include("fdp_i.jl")

include("data_prod_proc.jl")    # dp file handling
include("api_audit.jl")         # DR audits

include("testing.jl")

# ---- SEIRS model ----
module SeirsModel

include("model.jl")
export modelseirs, plotseirs, getparameter

end 

end 
