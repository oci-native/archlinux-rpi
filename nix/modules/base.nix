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

  networking.useDHCP = lib.mkDefault true;

  # Wifi is the only way in: this Pi has no ethernet.
  #
  # wpa_supplicant rather than iwd. iwd does all of its crypto through AF_ALG
  # kernel sockets, and while bcm2712_defconfig has CRYPTO_USER_API_HASH and
  # _SKCIPHER, whether hmac, cmac, ecb(aes) and ctr(aes) survive into the final
  # config is unverified -- and a missing one fails at handshake time, on a
  # box with no other way in. wpa_supplicant does its crypto in userspace.
  # Enabling it also turns on hardware.wirelessRegulatoryDatabase, which the
  # iwd module does not.
  #
  # pskRaw = "ext:..." keeps the passphrase out of the nix store: the value is
  # read at runtime from secretsFile, which is written onto the card by
  # scripts/provision-wifi.sh. Nothing sensitive reaches git or CI.
  networking.wireless = {
    enable = true;
    secretsFile = "/var/lib/wireless/secrets.conf";
    networks.${secrets.wifiSsid}.pskRaw = "ext:psk_wifi";
    # Hardened mode runs wpa_supplicant as its own user, which would mean
    # matching that uid when writing the secrets file onto an unbooted card.
    # Running as root keeps first-boot provisioning deterministic: the file is
    # simply root-owned 0600.
    enableHardening = false;
  };

  # The brcmfmac firmware on the BCM43455 mishandles WPA3/SAE offload, and on
  # a mixed WPA2/WPA3 access point that shows up as an association failure or
  # a firmware crash -- for every supplicant, not just this one. Disabling the
  # SAE and fast-roam offloads is the documented workaround and costs nothing
  # on a WPA2 network.
  boot.kernelParams = [ "brcmfmac.feature_disable=0x82000" ];

  hardware.enableRedistributableFirmware = true;
  hardware.wirelessRegulatoryDatabase = true;

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
