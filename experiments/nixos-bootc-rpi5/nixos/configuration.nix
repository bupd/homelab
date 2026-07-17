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
    # Avoid compiling the Raspberry Pi vendor kernel in CI. The Pi firmware still
    # owns firmware/config.txt/device-tree setup; bootc receives a cached
    # aarch64 NixOS kernel from nixpkgs.
    kernelPackages = lib.mkForce pkgs.linuxPackages_latest;
    kernelParams = [
      "console=tty1"
      "console=serial0,115200n8"
      "ip=dhcp"
      "boot.shell_on_fail"
      "systemd.log_level=debug"
    ];
    initrd.availableKernelModules = [
      "genet"
      "pcie-brcmstb"
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
    # Raspberry Pi 5 onboard Ethernet is commonly named end0 with predictable
    # interface names, while some kernels/configs still expose eth0. Let dhcpcd
    # claim whichever Ethernet interface appears so headless reverse SSH is not
    # blocked by a naming mismatch.
    useDHCP = true;
  };

  users.users = {
    bupd = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
  };

  security.sudo.wheelNeedsPassword = false;

  nix.enable = false;

  documentation = {
    enable = false;
    doc.enable = false;
    info.enable = false;
    man.enable = false;
    nixos.enable = false;
  };

  programs.command-not-found.enable = false;

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      AuthorizedKeysFile = ".ssh/authorized_keys /etc/ssh/authorized_keys.d/%u /boot/firmware/authorized_keys";
    };
  };

  systemd.network.wait-online.enable = false;

  systemd.services.bootsy-headless-apply = {
    description = "Apply Raspberry Pi bootfs headless SSH customisation";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "sshd.service" "bootsy-reverse-ssh.service" "bootsy-beacon.service" ];
    path = [ pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.shadow pkgs.systemd ];
    unitConfig = {
      RequiresMountsFor = [ "/boot/firmware" ];
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/usr/local/sbin/bootsy-headless-apply";
    };
  };

  systemd.services.rpi-bootc-sync = {
    description = "Sync bootc BLS deployment into Raspberry Pi firmware boot partition";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    unitConfig = {
      RequiresMountsFor = [ "/boot" "/boot/firmware" ];
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

  environment.defaultPackages = lib.mkForce [];

  environment.systemPackages = with pkgs; [
    bootc
    curl
    netcat-openbsd
    openssh
    ostree
    podman
    shadow
    skopeo
  ];

  virtualisation.podman.enable = false;

  environment.etc."bootc/kargs.d/10-rpi5.toml".text = ''
    kargs = ["console=tty1", "console=serial0,115200n8", "ip=dhcp", "boot.shell_on_fail"]
    match-architectures = ["aarch64"]
  '';

  environment.etc."containers/policy.json".text = builtins.toJSON {
    default = [
      {
        type = "insecureAcceptAnything";
      }
    ];
    transports = { };
  };
}
