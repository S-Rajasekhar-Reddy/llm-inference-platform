variable "region" {
  description = "Same region as infra/terraform (where the G/VT quota was granted)."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Same name as infra/terraform; the weights bucket and the read policy are named from it."
  type        = string
  default     = "llm-inference"
}

variable "owner" {
  description = "Value of the owner tag."
  type        = string
}

variable "project" {
  description = "Value of the project tag. The budget only counts costs carrying this tag."
  type        = string
  default     = "llm-inference-platform"
}

variable "budget_limit_usd" {
  description = "Monthly budget for this project. Alerts at 25%, 50% and 100% (5, 10 and 20 USD at the default)."
  type        = number
  default     = 20
}

variable "budget_scope" {
  description = <<-EOT
    "tag": count only costs tagged project=<project>. Needs the project tag activated as a cost
           allocation tag (Billing > Cost allocation tags; only the payer/management account can do it,
           and the key only appears there after a tagged resource has shown up in billing).
    "account": count the whole account. Only useful if nothing else runs in it.
  EOT
  type        = string
  default     = "tag"

  validation {
    condition     = contains(["tag", "account"], var.budget_scope)
    error_message = "budget_scope must be \"tag\" or \"account\"."
  }
}

variable "budget_alert_emails" {
  description = "Email addresses that receive the budget alerts."
  type        = list(string)
}
