"""
    DataPipeline package

The `DataPipeline` package provides a language-specific automation layer for the  
language-agnostic RESTful API that is used to interact with the Data Registry.
"""

module DataPipeline

const C_DEBUG_MODE = false
const LOCAL_DR_STEM = "http://localhost"
const API_ROOT = string(LOCAL_DR_STEM, ":8000", "/api/")
const SL_ROOT = string(API_ROOT, "storage_location/")
FDP_CONFIG_DIR() = get(ENV, "FDP_CONFIG_DIR", ".")
@static if Sys.iswindows()
    const FDP_SUBMISSION_SCRIPT = "script.bat"
else
    const FDP_SUBMISSION_SCRIPT = "script.sh"
end
const FDP_CONFIG_FILE = "config.yaml"

include("core.jl")

include("api.jl")
export link_read!, link_write!
export read_array, read_table, read_distribution, read_estimate
export write_array, write_table, write_distribution, write_estimate
export raise_issue

include("fdp_i.jl")

include("data_prod_proc.jl")    # dp file handling
include("api_audit.jl")         # DR audits

include("testing.jl")

# ---- SEIRS model ----
module SEIRSModel

include("model.jl")
export modelseirs, plotseirs, getparameter

end 

end 
