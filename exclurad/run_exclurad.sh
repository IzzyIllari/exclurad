#!/bin/bash

# Step 1: Environment setup
echo "Sourcing set up file..."
source /group/clas12/packages/setup.sh
echo "Sourced set up file success..."
echo "Loading latest CLAS12 environment..."
module load clas12
echo "CLAS12 environment loaded..."
echo "Loading cmake..."
module load cmake
echo "Environment check..."
module list

# Step 2: Go to the work directory
cd /w/hallb-scshelf2102/clas12/izzy/exclurad_working/exclurad/

# Step 3: Create a directory for results with date
results_dir="results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$results_dir"
echo "Results directory created: $results_dir"

# Step 4-6: Loop to process input files
input_dir="/w/hallb-scshelf2102/clas12/izzy/exclurad_working/exclurad/input_files"
for input_file in "$input_dir"/*; do
    # Extracting file number
    file_number=$(echo "$input_file" | grep -oP 'input_\K\d+')

    echo -e "\e[1mProcessing file number: $file_number\e[0m"

    # Copy and rename the input file
    cp "$input_file" ./input.dat

    # Step 5: Run the Fortran script
    ./build/exclurad.exe

    # Step 6: Rename and move output files
    for output_file in all.dat radasm.dat radcor.dat radsigmi.dat radsigpl.dat radtot.dat; do
        if [ -f "$output_file" ]; then
            mv "$output_file" "${results_dir}/${output_file%.dat}_${file_number}.dat"
        fi
    done

    echo -e "\e[1mFinished processing file number: $file_number\e[0m"
done

# Step 8: Completion message
echo -e "\e[1mAll done! Results are in $results_dir\e[0m"

