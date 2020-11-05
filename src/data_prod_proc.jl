# import SQLite
# import DataFrames
import HDF5
import TOML
import AxisArrays

### hdf5 file processing ###
const ARRAY_OBJ_NAME = "array"
const TABLE_OBJ_NAME = "table"
const ROWN_OBJ_NAME = "row_names"

## does what it says on the tin
function read_h5_table(obj_grp, use_axis_arrays::Bool)
    obj = HDF5.read(obj_grp[TABLE_OBJ_NAME])
    if use_axis_arrays      # - option for 2d AxisArray output
        cn = collect(keys(obj[1]))
        rn = HDF5.exists(obj_grp, ROWN_OBJ_NAME) ? HDF5.read(obj_grp[ROWN_OBJ_NAME]) : [1:length(obj)]
        arr = [collect(obj[i]) for i in eachindex(obj)]
        d = permutedims(reshape(hcat(arr...), length(cn), length(arr)))
        return AxisArrays.AxisArray(d, AxisArrays.Axis{:row}(rn), AxisArrays.Axis{:col}(cn))
    else
        return obj
    end
end

## does what it says on the tin
function read_h5_array(obj_grp)
    return HDF5.read(obj_grp[ARRAY_OBJ_NAME])
end

## recursively search and read table/array
function process_h5_file_group!(output_dict::Dict, h5, use_axis_arrays::Bool, verbose::Bool)
    gnm = HDF5.name(h5)
    verbose && println(" - processing group: ", gnm)
    for g in HDF5.names(h5)
        if HDF5.exists(h5, TABLE_OBJ_NAME)
            d = read_h5_table(h5, use_axis_arrays)
            output_dict[gnm] = d
            break
        elseif HDF5.exists(h5, ARRAY_OBJ_NAME)
            d = read_h5_array(h5)
            output_dict[gnm] = d
            break
        end
        process_h5_file_group!(output_dict, h5[g], use_axis_arrays, verbose) # group - recurse
    end
end

## wrapper for recursive processing
function process_h5_file(filepath::String, use_axis_arrays::Bool, verbose::Bool)
    output = Dict()
    f = HDF5.h5open(filepath)
    process_h5_file_group!(output, f, use_axis_arrays, verbose)
    HDF5.close(f)
    return output
end

# function process_toml_file(filepath::String)
#     return TOML.parsefile(filepath)
# end

"""
    read_data_product(filepath; use_axis_arrays = false, verbose = false)

Read HDF5 or TOML file from local system.

**Parameters**
- `filepath`        -- the location of an HDF5 or TOML file.
- `use_axis_arrays` -- convert the output to AxisArrays, where applicable.
- `verbose`         -- set to `true` to show extra output in the console.
"""
function read_data_product(filepath::String; use_axis_arrays::Bool = false, verbose::Bool = false)
    verbose && println("processing file: ", filepath)
    occursin(".h5", filepath) && (return process_h5_file(filepath, use_axis_arrays, verbose))
    occursin(".toml", filepath) && (return TOML.parsefile(filepath))
    println(" - WARNING - UNKNOWN FILE TYPE - skipping: ", filepath)
end

## test
# DATA_DIR = "/home/martin/AtomProjects/DataRegistryUtils.jl/out/"
# println(typeof(process_h5_file(string(DATA_DIR, "geography/scotland/lookup_table/1.0.1.h5"))))
# println(read_data_product(string(DATA_DIR, "master/EERA/fixed-parameters/T_hos/0.1.0.toml")))
# read_data_product(string(DATA_DIR, "human/demographics/population/scotland/1.0.1.h5"))

# QUESTIONS FOR CLAIRE:
# - I noticed (in Simulation.jl) that you process your data into something called an AxisArray
# -- is that a general requirement or just something you happen to do one particular case?
