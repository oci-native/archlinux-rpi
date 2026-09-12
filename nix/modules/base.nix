# The minimum needed to reach the machine after it boots. Deliberately small:
# every package added is another thing that has to be rebuilt from source,
# because the 16K-page overlay the Pi 5 vendor kernel requires puts most of
# the package set outside any binary cache.
{ lib, secrets, ... }:

{
  system.stateVersion = "25.11";

  networking.hostName = secrets.hostname;

  # Wired DHCP is the lowest bar there is for proving the machine reached
  # userspace: it depends on no firmware blob and no supplicant associating.
  networking.useDHCP = lib.mkDefault true;

  users.mutableUsers = false;
  users.users.root.initialPassword = secrets.password;
  users.users.${secrets.user} = {
    isNormalUser = true;
    initialPassword = secrets.password;
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "no";
  };

  # A console login that needs no network, for the next time it does not come up.
  services.getty.autologinUser = secrets.user;

  documentation.enable = false;
  documentation.man.enable = false;
  documentation.nixos.enable = false;
}
