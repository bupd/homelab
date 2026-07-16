{ config, lib, pkgs, ... }:

{
  system.stateVersion = "24.11";

  raspberry-pi-nix = {
    board = "bcm2712";
    kernel-version = "v6_12_17";
    firmware-partition-label = "BOOT";
    uboot.enable = false;
    firmware-migration-service.enable = lib.mkForce false;
  };

  boot = {
    loader.grub.enable = false;
    kernelParams = [
      "console=tty1"
      "console=serial0,115200n8"
      "ip=dhcp"
      "boot.shell_on_fail"
      "systemd.log_level=debug"
    ];
    initrd.availableKernelModules = [
      "bcmgenet"
      "pcie_brcmstb"
      "reset-raspberrypi"
      "sd_mod"
      "usb_storage"
      "usbhid"
    ];
  };

  fileSystems."/" = {
    device = "LABEL=NIXOS_BOOTC";
    fsType = "ext4";
  };

  fileSystems."/boot/firmware" = {
    device = "LABEL=BOOT";
    fsType = "vfat";
    options = [
      "rw"
      "relatime"
      "fmask=0022"
      "dmask=0022"
      "codepage=437"
      "iocharset=ascii"
      "shortname=mixed"
      "errors=remount-ro"
      "nofail"
    ];
  };

  networking = {
    hostName = "nixos-bootc-rpi5";
    useDHCP = false;
    interfaces.eth0.useDHCP = true;
  };

  users.users = {
    root.openssh.authorizedKeys.keyFiles = [
      "/etc/ssh/authorized_keys.d/root"
      "/boot/firmware/authorized_keys"
    ];
    bupd = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keyFiles = [
        "/etc/ssh/authorized_keys.d/bupd"
        "/boot/firmware/authorized_keys"
      ];
    };
  };

  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  systemd.network.wait-online.enable = false;

  systemd.services.rpi-bootc-sync = {
    description = "Sync bootc BLS deployment into Raspberry Pi firmware boot partition";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    requiresMountsFor = [ "/boot" "/boot/firmware" ];
    unitConfig = {
      ConditionPathIsDirectory = [ "/boot/firmware" "/boot/loader/entries" ];
    };
    serviceConfig = {
      Type = "oneshot";
      Environment = "RPI_BOOTC_EXTRA_CMDLINE=cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1";
      ExecStart = "/usr/local/sbin/rpi-bootc-sync --root / --boot /boot/firmware";
    };
  };

  systemd.paths.rpi-bootc-sync = {
    description = "Watch bootc BLS entries for Raspberry Pi boot partition sync";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathIsDirectory = [ "/boot/firmware" "/boot/loader/entries" ];
    };
    pathConfig = {
      PathModified = "/boot/loader/entries";
      PathChanged = "/boot/loader/entries";
      Unit = "rpi-bootc-sync.service";
    };
  };

  systemd.services.bootsy-beacon = {
    description = "Send a best-effort boot status message";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.curl pkgs.netcat-openbsd pkgs.systemd ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = [
        "-/etc/bootsy/reverse-ssh.env"
        "-/boot/firmware/bootsy-debug.env"
      ];
      ExecStart = "/usr/local/bin/bootsy-beacon booting";
    };
  };

  systemd.services.bootsy-reverse-ssh = {
    description = "Maintain reverse SSH access for headless boot debugging";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "sshd.service" ];
    wants = [ "network-online.target" "sshd.service" ];
    path = [ pkgs.coreutils pkgs.openssh pkgs.systemd ];
    serviceConfig = {
      Type = "simple";
      EnvironmentFile = [
        "-/etc/bootsy/reverse-ssh.env"
        "-/boot/firmware/bootsy-debug.env"
      ];
      ExecStart = "/usr/local/bin/bootsy-reverse-ssh";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    jq
    netcat-openbsd
    openssh
    podman
    ripgrep
    rsync
    tmux
    vim
  ];

  virtualisation.podman.enable = true;

  environment.etc."bootc/kargs.d/10-rpi5.toml".text = ''
    kargs = ["console=tty1", "console=serial0,115200n8", "ip=dhcp", "boot.shell_on_fail"]
    match-architectures = ["aarch64"]
  '';
}
