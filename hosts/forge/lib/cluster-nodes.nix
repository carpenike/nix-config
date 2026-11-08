# The cluster sleds' node addresses (carpenike/k8s-gitops talos/topf.yaml).
# Cilium masquerades pod egress to these, so they are the TCP peers Forge's
# Caddy sees for anything the cluster sends: alerts to Alertmanager, and the
# cluster Grafana's Prometheus and Loki reads.
[
  "10.20.10.20/32"
  "10.20.10.21/32"
  "10.20.10.22/32"
  "10.20.10.23/32"
]
