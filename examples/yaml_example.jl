# import YAML
import DataRegistryUtils

##
TEST_FILE = "/home/martin/AtomProjects/DataRegistryUtils.jl/examples/data_config.yaml"
DATA_OUT = "/home/martin/AtomProjects/DataRegistryUtils.jl/out/"
DataRegistryUtils.process_yaml_file(TEST_FILE, DATA_OUT)
