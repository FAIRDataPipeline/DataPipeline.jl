# import SQLite
# import DataFrames
import HDF5
import TOML

### hdf5 file processing ###
const TABLE_OBJ_NAME = "table"

## does what it says on the tin
function read_h5_table(obj_grp)
    obj = HDF5.read(obj_grp[TABLE_OBJ_NAME])
    # println("table found:\n", obj[1])
    return obj
end

## does what it says on the tin
function read_h5_array(obj_grp)
    obj = HDF5.read(obj_grp["array"])
    # println("array found: ", sizeof(obj))
    return obj
end

## recursively search and read table/array
function process_h5_file_group!(output_dict, h5, verbose::Bool)
    gnm = HDF5.name(h5)
    verbose && println(" - processing group: ", gnm)
    for g in HDF5.names(h5)
        if HDF5.exists(h5, TABLE_OBJ_NAME)
            d = read_h5_table(h5)
            output_dict[gnm] = d
            break
        elseif HDF5.exists(h5, "array")
            d = read_h5_array(h5)
            output_dict[gnm] = d
            break
        end
        process_h5_file_group!(output_dict, h5[g], verbose) # group - recurse
    end
end

## WIP - NEED TO INCORPORATE TOML FILES
function process_h5_file(filepath::String, verbose::Bool)
    ## DEFINE OUTPUT HERE, PASS AS REF
    output = Dict()
    f = HDF5.h5open(filepath)
    process_h5_file_group!(output, f, verbose)
    HDF5.close(f)
    return output
end

# function process_toml_file(filepath::String)
#     return TOML.parsefile(filepath)
# end

function read_data_product(filepath::String, verbose::Bool)
    verbose && println("processing file: ", filepath)
    occursin(".h5", filepath) && (return process_h5_file(filepath, verbose))
    occursin(".toml", filepath) && (return TOML.parsefile(filepath))
    println(" - WARNING - UNKNOWN FILE TYPE - skipping:\n ", filepath)
end

## test
# DATA_DIR = "/home/martin/AtomProjects/DataRegistryUtils.jl/out/"
# println(typeof(process_h5_file(string(DATA_DIR, "geography/scotland/lookup_table/1.0.1.h5"))))
# println(read_data_product(string(DATA_DIR, "master/EERA/fixed-parameters/T_hos/0.1.0.toml")))
# read_data_product(string(DATA_DIR, "human/demographics/population/scotland/1.0.1.h5"))

# QUESTIONS FOR CLAIRE:
# - I noticed (in Simulation.jl) that you process your data into something called an AxisArray
# -- is that a general requirement or just something you happen to do one particular case?
