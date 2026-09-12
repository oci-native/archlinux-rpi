# What the machine actually is, once it boots.
{ lib, pkgs, secrets, ... }:

{
  system.stateVersion = "25.11";

  networking.hostName = secrets.hostname;

  # Wired first. DHCP on a cable is the lowest bar there is for proving the
  # machine reached userspace, and it does not depend on firmware blobs or a
  # supplicant associating.
  networking.useDHCP = lib.mkDefault true;

  networking.wireless = lib.mkIf (secrets.wifiSsid != "") {
    enable = true;
    networks.${secrets.wifiSsid}.psk = secrets.wifiPsk;
  };

  # So the host is reachable by name without waiting on the router's DNS.
  # Its absence is why an earlier boot attempt could not be distinguished
  # from a failure: citadel.local was never going to resolve.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  users.mutableUsers = false;
  users.users.root.initialPassword = secrets.password;
  users.users.${secrets.user} = {
    isNormalUser = true;
    initialPassword = secrets.password;
    extraGroups = [ "wheel" "networkmanager" "video" "dialout" ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "no";
  };

  # A console login that does not need the network, for the next time it does
  # not come up.
  services.getty.autologinUser = secrets.user;

  time.timeZone = lib.mkDefault "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    git
    htop
    pciutils
    usbutils
    vim
  ];

  # Keep the closure small enough to be worth shipping in a container layer
  # later, when this becomes a bootc image.
  documentation.enable = false;
  documentation.man.enable = false;
  documentation.nixos.enable = false;
}
