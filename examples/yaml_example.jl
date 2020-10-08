import DataRegistryUtils

##
TEST_FILE = "/home/martin/AtomProjects/DataRegistryUtils.jl/examples/yaml_example.jl"
DATA_OUT = "/home/martin/AtomProjects/DataRegistryUtils.jl/out/"
d = YAML.load_file(TEST_FILE)
println(d)
DataRegistryUtils.proc_yaml(d, DATA_OUT)
