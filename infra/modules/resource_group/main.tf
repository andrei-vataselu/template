resource "aws_resourcegroups_group" "this" {
  name        = var.name
  description = var.description

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        for filter in var.tag_filters : {
          Key    = filter.key
          Values = filter.values
        }
      ]
    })
  }

  tags = var.tags
}
