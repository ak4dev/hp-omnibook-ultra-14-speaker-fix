# Out-of-tree rebuild of soundwire-cadence for Linux 7.1.9-arch1-2, with one change:
# re-arm cdns_check_attached_status_dwork() while a peripheral that was once
# enumerated is UNATTACHED. Sources are v7.1.9 verbatim except cadence_master.{c,h}.
obj-m := soundwire-cadence.o
soundwire-cadence-y := cadence_master.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(CURDIR)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
