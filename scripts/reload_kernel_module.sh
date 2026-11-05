modprobe -r smi_stream_dev
modprobe bcm2835_smi
insmod ./smi_stream_dev.ko
