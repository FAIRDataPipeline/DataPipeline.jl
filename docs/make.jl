using Documenter, DataPipeline

makedocs(sitename="[SCRC] DataPipeline.jl docs")

deploydocs(
    repo = "github.com/FAIRDataPipeline/DataPipeline.jl.git",
    devbranch = "main",
)
