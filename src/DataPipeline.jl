# SPDX-License-Identifier: LGPL-3.0-or-later

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

# The registry the CLI writes into a working config when the user has not set one
const DEFAULT_REGISTRY_URL = "http://127.0.0.1:8000/api/"
const DEFAULT_API_VERSION = "1.0.0"
FDP_CONFIG_DIR() = get(ENV, "FDP_CONFIG_DIR", ".")
@static if Sys.iswindows()
    const FDP_SUBMISSION_SCRIPT = "script.bat"
else
    const FDP_SUBMISSION_SCRIPT = "script.sh"
end
FDP_PATH_CONFIG() = joinpath(FDP_CONFIG_DIR(), "config.yaml")
FDP_PATH_SUBMISSION() = joinpath(FDP_CONFIG_DIR(), FDP_SUBMISSION_SCRIPT)
FDP_LOCAL_TOKEN() = get(ENV, "FDP_LOCAL_TOKEN", "fake_token")

include("core.jl")

include("api.jl")
export link_read!, link_read_files!, link_write!
export read_array, read_table, read_distribution, read_estimate
export write_array, write_table, write_distribution, write_estimate
export raise_issue
# Supported but qualified: the code run's brackets, whose names any model
# might use itself, and the types a script names rather than calls
public initialise, finalise
public DataRegistryHandle, RegistryEndpoint
public ReadWriteException, ConfigFileException
public AbstractIssueTarget, WorkingConfig, SubmissionScript, CodeRepository
public ConfigDataProduct, ExistingDataProduct

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
