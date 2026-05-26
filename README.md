# OpenWrt stock layout converter on Zyxel EX5601-T0 ( Project C)
This tool is for you if you have Openwrt ( stock layout) installed on EX5601-T0 / T-56 router and you want to...
> Convert Openwrt stock layout to Openwrt ubootmod layout

> [!WARNING]
> Power loss during flash can brick the device.
> Keep backups of important MTD partitions before flash

## Installation

Download two required files.
- `loader.sh`
- `openwrt_chroot_rootfs.tar.gz`
```sh
cd /tmp
wget \
https://raw.githubusercontent.com/majad00/openwrt-stock-layout-to-ubootmod-ex5601-t0/main/tools/loader.sh \
https://raw.githubusercontent.com/majad00/openwrt-stock-layout-to-ubootmod-ex5601-t0/main/tools/openwrt_chroot_rootfs.tar.gz
chmod +x loader.sh ; ./loader.sh
```

Copy these two files to the router under `/tmp`:

Example:

```sh
scp loader.sh openwrt_chroot_rootfs.tar.gz root@192.168.1.1:/tmp/
```

SSH into the router and run:
```sh
cd /tmp
chmod +x loader.sh
./loader.sh
```

After the loader finishes, open LuCI at port 8080 and go to:
System > Matrix Installer ( click your option)

### Building from source

Project A, B and C are part of main project and based on the source from
https://github.com/majad00/ex5601_openwrt_loader
