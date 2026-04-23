# zt-plat-terraform-modules

ZeroTheft shared Terraform modules and environment configurations.

## Modules

| Module | Path | Description |
|--------|------|-------------|
| `s3` | `modules/s3/` | S3 bucket with standard tagging and encryption |
| `vpc` | `modules/vpc/` | VPC with subnets, NAT, and routing |
| `secret_manager` | `modules/secret_manager/` | AWS Secrets Manager with rotation Lambda |
| `drift` | `modules/drift/` | Schema drift detection Lambda |

## Environments

| Environment | Path | Purpose |
|-------------|------|---------|
| `stage` | `envs/stage/` | Staging environment stacks |
| `prod` | `envs/prod/` | Production environment stacks |
| `dev` | `envs/dev/` | Development environment stacks |

## Usage

```hcl
module "my_bucket" {
  source = "github.com/zerotheft-org/zt-plat-terraform-modules//modules/s3?ref=v1.0.0"
  
  bucket_name = "my-app-bucket"
  # ...
}
```

## Rules
- Domains consume platform modules
- Domains never modify platform code
- All changes must go through PR with `zt-platform` approval
