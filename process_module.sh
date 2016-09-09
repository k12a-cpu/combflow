#!/bin/sh
set -eu

module="$1"                 # Name of the RTL module to compile ("k12a_*").
dir="work_$module"          # Working directory.
input="$dir/input.v"        # Preprocessed Verilog input.
synth="$dir/synth.blif"     # Synthesised netlist in BLIF format.
packed="$dir/packed.attano" # Packed netlist in Attano format.
cells="cells.lib"           # Cell definitions for the ABC tool (run as part of the Yosys script).

name=$(echo "$module" | sed 's/^k12a_//')  # Module name without the "k12a_" prefix.
auto_node_format="$name""_autogen_node%"   # Format of auto-generated nodes.

# Start printing commands as they are executed.
set -x

# Ensure working directory exists.
mkdir -p "$dir"

# Ensure 'rtl' module is up to date.
git submodule update --remote rtl

# Convert SystemVerilog to Verilog 1995, as Yosys doesn't support SystemVerilog very well.
verilog_sources=$(find rtl -name '*.sv')
iverilog -tvlog95 -o"$input" -g2005-sv -Irtl -Irtl/k12a -s $1 $verilog_sources

# Run yosys to synthesise the Verilog into a netlist.
yosys -q <<YOSYSEND
read_verilog $input
hierarchy -check -top $module
proc
opt
techmap
opt
abc -liberty $cells
clean
rename -enumerate -pattern $auto_node_format
write_blif $synth
YOSYSEND

# Ensure the packer has been compiled.
nim c --verbosity:0 --define:release pack.nim

# Run the packer.
./pack --prefix "$name""_autogen_inst" "$synth" "$packed"
