data "kubectl_file_documents" "gateway_api_crds" {
  content = file("${path.module}/gateway-api/experimental-install.yaml")
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each = data.kubectl_file_documents.gateway_api_crds.manifests

  yaml_body = each.value

  server_side_apply = true
  force_conflicts   = true
  wait              = true
}
