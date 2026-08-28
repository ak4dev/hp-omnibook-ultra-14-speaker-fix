# Out-of-tree rebuild of snd-soc-sdca for Linux 7.1.9-arch1-2, with one change:
# assume SmartAmp for a TI (mfg 0x0102) SoundWire peripheral whose ACPI gives no
# mipi-sdca-control-dc-value. Sources are v7.1.9 verbatim except sdca_functions.c.
obj-m := snd-soc-sdca.o
snd-soc-sdca-y := sdca_functions.o sdca_device.o sdca_function_device.o \
                  sdca_regmap.o sdca_asoc.o sdca_ump.o \
                  sdca_hid.o sdca_interrupts.o sdca_jack.o sdca_fdl.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(CURDIR)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
