variable "project_name" {
  type        = string
  description = "Prefix for the table name."
}

variable "tags" {
  type        = map(string)
  description = "Additional resource tags, merged with the provider's default_tags."
  default     = {}
}
