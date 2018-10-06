#!/bin/bash

set -ex

NM_USB0_LINKLOCAL_CONNECTION=$(cat<<EOF
[connection]
id=usb0_linklocal
uuid=3c8ee1db-c6b3-4db6-8bfc-4e94e72cab17
interface-name=usb0
type=ethernet

[ipv6]
method=link-local
never-default=true

[ipv4]
method=link-local
never-default=true
EOF
)

function build_debian_post_chroot {

	sudo mount -t proc	chproc	rootfs/proc
	sudo mount -t sysfs	chsys	rootfs/sys

	sudo chroot rootfs /bin/bash <<EOF
set -x
echo -e "chip\nchip\n\n\n\n\n\nY\n" | adduser chip
adduser chip sudo 
adduser chip i2c

export BRANCH

if [[ "$BRANCH" == "pocketchip" ]]; then
sudo apt-get install -y --allow-unauthenticated xmlstarlet

#battery-warning poweroff fix
cat /usr/share/polkit-1/actions/org.freedesktop.login1.policy

xmlstarlet ed -u\
 "/*/action[@id='org.freedesktop.login1.power-off']/defaults/allow_any"\
  -v "yes"\
 /usr/share/polkit-1/actions/org.freedesktop.login1.policy

xmlstarlet ed -u\
 "/*/action[@id='org.freedesktop.login1.power-off']/defaults/allow_any"\
  -v "yes"\
 /usr/share/polkit-1/actions/org.freedesktop.login1.policy >\
 /usr/share/polkit-1/actions/org.freedesktop.login1.policy.new

mv /usr/share/polkit-1/actions/org.freedesktop.login1.policy.new\
 /usr/share/polkit-1/actions/org.freedesktop.login1.policy
sudo apt-get purge -y xmlstarlet

##hacks for pocketchip gtk file dialog size
mkdir -p /home/chip/.config
cp -R /etc/skel/.config/gtk-2.0 /home/chip/.config/
chown -R root:root /home/chip/.config/gtk-2.0
chmod 655 /home/chip/.config/gtk-2.0
chmod 644 /home/chip/.config/gtk-2.0/*
##endhacks
fi

apt-get clean
apt-get autoclean
apt-get autoremove

rm -rf /var/lib/apt/lists/*
rm -rf /usr/lib/locale/*

if [[ "$BRANCH" == "pocketchip" ]]; then
systemctl disable systemd-journal-flush
systemctl mask systemd-journal-flush
systemctl disable ModemManager
systemctl mask ModemManager
systemctl disable hostapd
systemctl mask hostapd


sed -i -e 's/#Storage=.*/Storage=volatile/' /etc/systemd/journald.conf
sed -i -e 's/#SystemMaxUse=.*/SystemMaxUse=10M/' /etc/systemd/journald.conf
sed -i -e 's/#SystemKeepFree=.*/SystemKeepFree=5M/' /etc/systemd/journald.conf
sed -i -e 's/#RuntimeMaxUse=.*/RuntimeMaxUse=10M/' /etc/systemd/journald.conf
sed -i -e 's/#RuntimeKeepFree=.*/RuntimeKeepFree=5M/' /etc/systemd/journald.conf

update-initramfs -u
fi

EOF
  sync
  sleep 3

  sudo umount -l rootfs/proc
  sudo umount -l rootfs/sys

  sudo rm rootfs/usr/sbin/policy-rc.d
  sudo rm rootfs/etc/resolv.conf
  sudo rm rootfs/usr/bin/qemu-arm-static

	#  hack to generate ssh host keys on first boot
	#  also finish install of hanging packages [blueman]
	if [[ ! -e rootfs/etc/rc.local.orig ]]; then sudo mv rootfs/etc/rc.local rootfs/etc/rc.local.orig; fi
	echo -e "#!/bin/sh\n\n\
if [[ -f /etc/ssh/ssh_host_rsa_key ]] &&\n\
   [[ -f /etc/ssh/ssh_host_dsa_key ]] &&\n\
   [[ -f /etc/ssh/ssh_host_key ]] &&\n\
   [[ -f /etc/ssh/ssh_host_ecdsa_key ]] &&\n\
   [[ -f /etc/ssh/ssh_host_ed25519_key ]]; then\n\
\n\
mv -f /etc/rc.local.orig /etc/rc.local\n\
exit 0\n\
\n\
fi\n\
\n\
rm -f /etc/ssh/ssh_host_*\n\
/usr/bin/ssh-keygen -t rsa -N '' -f /etc/ssh/ssh_host_rsa_key\n\
/usr/bin/ssh-keygen -t dsa -N '' -f /etc/ssh/ssh_host_dsa_key\n\
/usr/bin/ssh-keygen -t rsa1 -N '' -f /etc/ssh/ssh_host_key\n\
/usr/bin/ssh-keygen -t ecdsa -N '' -f /etc/ssh/ssh_host_ecdsa_key\n\
/usr/bin/ssh-keygen -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key\n\
systemctl restart ssh\n\
\n\
apt-get -f install\n\
sync\n\
" |sudo tee rootfs/etc/rc.local >/dev/null

	sudo chmod a+x rootfs/etc/rc.local

	#enable root login via ssh
	sudo sed -i -e 's/PermitRootLogin without-password/PermitRootLogin yes/' rootfs/etc/ssh/sshd_config

	#network-manager should ignore wlan1
	NM_CONF="rootfs/etc/NetworkManager/NetworkManager.conf"
	grep -q '^\[keyfile\]' "${NM_CONF}" || \
    echo -e "$(cat ${NM_CONF})\n\n[keyfile]\nunmanaged-devices=interface-name:wlan1" |sudo tee ${NM_CONF}

	#network-manager default to link-local on usb0 cdc_ethernet
	sudo mkdir -p rootfs/etc/NetworkManager/system-connections/
	echo "${NM_USB0_LINKLOCAL_CONNECTION}" \
		| sudo tee rootfs/etc/NetworkManager/system-connections/usb0_linklocal &> /dev/null
	sudo chmod 755 rootfs/etc/NetworkManager/system-connections
	sudo chmod 600 rootfs/etc/NetworkManager/system-connections/usb0_linklocal

  #hack to set back kernel/printk level to 4 after wifi modules have been loaded:
  sudo sed -i -e '/ExecStart=.*/ aExecStartPost=/bin/bash -c "/bin/echo 4 >/proc/sys/kernel/printk"' rootfs/lib/systemd/system/wpa_supplicant.service

  #load g_serial at boot time
  #echo -e "$(cat rootfs/etc/modules)\ng_serial" | sudo tee rootfs/etc/modules

  echo -e "Debian on C.H.I.P ${BRANCH} build ${BUILD} rev ${GITHASH}\n" |sudo tee rootfs/etc/chip_build_info.txt

  echo -e "$(cat rootfs/etc/os-release)\n\
  BUILD_ID=$(date)\n\
  VARIANT=\"Debian on C.H.I.P\"\n\
  VARIANT_ID=$(cat rootfs/etc/os-variant)\n" |sudo tee rootfs/etc/os-release

pushd rootfs
sudo tar -cf ../postchroot-rootfs.tar.gz .
}

build_debian_post_chroot || exit $?

