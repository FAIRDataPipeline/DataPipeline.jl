# SPDX-License-Identifier: LGPL-3.0-or-later

using Documenter
using DataPipeline

makedocs(sitename = "FAIRDataPipeline DataPipeline.jl docs",
         pages = ["index.md", "fdp_manual.md", "SEIRS.md"])

deploydocs(repo = "github.com/FAIRDataPipeline/DataPipeline.jl.git",
           devbranch = "main",
           devurl = "main")
