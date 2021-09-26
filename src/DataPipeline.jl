"""
    DataPipeline package

The `DataPipeline` package provides a language-specific automation layer for the  
language-agnostic RESTful API that is used to interact with the Data Registry.
"""

module DataPipeline

using YAML
using HTTP
using JSON
using FTPClient
using SHA
using Dates
using CSV
using DataFrames
using URIs
using Plots

const C_DEBUG_MODE = false
const LOCAL_DR_STEM = "http://localhost"
const LOCAL_DR_PORTLESS = string(LOCAL_DR_STEM, "/api/")
const API_ROOT = string(LOCAL_DR_STEM, ":8000", "/api/")
const NS_ROOT = string(API_ROOT, "namespace/")
const STR_ROOT = string(LOCAL_DR_PORTLESS, "storage_root/")
const STR_MATCH = Regex(string(LOCAL_DR_STEM, ".*storage_root/"))
const SL_ROOT = string(LOCAL_DR_PORTLESS, "storage_location/")
const TF_ROOT = string(API_ROOT, "text_file/")
const TEST_NAMESPACE = "data_processing_test"
const DATA_OUT = "./out/"
const NULL_HASH = "na"
const NULL_FILE = "no_match"
const VERSION_LATEST = "latest"
const STR_RT_GITHUB = string(STR_ROOT, "11/")
const STR_RT_TEXTFILE = string(STR_ROOT, "203/")
const STR_RT_BOYDORR = string(STR_ROOT, "9/")
const DF_MODEL_REL_DESC = "Julia model."
const DF_MR_SUB_SCR_DESC = "Submission script."
const FILE_SR_STEM = "file://"

include("core.jl")
export getfilehash, gettoken

include("api.jl")
export initialise, finalise
export link_read!, link_write!
export read_array, read_table, read_distribution, read_estimate
export write_array, write_table, write_distribution, write_estimate
export raise_issue

include("fdp_i.jl")

include("data_prod_proc.jl")    # dp file handling
include("api_audit.jl")         # DR audits

end # module

module SeirsModel

include("model.jl")
export modelseirs, plotseirs, getparameter

end # module
