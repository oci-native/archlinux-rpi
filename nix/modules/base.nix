# What the machine actually is, once it boots.
{ lib, pkgs, secrets, ... }:

{
  system.stateVersion = "25.11";

  networking.hostName = secrets.hostname;
  networking.useDHCP = lib.mkDefault true;

  networking.wireless = lib.mkIf (secrets.wifiSsid != "") {
    enable = true;
    networks.${secrets.wifiSsid}.psk = secrets.wifiPsk;
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

  time.timeZone = lib.mkDefault "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    git
    htop
    pciutils
    usbutils
    vim
  ];

  # Keep the closure small enough to be worth shipping in a container layer.
  documentation.enable = false;
  documentation.man.enable = false;
  documentation.nixos.enable = false;
}
