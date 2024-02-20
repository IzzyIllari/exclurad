#!/bin/bash

# Directory where all input files will be stored
dir_name="input_files"
mkdir -p "$dir_name"

# Define arrays of possible values for W, Q2, and cos(theta*)
#W_values=(1.4925 1.5075 1.5225 1.5375 1.5525 1.5725 1.5975 1.6225 1.6475 1.6725 1.6975 1.7225 1.7475 1.7725 1.7975 1.8350 1.8850 1.9350 1.9850)
W_values=(1.6975)
#Q2_values=(0.4105 0.7085 1.698 4.0855)
Q2_values=(0.4105)
#cos_values=(-0.75 -0.25 0.25 0.75)
cos_values=(0.0)
phi_values=(18. 54. 90. 126. 162. 198. 234. 270. 306. 342.)

counter=0

# Loop through each combination of W, Q2, and cos(theta*)
for w in "${W_values[@]}"; do
    for q2 in "${Q2_values[@]}"; do
        for cos in "${cos_values[@]}"; do
            # Prepare file name
            file_name="input_${counter}.dat"
            
            # Create and write to file
            {
                echo "3       !  1: AO 2: maid98  3: maid2000"
                echo "0       !  0: Full, 1: Factorizable and Leading log"
                echo "6.53    !  bmom - lepton momentum"
                echo "0.0     !  tmom - momentum per nucleon"
                echo "1       !  lepton - 1 electron, 2 muon"
                echo "1       !  ivec - detected hadron (1) p, (2) pi+"
                echo "0.166   !  vcut - cut on inelasticity (0.) if no cut, negative -- v"
                echo ""
                echo "10 ! no. of points"
                for i in {1..10}; do echo -n "$w "; done; echo "! W values"
                for i in {1..10}; do echo -n "$q2 "; done; echo "! Q^2 values"
                for i in {1..10}; do echo -n "$cos "; done; echo "! Cos(Theta) values"
                echo "${phi_values[*]} ! phi values"
                echo ""
                echo "0error detected by nag library routine   d01fce - ifail =     2"
            } > "$dir_name/$file_name"
            
            ((counter++))
        done
    done
done

echo "Generated $counter input files in $dir_name."

