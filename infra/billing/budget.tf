# Cost guardrail for the cloud run. It lives in this stack, not in infra/terraform, so that
# `terraform destroy` of the cluster does not delete it: charges that land after the run
# (or anything left behind) still trigger an email.
#
# Budgets are evaluated a few times a day from billing data that lags by hours, so this is a
# backstop, not a brake. The brakes are in docs/cloud-run.md: the time box, `make cloud-cost`
# during the run and `make cloud-leftovers` after it.
resource "aws_budgets_budget" "run" {
  name         = "${var.name}-${var.budget_scope == "tag" ? "project" : "account"}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "cost_filter" {
    for_each = var.budget_scope == "tag" ? [1] : []
    content {
      name   = "TagKeyValue"
      values = [format("user:project$%s", var.project)]
    }
  }

  # 25/50/100% = 5/10/20 USD actual spend at the default limit.
  dynamic "notification" {
    for_each = [25, 50, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }
}

# Backstop: whole account, no tag filter. Alerts at 80% and 100% actual, and on forecast.
resource "aws_budgets_budget" "account_backstop" {
  count = var.account_backstop_usd == null ? 0 : 1

  name         = "${var.name}-account-backstop-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.account_backstop_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }
}
