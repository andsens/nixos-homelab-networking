{ inputs, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  # See https://github.com/NixOS/nixpkgs/blob/597283ad8aa0b331c788e97c4c262d58877074ef/nixos/modules/services/networking/unifi.nix
  ccfg = config.homelab.cluster;
  cfg = config.homelab.services.unifi;
  jrePkg = pkgs.jdk25_headless;
  unifiPkg = pkgs.stdenvNoCC.mkDerivation {
    name = "mk-unifi-home";
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      mkdir $out
      cp -r ${pkgs.unifi}/* $out/
      ln -s "${pkgs.mongodb-7_0}/bin" $out/bin
      ln -s /var/lib/unifi/data $out/data
      ln -s /var/lib/unifi/logs $out/logs
      ln -s /var/lib/unifi/run $out/run
      runHook postInstall
    '';
  };
  run = pkgs.writeShellScriptBin "unifi" ''
    mkdir -p /var/lib/unifi/data/db
    exec "${jrePkg}/bin/java" \
    --add-opens=java.base/java.lang=ALL-UNNAMED \
    --add-opens=java.base/java.time=ALL-UNNAMED \
    --add-opens=java.base/sun.security.util=ALL-UNNAMED \
    --add-opens=java.base/java.io=ALL-UNNAMED \
    --add-opens=java.rmi/sun.rmi.transport=ALL-UNNAMED \
    -jar "${unifiPkg}/lib/ace.jar" "$@"
  '';
  image = pkgs.dockerTools.buildLayeredImage {
    name = "cluster.local/unifi";
    contents = with pkgs; [ mongodb-7_0 ] ++ lib.optionals cfg.debug ccfg.debugTools;
    config.Entrypoint = [
      (lib.getExe pkgs.tini)
      (lib.getExe run)
      "--"
    ];
    config.Cmd = [ "start" ];
  };
in
{
  options.homelab.services.unifi = {
    enable = lib.mkEnableOption "Unifi Controller";
    debug = lib.mkEnableOption "debug mode";
  };
  imports = [ ];
  config = lib.mkIf cfg.enable {
    services.k3s.images = [ image ];
    homelab.cluster.backup.volumes.unifi.unifi = [ "/var/lib/unifi/data" ];
    kubetree.resources.unifi = {
      logs = {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        metadata.namespace = "unifi";
        metadata.name = "logs";
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = "1Gi";
          volumeMode = "Filesystem";
        };
      };
      service-macro = {
        apiVersion = "cluster.local";
        kind = "ServiceMacro";
        metadata.name = "unifi";
        spec = {
          allowIngress = [
            "local-lan"
          ];
          allowEgress = [
            "internet"
          ];
          dataPath = "/var/lib/unifi/data";
          ingressPort = 8443;
          servicePodSpec = {
            mainContainer = {
              image = "${image.imageName}:${image.imageTag}";
              imagePullPolicy = "Never";
              workingDir = "/var/lib/unifi";
              portsByName = {
                web = 8443;
                inform = 8080;
                portalredir = 8880;
                portalredir-tls = 8843;
                speed-test = 6789;
                stun = {
                  containerPort = 3478;
                  protocol = "UDP";
                };
                discovery = {
                  containerPort = 10001;
                  protocol = "UDP";
                };
              };
              volumeMountsByPath = {
                "/var/lib/unifi/logs" = "logs";
                "/var/lib/unifi/run" = "run";
                "/tmp" = "tmp";
              };
            };
            volumesByName = {
              logs.persistentVolumeClaim.claimName = "logs";
              run.emptyDir = { };
              tmp.emptyDir = { };
            };
          };
        };
      };
    };
  };
}
