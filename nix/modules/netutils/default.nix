{ self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  flakePkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  options.homelab.netutils = {
    enable = lib.mkEnableOption "the netutils debugging container";
  };
  config = {
    services.k3s.manifests.netutils.enable = config.homelab.netutils.enable;
    kubetree.resources.netutils = {
      netutils-to-all = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumNetworkPolicy";
        metadata = {
          namespace = "default";
          name = "netutils-to-all";
        };
        spec.endpointSelector.matchLabels."app.kubernetes.io/name" = "netutils";
        spec.ingress = [ { fromEntities = [ "all" ]; } ];
        spec.egress = [ { toEntities = [ "all" ]; } ];
      };
      all-from-netutils = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "all-from-netutils";
        spec.endpointSelector.matchLabels = { };
        spec.ingress = [
          {
            fromEndpoints = [
              {
                matchLabels = {
                  "k8s:io.kubernetes.pod.namespace" = "default";
                  "app.kubernetes.io/name" = "netutils";
                };
              }
            ];
          }
        ];
      };
      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          namespace = "default";
          name = "netutils";
          labels."app.kubernetes.io/name" = "netutils";
        };
        spec = {
          selector.matchLabels."app.kubernetes.io/name" = "netutils";
          template.metadata.labels."app.kubernetes.io/name" = "netutils";
          template.spec.containersByName.netutils = {
            image = "${flakePkgs.container-utils.buildArgs.name}:${flakePkgs.container-utils.imageTag}";
            imagePullPolicy = "Never";
            command = [
              "iperf2"
              "-s"
            ];
          };
        };
      };
    };
  };
}
