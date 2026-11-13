locals {
  install_images = {
    for k, v in var.nodes : k => v.schematic != null ? data.talos_image_factory_urls.schematic[v.schematic].urls.installer : v.install_image
  }
  schematics = {
    for s in toset([for v in var.nodes : v.schematic if v.schematic != null]) : s => file("${path.module}/schematics/${s}.yaml")
  }
}

resource "talos_image_factory_schematic" "schematic" {
  for_each = local.schematics

  schematic = each.value
}

data "talos_image_factory_urls" "schematic" {
  for_each = local.schematics

  schematic_id  = talos_image_factory_schematic.schematic[each.key].id
  talos_version = var.talos_image_version
  sbc           = yamldecode(each.value).overlay.name
  architecture  = "arm64"
}
