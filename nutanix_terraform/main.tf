# resource "nutanix_image" "image" {
#   name        = "Arch Linux"
#   description = "Arch-Linux-x86_64-basic-20210401.18564"
#   source_uri  = var.image_uri
# }

resource "nutanix_virtual_machine" "dev" {
  name                 = "DEV - VM"
  cluster_uuid         = data.nutanix_cluster.cluster.id
  num_vcpus_per_socket = "2"
  num_sockets          = "1"
  memory_size_mib      = 1024
  count                = 2

  categories {
    name  = "Environment"
    value = "Dev"
  }

  disk_list {
    data_source_reference = {
      kind = "image"
      uuid = data.nutanix_image.image.id
    }
  }

  disk_list {
    disk_size_bytes = 10 * 1024 * 1024 * 1024
    device_properties {
      device_type = "DISK"
      disk_address = {
        "adapter_type" = "SCSI"
        "device_index" = "1"
      }
    }
  }
  nic_list {
    subnet_uuid = data.nutanix_subnet.subnet.id
  }
}

# resource "nutanix_network_security_rule" "isolation" {
#     name        = "example-isolation-rule"
#     description = "Isolation Rule Example"

#     isolation_rule_action = "MONITOR"

#     isolation_rule_first_entity_filter_kind_list = ["vm"]
#     isolation_rule_first_entity_filter_type      = "CATEGORIES_MATCH_ALL"
#     isolation_rule_first_entity_filter_params {
#         name   = "Environment"
#         values = ["Dev"]
#     }

#     isolation_rule_second_entity_filter_kind_list = ["vm"]
#     isolation_rule_second_entity_filter_type      = "CATEGORIES_MATCH_ALL"
#     isolation_rule_second_entity_filter_params {
#         name   = "Environment"
#         values = ["Production"]
#     }
# }
