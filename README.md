# Instruction Cache (`icache`) ASIC Flow

Final results are in Runs/icache2

RTL implementation, verification testbench, and OpenLane 2 / OpenROAD physical design flow for an Instruction Cache (`icache`).

## Overview
- **Design:** Instruction Cache (`icache`)
- **Language:** Verilog / SystemVerilog
- **Flow:** RTL-to-GDSII (OpenLane 2 / OpenROAD)
- **Simulation:** Icarus Verilog, GTKWave, Vivado XSim

## Simulation
bash
iverilog -o icache_sim src/.v tb/.v
vvp icache_sim
