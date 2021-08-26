
library(devtools)
install_github("FAIRDataPipeline/rFDP")
library(rFDP)

path = '/media/martin/storage/projects/AtomProjects/DataPipeline.jl/docs/validation/a.tml'
x = configr::read.config(file = path)
x$`asymptomatic-period`
x$`asymptomatic-period2`
