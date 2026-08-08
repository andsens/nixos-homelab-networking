{ inputs, ... }:
{ lib, config, ... }:
let
  cfg = config.kubetree.cilium;
  transform = inputs.kubetree.lib.transform;
  cilium = import ./kubetree-transformers.nix { inherit lib transform; };
in
{
  options.kubetree.cilium = {
    enable = lib.mkEnableOption "Cilium CRD transformers";
  };
  config = {
    kubetree.transformers = lib.mkIf cfg.enable {

      "cluster.local" = {
        ServiceNetpols._transformers = [
          cilium.transformServiceNetpols
          transform.transformResource
          transform.flattenResourceList
        ];
      };
      "cilium.io" = {
        CiliumClusterwideNetworkPolicy.spec = {
          ingress."[]"._transformers = [ cilium.transformToPortsFlattened ];
          egress."[]"._transformers = [ cilium.transformToPortsFlattened ];
        };
        CiliumNetworkPolicy.spec = {
          ingress."[]"._transformers = [ cilium.transformToPortsFlattened ];
          egress."[]"._transformers = [ cilium.transformToPortsFlattened ];
        };
      };
    };
  };
}
