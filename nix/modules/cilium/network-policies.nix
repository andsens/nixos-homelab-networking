{ ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.cilium.network-policies;
  enable = config.homelab.cilium.enable && cfg.enable;
in
{
  options.homelab.cilium.network-policies = {
    enable = lib.mkEnableOption "Cilium clusterwide network policies";
  };
  config = {
    services.k3s.manifests.networkpolicies.enable = enable;
    kubetree.resources.networkpolicies = {
      deny-all = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "deny-all";
        spec.endpointSelector = { };
        spec.ingress = [ { fromEntities = [ ]; } ];
        spec.egress = [ { toEntities = [ ]; } ];
      };
      pod-to-coredns = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-to-coredns";
        spec.endpointSelector.matchLabels = { };
        spec.egress = [
          {
            toEndpoints = [
              {
                matchLabels = {
                  "k8s:io.kubernetes.pod.namespace" = "kube-system";
                  k8s-app = "kube-dns";
                };
              }
            ];
            toPortsFlattened = [
              {
                port = "53";
                protocol = "UDP";
              }
              {
                port = "53";
                protocol = "TCP";
              }
            ];
          }
        ];
      };
      coredns-from-pod = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumNetworkPolicy";
        metadata.namespace = "kube-system";
        metadata.name = "coredns-from-pod";
        spec.endpointSelector.matchLabels.k8s-app = "kube-dns";
        spec.ingress = [
          {
            fromEntities = [
              "host"
              "remote-node"
              "kube-apiserver"
              "cluster"
            ];
            toPortsFlattened = [
              {
                port = "53";
                protocol = "TCP";
              }
              {
                port = "53";
                protocol = "UDP";
              }
            ];
          }
        ];
        spec.egress = [
          {
            toEntities = [ "world" ];
            toPortsFlattened = [
              {
                port = "53";
                protocol = "UDP";
              }
              {
                port = "53";
                protocol = "TCP";
              }
            ];
          }
          { toEntities = [ "kube-apiserver" ]; }
        ];
      };
      pod-to-apiserver = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-to-apiserver";
        spec.endpointSelector.matchLabels."cluster.local/apiserver-egress" = "allow";
        spec.egress = [ { toEntities = [ "kube-apiserver" ]; } ];
      };
      pod-from-apiserver = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-to-apiserver";
        spec.endpointSelector.matchLabels."cluster.local/apiserver-ingress" = "allow";
        spec.ingress = [ { fromEntities = [ "kube-apiserver" ]; } ];
      };
      pod-to-internet = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-to-internet";
        spec.endpointSelector.matchLabels."cluster.local/internet-egress" = "allow";
        spec.egress = [ { toEntities = [ "world" ]; } ];
      };
      pod-to-gateway = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-to-gateway";
        spec.endpointSelector.matchLabels."cluster.local/gateway-egress" = "allow";
        spec.egress = [ { toEntities = [ "ingress" ]; } ];
      };
      gateway-from-pod = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "gateway-from-pod";
        spec.endpointSelector.matchExpressions = [
          {
            key = "reserved:ingress";
            operator = "Exists";
          }
        ];
        spec.ingress = [
          {
            fromEndpoints = [
              {
                matchExpressions = [
                  {
                    key = "k8s:io.kubernetes.pod.namespace";
                    operator = "Exists";
                  }
                  {
                    key = "cluster.local/gateway-egress";
                    operator = "In";
                    values = [ "allow" ];
                  }
                ];
              }
            ];
          }
        ];
      };
      gateway-to-pod = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "gateway-to-pod";
        spec.endpointSelector.matchExpressions = [
          {
            key = "reserved:ingress";
            operator = "Exists";
          }
        ];
        spec.egress = [
          {
            toEndpoints = [
              {
                matchExpressions = [
                  {
                    key = "k8s:io.kubernetes.pod.namespace";
                    operator = "Exists";
                  }
                  {
                    key = "cluster.local/gateway-ingress";
                    operator = "In";
                    values = [ "allow" ];
                  }
                ];
              }
            ];
          }
        ];
      };
      pod-from-gateway = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-from-gateway";
        spec.endpointSelector.matchLabels."cluster.local/gateway-ingress" = "allow";
        spec.ingress = [ { fromEntities = [ "ingress" ]; } ];
      };
      pod-to-cluster = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-to-cluster";
        spec.endpointSelector.matchLabels."cluster.local/cluster-egress" = "allow";
        spec.egress = [ { toEntities = [ "cluster" ]; } ];
      };
      cluster-from-pod = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "cluster-from-pod";
        spec.endpointSelector = { };
        spec.ingress = [
          {
            fromEndpoints = [
              {
                matchExpressions = [
                  {
                    "key" = "k8s:io.kubernetes.pod.namespace";
                    "operator" = "Exists";
                  }
                  {
                    key = "cluster.local/cluster-egress";
                    operator = "In";
                    values = [ "allow" ];
                  }
                ];
              }
            ];
          }
        ];
      };
      pod-from-local-lan = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-from-local-lan";
        spec.endpointSelector.matchLabels."cluster.local/local-lan-ingress" = "allow";
        spec.ingress = [ { fromCIDRSet = [ { cidrGroupRef = "local-lan"; } ]; } ];
      };
      pod-to-local-lan = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumClusterwideNetworkPolicy";
        metadata.name = "pod-to-local-lan";
        spec.endpointSelector.matchLabels."cluster.local/local-lan-egress" = "allow";
        spec.ingress = [ { fromCIDRSet = [ { cidrGroupRef = "local-lan"; } ]; } ];
      };
    };
  };
}
