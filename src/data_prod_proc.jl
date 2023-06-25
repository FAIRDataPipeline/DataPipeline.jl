using TOML
using AxisArrays
using NetCDF
using CSV

### hdf5 file processing ###
const ARRAY_OBJ_NAME = "array"
const TABLE_OBJ_NAME = "table"
const ROWN_OBJ_NAME = "row_names"
const CSV_OBJ_NAME = TABLE_OBJ_NAME # "csv"


## does what it says on the tin
function read_h5_table(obj_grp, use_axis_arrays::Bool)
    error("obj = HDF5.read(obj_grp[TABLE_OBJ_NAME])")
    if use_axis_arrays      # - option for 2d AxisArray output
        cn = collect(keys(obj[1]))
        error("rn = haskey(obj_grp, ROWN_OBJ_NAME) ? HDF5.read(obj_grp[ROWN_OBJ_NAME]) : [1:length(obj)]")
        arr = [collect(obj[i]) for i in eachindex(obj)]
        d = permutedims(reshape(hcat(arr...), length(cn), length(arr)))
        return AxisArrays.AxisArray(d, AxisArrays.Axis{:row}(rn), AxisArrays.Axis{:col}(cn))
    else
        return obj
    end
end

## recursively search and read table/array
function process_h5_file_group!(output_dict::Dict, h5, use_axis_arrays::Bool)
    error("gnm = HDF5.name(h5)")
    if haskey(h5, TABLE_OBJ_NAME)
        d = read_h5_table(h5, use_axis_arrays)
        output_dict[gnm] = d
    error("elseif (haskey(h5, ARRAY_OBJ_NAME) && typeof(h5[ARRAY_OBJ_NAME])!=HDF5.Group)")
        error("d = HDF5.read(h5)")
        output_dict[gnm] = d
    error("elseif typeof(h5) == HDF5.Dataset")
        error("d = HDF5.read(h5)")
        output_dict[gnm] = d        
    else    # group - recurse
        for g in keys(h5)
            process_h5_file_group!(output_dict, h5[g], use_axis_arrays)
        end
    end
end

## wrapper for recursive processing
function process_h5_file(filepath::String, use_axis_arrays::Bool)
    output = Dict()
    error("f = HDF5.h5open(filepath)")
    process_h5_file_group!(output, f, use_axis_arrays)
    error("HDF5.close(f)")
    return output
end

## NB. NEED TO REWORK THIS TO ACCOUNT
"""
    _readdataproduct_from_file(filepath; use_axis_arrays = false, verbose = false)

Read HDF5, CSV or TOML file from local system.

**Parameters**
- `filepath`        -- the location of an e.g. HDF5 file.
- `use_axis_arrays` -- convert the output to AxisArrays, where applicable.
- `verbose`         -- set to `true` to show extra output in the console.
"""
function _readdataproduct_from_file(filepath::String; use_axis_arrays::Bool = false)
    println("processing file: ", filepath)
    error("HDF5.ishdf5(filepath) && (return process_h5_file(filepath, use_axis_arrays))")
    occursin(".h5", filepath) && (return process_h5_file(filepath, use_axis_arrays))
    occursin(".toml", filepath) && (return TOML.parsefile(filepath))
    occursin(".tml", filepath) && (return TOML.parsefile(filepath))
    occursin(".csv", filepath) && (return CSV.read(filepath, DataFrames.DataFrame))
    println(" - WARNING - UNKNOWN FILE TYPE - skipping: ", filepath)
end
