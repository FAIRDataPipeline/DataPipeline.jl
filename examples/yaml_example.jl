import DataRegistryUtils


#### loading data ####

TEST_FILE = "/home/martin/AtomProjects/DataRegistryUtils.jl/examples/data_config.yaml"
DATA_OUT = "/home/martin/AtomProjects/DataRegistryUtils.jl/out/"
data = DataRegistryUtils.fetch_data_per_yaml(TEST_FILE, DATA_OUT, false)
# - hint: use 'true' for verbose processing output in the console


#### examples for usage ####

# - access data product by name
println("\nExample one - access data product / component by name:")
dp = data["human/infection/SARS-CoV-2/symptom-delay"]
println(" ", dp)
println(" - e.g. distribution name: ", dp["symptom-delay"]["distribution"])

# - loop through Dict of data products
println("\n\nExample two - loop through Dict of data products:")
data_product_names = collect(keys(data))
for i in eachindex(data_product_names)
    println("\n data product: ", data_product_names[i])
    println(" - components: ", collect(keys(data[data_product_names[i]])))
end
# - hint: you can use the same approach to loop through any Dict()
#           e.g. individual components of a data product
