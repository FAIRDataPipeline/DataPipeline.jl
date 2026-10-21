# SPDX-License-Identifier: LGPL-3.0-or-later

import HDF5
import TOML

### hdf5 file processing ###

# Write `data` as the dataset at `path` in an HDF5 file, making the groups
# that hold it, none of them recording times: what is written is then the
# same bytes whenever it is written, as a file must be to be found unchanged.
# A new file's root group must be made with `obj_track_times = false` too.
function _writeuntimed(file::HDF5.File, path::AbstractString, data::Array)
    parts = split(path, '/', keepempty = false)
    for group in accumulate((parent, part) -> "$parent/$part",
                            parts[1:(end - 1)])
        haskey(file, group) ||
            HDF5.create_group(file, group, obj_track_times = false)
    end
    HDF5.write_dataset(file, path, data, obj_track_times = false)
    return nothing
end

const ARRAY_OBJ_NAME = "array"
const TABLE_OBJ_NAME = "table"
const ROWN_OBJ_NAME = "row_names"

## does what it says on the tin
function read_h5_table(obj_grp)
    return HDF5.read(obj_grp[TABLE_OBJ_NAME])
end

## recursively search and read table/array
function process_h5_file_group!(output_dict::Dict, h5)
    gnm = HDF5.name(h5)
    if haskey(h5, TABLE_OBJ_NAME)
        d = read_h5_table(h5)
        output_dict[gnm] = d
    elseif (haskey(h5, ARRAY_OBJ_NAME) &&
            typeof(h5[ARRAY_OBJ_NAME])!=HDF5.Group)
        d = HDF5.read(h5)
        output_dict[gnm] = d
    elseif typeof(h5) == HDF5.Dataset
        d = HDF5.read(h5)
        output_dict[gnm] = d
    else    # group - recurse
        for g in keys(h5)
            process_h5_file_group!(output_dict, h5[g])
        end
    end
end

## wrapper for recursive processing
function process_h5_file(filepath::String)
    output = Dict()
    f = HDF5.h5open(filepath)
    process_h5_file_group!(output, f)
    HDF5.close(f)
    return output
end
