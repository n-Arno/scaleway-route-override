locals {
  subnet = "192.168.0.0/24"
}

resource "scaleway_vpc" "demo" {
  name = "demo-vpc"
}

resource "scaleway_vpc_private_network" "internal" {
  name   = "internal"
  vpc_id = scaleway_vpc.demo.id

  ipv4_subnet {
    subnet = local.subnet
  }
}

resource "scaleway_vpc_public_gateway_ip" "gw_ip" {}

resource "scaleway_vpc_public_gateway" "pgw" {
  name            = "gateway"
  type            = "VPC-GW-S"
  bastion_enabled = true
  bastion_port    = 61000
  ip_id           = scaleway_vpc_public_gateway_ip.gw_ip.id
}

resource "scaleway_vpc_gateway_network" "internal" {
  gateway_id         = scaleway_vpc_public_gateway.pgw.id
  private_network_id = scaleway_vpc_private_network.internal.id
  enable_masquerade  = true
  ipam_config {
    push_default_route = true
  }
}

resource "scaleway_instance_security_group" "http" {
  name                   = "http"
  stateful               = true
  inbound_default_policy = "drop"
  inbound_rule {
    action = "accept"
    port   = 80
  }
}

resource "scaleway_instance_ip" "public" {
  type = "routed_ipv4"
}

resource "scaleway_instance_server" "public" {
  name              = "demo-public"
  image             = "ubuntu_jammy"
  type              = "PLAY2-PICO"
  routed_ip_enabled = true
  ip_id             = scaleway_instance_ip.public.id

  root_volume {
    volume_type           = "b_ssd"
    size_in_gb            = 10
    delete_on_termination = true
  }

  private_network {
    pn_id = scaleway_vpc_private_network.internal.id
  }

  # This instance should use the public access as default instead of the PGW.
  # We override the route metric to put it lower than the default via ens2.
  # We add both ens4 and ens5 to handle the naming of the nic changing by
  # ubuntu version and offer.
  # The 99 in the name of the file is important, it will override the "previous"
  # files in the netplan folder (created by cloud-init and scaleway-ecosystem).
  user_data = {
    cloud-init = <<-EOT
    #cloud-config
    package_update: true
    packages:
    - postgresql-client
    - nginx
    write_files:
    - path: /etc/netplan/99-overrides.yaml
      permissions: '0644'
      content: |
        network:
          version: 2
          ethernets:
            ens4:
              dhcp4-overrides:
                route-metric: 150
            ens5:
              dhcp4-overrides:
                route-metric: 150
    runcmd:
    - echo "Hello, i'm $(hostname)!" > /var/www/html/index.nginx-debian.html
    - systemctl enable --now nginx
    EOT
  }

  security_group_id = scaleway_instance_security_group.http.id

  depends_on = [scaleway_vpc_gateway_network.internal]
}

resource "scaleway_instance_security_group" "drop_all" {
  # Security group only apply to public access, but we'll close everything to be sure
  name                    = "private"
  inbound_default_policy  = "drop"
  outbound_default_policy = "drop"
}

resource "scaleway_instance_server" "private" {
  name              = "demo-private"
  image             = "ubuntu_jammy"
  type              = "PLAY2-PICO"
  routed_ip_enabled = true

  root_volume {
    volume_type           = "b_ssd"
    size_in_gb            = 10
    delete_on_termination = true
  }

  private_network {
    pn_id = scaleway_vpc_private_network.internal.id
  }

  user_data = {
    cloud-init = <<-EOT
    #cloud-config
    package_update: true
    packages:
    - postgresql-client
    EOT
  }

  security_group_id = scaleway_instance_security_group.drop_all.id

  depends_on = [scaleway_vpc_gateway_network.internal]
}

# Generate a random password for database user
resource "random_password" "db" {
  length           = 10
  min_numeric      = 1
  min_upper        = 1
  min_lower        = 1
  min_special      = 1
  override_special = "+-_="
}

resource "scaleway_rdb_instance" "pgsql" {
  name              = "demo-db"
  node_type         = "DB-DEV-S"
  engine            = "PostgreSQL-15"
  is_ha_cluster     = false
  disable_backup    = true
  user_name         = "terraform"
  password          = random_password.db.result
  volume_type       = "bssd"
  volume_size_in_gb = 10
  private_network {
    pn_id = scaleway_vpc_private_network.internal.id
  }
  depends_on = [random_password.db]
}

resource "scaleway_rdb_acl" "private_only" {
  # default acl for DB is 0.0.0.0/0. 
  # We can't delete it via terraform but we can replace it
  # with the local subnet (even if ACL is not used with PN)
  # to disable access via internet.
  instance_id = scaleway_rdb_instance.pgsql.id
  acl_rules {
    ip          = local.subnet
    description = "Private network access only"
  }
}

resource "scaleway_rdb_database" "demo" {
  instance_id = scaleway_rdb_instance.pgsql.id
  name        = "terraform"
}

resource "scaleway_rdb_privilege" "grant" {
  instance_id   = scaleway_rdb_instance.pgsql.id
  user_name     = "terraform"
  database_name = "terraform"
  permission    = "all"
  depends_on    = [scaleway_rdb_database.demo]
}

# HTTP access to the public instance via it's public ip
output "public_access_to_public_instance" {
  value = format("http://%s", scaleway_instance_ip.public.address)
}

data "scaleway_ipam_ip" "public_internal_ip" {
  mac_address = scaleway_instance_server.public.private_network.0.mac_address
  type        = "ipv4"
}

# SSH access to public instance via the PGW
output "private_access_to_public_instance" {
  value = format("ssh -J bastion@%s:61000 root@%s", scaleway_vpc_public_gateway_ip.gw_ip.address, data.scaleway_ipam_ip.public_internal_ip.address)
}

data "scaleway_ipam_ip" "private_internal_ip" {
  mac_address = scaleway_instance_server.private.private_network.0.mac_address
  type        = "ipv4"
}

# SSH access to private instance via the PGW
output "private_access_to_private_instance" {
  value = format("ssh -J bastion@%s:61000 root@%s", scaleway_vpc_public_gateway_ip.gw_ip.address, data.scaleway_ipam_ip.private_internal_ip.address)
}

# nonsensitive function is needed to force display of sensitive value
output "database_password" {
  value = nonsensitive(random_password.db.result)
}

data "scaleway_ipam_ip" "private_database_ip" {
  resource {
    id   = scaleway_rdb_instance.pgsql.id
    type = "rdb_instance"
  }
  type = "ipv4"
}

# command to execute from instances to access DB via PN
output "database_access" {
  value = format("psql -h %s --port 5432 -d terraform -U terraform", data.scaleway_ipam_ip.private_database_ip.address)
}

# Queried to demo accessing this IP in configuration, for DNS for example
# Can be added in a depends_on parameter if needed to build other resources
data "scaleway_ipam_ip" "private_gateway_ip" {
  resource {
    id   = scaleway_vpc_gateway_network.internal.id
    type = "vpc_gateway_network"
  }
  type = "ipv4"
}

output "gateway_internal_ip" {
  value = data.scaleway_ipam_ip.private_gateway_ip.address
}
