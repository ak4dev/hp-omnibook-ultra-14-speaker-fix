# Out-of-tree rebuild of snd-soc-sdw-utils for Linux 7.1.9-arch1-2, with one change:
# drop SmartAmp endpoints whose SoundWire peripheral has left the bus, so a dead
# TAS2783 cannot abort the Speaker PCM open for the amplifiers that are alive.
# Sources are v7.1.9 verbatim except soc_sdw_utils.c (see the .patch beside this).
snd-soc-sdw-utils-y := soc_sdw_utils.o soc_sdw_dmic.o soc_sdw_rt_dmic.o \
		       soc_sdw_rt700.o soc_sdw_rt711.o			\
		       soc_sdw_rt5682.o soc_sdw_rt_sdca_jack_common.o	\
		       soc_sdw_rt_amp.o soc_sdw_rt_mf_sdca.o		\
		       soc_sdw_bridge_cs35l56.o				\
		       soc_sdw_cs42l42.o soc_sdw_cs42l43.o		\
		       soc_sdw_cs42l45.o				\
		       soc_sdw_cs47l47.o				\
		       soc_sdw_cs_amp.o					\
		       soc_sdw_maxim.o \
		       soc_sdw_ti_amp.o
obj-m += snd-soc-sdw-utils.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(CURDIR)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
