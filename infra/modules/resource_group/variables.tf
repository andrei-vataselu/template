variable "name" {
  description = "Resource group name shown in AWS console"
  type        = string
}

variable "description" {
  description = "Resource group description"
  type        = string
  default     = ""
}

variable "tag_filters" {
  description = "Tag filters used to discover resources for this group"
  type = list(object({
    key    = string
    values = list(string)
  }))
}

variable "tags" {
  description = "Tags applied to the resource group itself"
  type        = map(string)
  default     = {}
}
