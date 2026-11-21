# Time unit: nanoseconds
set_units -time ns
# Clock on port clk. The period comes from CLOCK_PERIOD in config.json,
# so changing CLOCK_PERIOD changes synthesis AND place-and-route.
create_clock [get_ports clk] -name clk -period $::env(CLOCK_PERIOD)
# Safety margin for clock jitter and skew, used in every timing check
set_clock_uncertainty 0.25 [get_clocks clk]
# Inputs arrive, and outputs must be ready, 20% of a period from the clock edge
set_input_delay  [expr {$::env(CLOCK_PERIOD) * 0.2}] -clock clk [all_inputs -no_clocks]
set_output_delay [expr {$::env(CLOCK_PERIOD) * 0.2}] -clock clk [all_outputs]
# Each output drives a 0.033 pF (33 fF) load
set_load 0.033 [all_outputs]
