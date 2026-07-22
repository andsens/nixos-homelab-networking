{ inputs, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.homelab.services.unifi;
  stateDir = "/var/lib/unifi";
  jrePackage = pkgs.jdk25_headless;
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/unifi";
    copyToRoot =
      with pkgs;
      [
        unifi
        cacert
      ]
      ++ lib.optionals cfg.debug ccfg.debugTools;
    config.Env = [
      "CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    config.Entrypoint = [
      "${jrePackage}/bin/java"
      "java"
      "--add-opens=java.base/java.lang=ALL-UNNAMED"
      "--add-opens=java.base/java.time=ALL-UNNAMED"
      "--add-opens=java.base/sun.security.util=ALL-UNNAMED"
      "--add-opens=java.base/java.io=ALL-UNNAMED"
      "--add-opens=java.rmi/sun.rmi.transport=ALL-UNNAMED"
      "-jar"
      "${stateDir}/lib/ace.jar"
    ];
    config.Cmd = [ "start" ];
  };
in
{
  options.homelab.services.unifi = {
    enable = lib.mkEnableOption "Unifi Controller";
  };
  imports = [ ];
  config = lib.mkIf cfg.enable {
    homelab.cluster.backup.volumes.unifi.unifi = [ stateDir ];
    kubetree.resources.unifi = {
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
          dataPath = stateDir;
          ingressPort = 8443;
          servicePodSpec = {
            mainContainer = {
              image = "${image.buildArgs.name}:${image.imageTag}";
              portsByName = {
                web = 8443;
                inform = 8080;
                portalRedir = 8880;
                portalRedirTLS = 8843;
                mobileSpeedTest = 6789;
                stun = {
                  containerPort = 3478;
                  protocol = "UDP";
                };
                discovery = {
                  containerPort = 10001;
                  protocol = "UDP";
                };
              };
            };
            volumesByName.config.configMap.name = "config";
          };
        };
      };
    };
  };
}
