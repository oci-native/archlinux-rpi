ARG BASE=localhost/archlinux-bootc-rpi:10-kitten-rpi-arch

FROM $BASE

COPY 10-bootc-growpart.cfg /etc/cloud/cloud.cfg.d/
RUN \
  pacman -Sy --noconfirm cloud-init cloud-guest-utils && \
  systemctl enable cloud-init && \
  sed -i 's@resize_what = "/"@resize_what = "/var"@' /usr/lib/python*/site-packages/cloudinit/config/cc_resizefs.py
