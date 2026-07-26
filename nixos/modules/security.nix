# =============================================================================
# NixOS Sicherheitsmodul – AppArmor, Audit, Fail2ban, sudo-Härtung, AIDE
# Angelehnt an apphost/nixos/modules/security.nix. Unterschiede: keine
# Traefik-Jail (dieser Host betreibt keinen Reverse Proxy), AIDE überwacht
# /opt/pihole statt /opt/monorepo/config.
# =============================================================================
{ config, pkgs, lib, ... }:
{
  # AppArmor – Mandatory Access Control
  security.apparmor = {
    enable                    = true;
    killUnconfinedConfinables = true;
    packages                  = [ pkgs.apparmor-profiles ];
    enableCache               = true;
  };

  # sudo Konfiguration
  security.sudo = {
    enable              = true;
    execWheelOnly       = true;
    wheelNeedsPassword  = true;
    extraConfig = ''
      # Keine Umgebungsvariablen weiterleiten um Injections zu verhindern
      Defaults env_reset
      Defaults secure_path="/run/current-system/sw/bin:/run/current-system/sw/sbin"
      # Logging für sauberen Auth-Log
      Defaults logfile=/var/log/sudo.log
      Defaults log_input,log_output
      Defaults iolog_dir=/var/log/sudo-io
      # Sitzungs-Timeout
      Defaults timestamp_timeout=5
      Defaults passwd_tries=3
    '';
  };

  # Audit-Daemon für CIS-konformes Audit-Logging
  security.audit = {
    enable = true;
    backlogLimit = 8192;
    rules  = [
      # Zeitänderungen
      "-a always,exit -F arch=b64 -S clock_settime -k time-change"
      "-a always,exit -F arch=b32 -S clock_settime -k time-change"
      "-w /etc/localtime -p wa -k time-change"

      # Benutzer-/Gruppen-Änderungen
      "-w /etc/group -p wa -k identity"
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/shadow -p wa -k identity"

      # Netzwerk-Konfiguration
      "-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale"
      "-w /etc/hosts -p wa -k system-locale"

      # Berechtigungseskalation
      "-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid"

      # Sudo
      "-w /etc/sudoers -p wa -k scope"
      "-w /etc/sudoers.d/ -p wa -k scope"

      # Kernel-Module via Syscall
      "-a always,exit -F arch=b64 -S init_module -S delete_module -k modules"
      "-a always,exit -F arch=b32 -S init_module -S delete_module -k modules"

      # Docker – nur echte User-Sessions (auid>=1000)
      "-w /var/lib/docker/ -p wa -F auid>=1000 -k docker"
      "-w /etc/docker/ -p rwa -k docker"

      # Löschoperationen (auid!=4294967295 = hat eine Login-Session)
      "-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -F auid!=4294967295 -k delete"

      # Datei-Berechtigungsänderungen
      "-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid!=4294967295 -k perm_mod"
      "-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid!=4294967295 -k perm_mod"

      # Fehlgeschlagene Zugriffe auf /etc
      "-a always,exit -F arch=b64 -S open -F dir=/etc -F success=0 -k unauth"
    ];
  };

  # Fail2ban – Brute-Force-Schutz (nur SSH; kein Traefik auf dieser VM)
  services.fail2ban = {
    enable = true;

    maxretry    = 3;
    bantime     = "15m";
    bantime-increment = {
      enable       = true;
      maxtime      = "48h";
      overalljails = true;
    };

    jails = {
      sshd = {
        settings = {
          enabled  = true;
          port     = "22";
          filter   = "sshd";
          logpath  = "/var/log/auth.log";
          maxretry = 3;
          bantime  = "2h";
        };
      };
    };

    extraPackages = [ pkgs.ipset ];
  };

  # AIDE – File Integrity Monitoring
  # DB initialisieren:  aide --init && cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
  environment.etc."aide.conf".text = ''
    database_in=file:/var/lib/aide/aide.db
    database_out=file:/var/lib/aide/aide.db.new
    database_new=file:/var/lib/aide/aide.db.new
    gzip_dbout=yes
    report_url=file:/var/log/aide.log
    report_url=stdout

    NORMAL = sha512+sha256+md5+rmd160+tiger+haval+gost+crc32

    /etc NORMAL
    /bin NORMAL
    /sbin NORMAL
    /lib NORMAL
    /lib64 NORMAL
    /usr/bin NORMAL
    /usr/sbin NORMAL
    /boot NORMAL
    /opt/pihole NORMAL

    !/proc
    !/sys
    !/dev
    !/run
    !/tmp
    !/var/tmp
  '';

  systemd.services.aide-check = {
    description = "AIDE File Integrity Check";
    startAt     = "daily";
    script      = ''
      if [ -f /var/lib/aide/aide.db ]; then
        ${pkgs.aide}/bin/aide --check || true
      else
        echo "AIDE-Datenbank nicht gefunden. Bitte 'aide --init' ausführen."
      fi
    '';
    serviceConfig.Type = "oneshot";
  };

  # Kernel-Sicherheitsmodule
  security = {
    lockKernelModules   = true;   # Nachladen nicht erlaubter Module verhindern
    protectKernelImage  = true;   # /dev/mem, /dev/kmem Schutz
    allowUserNamespaces = true;   # Für Docker userns-remap benötigt
  };

  # auditd – Daemon
  security.auditd.enable = true;

  # Logrotate
  services.logrotate = {
    enable = true;
    settings = {
      "/var/log/sudo.log" = {
        rotate     = 12;
        monthly    = true;
        compress   = true;
        missingok  = true;
        notifempty = true;
      };
    };
  };
}
