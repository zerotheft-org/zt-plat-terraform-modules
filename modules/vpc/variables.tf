variable "environment" {
  description = "Environment name"
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "Environment must be dev, stage, or prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be valid IPv4 CIDR block."
  }
}

variable "azs" {
  description = "List of availability zones"
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Must specify at least 2 availability zones."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)

  validation {
    condition = (
      length(var.private_subnet_cidrs) == length(var.azs) &&
      length(var.private_subnet_cidrs) == length(var.public_subnet_cidrs)
    )
    error_message = "private_subnet_cidrs length must match azs and public_subnet_cidrs length."
  }

  validation {
    condition     = alltrue([for cidr in var.private_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Each private_subnet_cidrs entry must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)

  validation {
    condition = (
      length(var.public_subnet_cidrs) == length(var.azs) &&
      length(var.public_subnet_cidrs) == length(var.private_subnet_cidrs)
    )
    error_message = "public_subnet_cidrs length must match azs and private_subnet_cidrs length."
  }

  validation {
    condition     = alltrue([for cidr in var.public_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Each public_subnet_cidrs entry must be a valid IPv4 CIDR block."
  }
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnet internet access"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}
