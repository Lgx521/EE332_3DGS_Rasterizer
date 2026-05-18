# add_sources.tcl
# Run in Vivado Tcl Console:  source add_sources.tcl
# Adds all VHDL sources, constraints, and simulation files to the project.

set proj_dir [file dirname [info script]]

# ========== Design Sources ==========
add_files -fileset sources_1 [glob $proj_dir/src/*.vhd]

# Set top module
set_property top top_gsplat [current_fileset]

# ========== Constraints ==========
add_files -fileset constrs_1 $proj_dir/constrs/gsplat.xdc

# ========== Simulation Sources ==========
add_files -fileset sim_1 [glob $proj_dir/sim/tb_*.vhd]

# Set simulation top to the full-system testbench
set_property top tb_top [get_filesets sim_1]

# ========== Memory Init Files ==========
# Add .mem files so Vivado can find them during synthesis/simulation
add_files [glob $proj_dir/mem/*.mem]

puts "All sources added successfully."
puts "Design sources: [llength [get_files -of_objects [get_filesets sources_1]]] files"
puts "Constraints:    [llength [get_files -of_objects [get_filesets constrs_1]]] files"
puts "Simulation:     [llength [get_files -of_objects [get_filesets sim_1]]] files"
