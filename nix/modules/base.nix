# A headless Pi 5. Deliberately small: every package added is another thing
# rebuilt from source, because the 16K-page overlay the vendor kernel requires
# puts most of the package set outside any binary cache.
{ lib, secrets, ... }:

let
  # Public keys are not secrets, so this lives in the repo and CI can build a
  # fully configured machine without anything sensitive reaching a public
  # repository's runner.
  authorizedKeys =
    lib.filter (l: l != "" && !(lib.hasPrefix "#" l))
      (lib.splitString "\n" (builtins.readFile ../authorized-keys.txt));
in
{
  system.stateVersion = "25.11";

  networking.hostName = secrets.hostname;

  # Wired DHCP is the lowest bar there is for proving the machine reached
  # userspace: it depends on no firmware blob and no supplicant associating.
  networking.useDHCP = lib.mkDefault true;

  # Only configured when a wifi PSK is actually available, which it is not in
  # CI. Ethernet is the path that has to work.
  networking.wireless = lib.mkIf (secrets.wifiSsid != "") {
    enable = true;
    networks.${secrets.wifiSsid}.psk = secrets.wifiPsk;
  };

  # So the box is reachable by name without waiting on the router's DNS.
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
  users.users.${secrets.user} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = authorizedKeys;
    # Only set when a password is actually supplied; otherwise this account is
    # key-only and has no password at all.
    initialPassword = lib.mkIf (secrets.password != "") secrets.password;
  };
  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;

  # Headless, so getting in has to work before anything else does. Key-only
  # unless a password was supplied, which it is not in CI.
  security.sudo.wheelNeedsPassword = false;
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = secrets.password != "";
      PermitRootLogin = "prohibit-password";
    };
  };

  # A console login that needs no network, for the next time it does not come up.
  services.getty.autologinUser = secrets.user;

  time.timeZone = lib.mkDefault "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  documentation.enable = false;
  documentation.man.enable = false;
  documentation.nixos.enable = false;
}
