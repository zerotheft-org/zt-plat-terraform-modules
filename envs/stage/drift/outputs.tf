output "config_rule_names" {
  description = "Config rules monitoring for drift"
  value       = module.drift.config_rule_names
}

output "config_recorder_name" {
  description = "Config recorder name"
  value       = module.drift.config_recorder_name
}
