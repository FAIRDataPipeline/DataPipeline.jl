using Documenter, DataPipeline

makedocs(sitename="FAIRDataPipeline DataPipeline.jl docs")

deploydocs(
    repo = "github.com/FAIRDataPipeline/DataPipeline.jl.git",
    devbranch = "main",
)
