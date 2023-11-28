scaleway-route-override
=======================

This terraform demo how to override the VPC default route on specific instances to keep public access and still be able to access databases via PN.

requirements:
- Scaleway API key in environment variables:
    - SCW_ACCESS_KEY
    - SCW_SECRET_KEY
    - SCW_DEFAULT_REGION
    - SCW_DEFAULT_ZONE
    - SCW_DEFAULT_ORGANIZATION_ID
    - SCW_DEFAULT_PROJECT_ID
- GNU Make (or do a terraform init + apply manually)
- Terraform
- Scaleway Terraform Provider

usage:
```
make
```

output example:
```
database_access = "psql -h 192.168.0.2 --port 5432 -d terraform -U terraform"
database_password = "********"
gateway_internal_ip = "192.168.0.3"
private_access_to_private_instance = "ssh -J bastion@Y.Y.Y.Y:61000 root@192.168.0.5"
private_access_to_public_instance = "ssh -J bastion@Y.Y.Y.Y:61000 root@192.168.0.4"
public_access_to_public_instance = "http://X.X.X.X"
```

tests:
- Access public instance directly via `public_access_to_public_instance`
- SSH to private instance using `private_access_to_private_instance` and connect to DB using `database_access` and `database_password`
- SSH to public instance using `private_access_to_public_instance` and connect to DB using `database_access` and `database_password`
- Validate routes on public instance using `ip r`. Metric for default route via `gateway_internal_ip` should be 150 (lower than metric for public IP)

note:
We are using routed IP instances to disable NAT private IP on the instances, even on pure private one.
