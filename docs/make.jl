using Documenter, DataRegistryUtils

makedocs(sitename="[SCRC] DataRegistryUtils.jl docs")

deploydocs(
    repo = "github.com/ScottishCovidResponse/DataRegistryUtils.jl.git",
    devbranch = "main",
)
