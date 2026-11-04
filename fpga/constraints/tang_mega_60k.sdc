# Physical controls/SPI/PT8211 use clk_50m and enables. Video owns a PLL.
create_clock -name system_clock_50mhz -period 20.000 -waveform {0.000 10.000} [get_ports {clk_50m}]
# R11.3 最终未引入 12.5 MHz 分频域（左手判定留在单实例 50 MHz 链路里，
# 只增加跨通道最小值扣除），因此本文件不需要额外的派生时钟。
# Only used when USE_EXTERNAL_AUDIO_CLOCK=1. Never redefines the 50MHz clock.
create_clock -name audio_bck_clock -period 651.041667 -waveform {0.000 325.520833} [get_ports {audio_bck_in}]
set_clock_groups -asynchronous -group [get_clocks {system_clock_50mhz}] -group [get_clocks {audio_bck_clock}]
# Mailbox payload is held until acknowledgement; toggles have three-stage
# synchronizers. CDC behaviour is separately checked in revision5_clock_tb.

# UART RX/TX are absent: the physical adapter is the sole performer source.

# External user reset is synchronized before release.
set_false_path -from [get_ports {reset_n}]

# PAW and AD7091R-4 returns use explicit synchronizers and slow generated SPI.
# ADC128S102 DOUT is captured directly after a 60ns half-SCK (DIV=3), matching
# its 8..16MHz SCLK specification; its tCO max 27ns leaves a nominal 33ns
# for board flight/FPGA input/setup. It has no two-flop MISO synchronizer.
# These external input paths are excluded below: internal STA PASS therefore
# does NOT sign off external sensor setup/hold. Board IO timing remains open.
set_false_path -from [get_ports {paw_miso left_adc1_out left_adc2_out piezo_miso piezo_busy_n}]
set_output_delay -clock system_clock_50mhz -max 5.000 [get_ports {paw_ncs paw_sclk paw_mosi left_adc_sclk left_adc_din left_adc1_cs_n left_adc2_cs_n left_tx1 left_tx2 left_tx3 left_tx4 left_sk_clk left_sk_data piezo_sclk piezo_mosi piezo_cs_n piezo_convst_n piezo_reset_n}]
set_output_delay -clock system_clock_50mhz -min 0.000 [get_ports {paw_ncs paw_sclk paw_mosi left_adc_sclk left_adc_din left_adc1_cs_n left_adc2_cs_n left_tx1 left_tx2 left_tx3 left_tx4 left_sk_clk left_sk_data piezo_sclk piezo_mosi piezo_cs_n piezo_convst_n piezo_reset_n}]
set_output_delay -clock system_clock_50mhz -max 5.000 [get_ports {hp_bck hp_ws hp_din pa_en}]
set_output_delay -clock system_clock_50mhz -min 0.000 [get_ports {hp_bck hp_ws hp_din pa_en}]

# Gowin derives PLL output clocks. Official profile: 366.6667 / 73.3333MHz.# Independent observation domains: only toggle synchronizers, held metadata and
# double-buffered RAM cross this boundary; audio has no video-dependent enables.
create_clock -name video_pixel_clock -period 13.636 [get_pins {VIDEO.u_display/u_video_pll/PLLA_inst/CLKOUT1}]
create_clock -name video_serial_clock -period 2.727 [get_pins {VIDEO.u_display/u_video_pll/PLLA_inst/CLKOUT0}]
set_clock_groups -asynchronous -group [get_clocks {system_clock_50mhz}] -group [get_clocks {video_pixel_clock video_serial_clock}]
set_clock_groups -asynchronous -group [get_clocks {audio_bck_clock}] -group [get_clocks {video_pixel_clock video_serial_clock}]
# PLL LOCK is asynchronous status, used solely to assert reset. Local RTL reset
# releases have three-stage domain synchronizers; the vendor DVI PHY retains
# its board-reset/LOCK startup scheme. This is not a datapath timing exception.
set_false_path -from [get_pins {VIDEO.u_display/u_video_pll/PLLA_inst/LOCK}]
