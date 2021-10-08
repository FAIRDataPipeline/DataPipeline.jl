using Documenter
using DataPipeline

makedocs(sitename="FAIRDataPipeline DataPipeline.jl docs", pages = ["index.md", "fdp_manual.md"])

deploydocs(repo = "github.com/FAIRDataPipeline/DataPipeline.jl.git",
           devbranch = "main")
