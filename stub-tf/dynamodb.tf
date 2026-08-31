# Customer state for the deployed app.
#
# WHY A TABLE AND NOT A FILE. Locally the backend keeps everything in a YAML
# file, which is fine for a single process on a laptop. In this topology it
# would be wrong for three independent reasons:
#
#   1. Blue and green run SIMULTANEOUSLY. That is the premise of the whole
#      release process -- the standby pool is live and being validated while
#      the active pool serves customers. A file inside a task gives each pool
#      its own divergent copy of the world, so a tester's write on the standby
#      pool is invisible on the active one and vanishes at the next deployment.
#      Whatever holds the state has to sit outside both pools.
#   2. The estate spans ECS AND LAMBDA. Loyalty enrolment is written by the
#      function and read by the tasks. Two compute models cannot share a
#      container filesystem.
#   3. ECS tasks are cattle. Scale-out, task replacement and every deployment
#      destroy local disk.
#
# EFS would survive (3) but buys a POSIX filesystem nobody needs, plus mount
# targets and another failure mode. RDS would be the wrong shape: no relational
# query is ever issued here, and it puts a cluster and a password rotation in
# front of a demo. The access pattern is literally "fetch this customer's
# document by key", which is what this is for.

resource "aws_dynamodb_table" "customers" {
  name = "${local.name}-customers"

  # On-demand. An idle demo costs nothing, and there is no traffic shape to
  # provision capacity against.
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "customerId"

  attribute {
    name = "customerId"
    type = "S"
  }

  server_side_encryption {
    # AWS-owned key. A CMK would add cost and key policy management for demo
    # data that is entirely lorem ipsum.
    enabled = false
  }

  point_in_time_recovery {
    enabled = var.environment == "production"
  }

  # A blue/green promotion is not a data migration -- both pools read and write
  # this same table throughout. Deleting it by accident would take the demo
  # with it, so production is protected.
  # (`lifecycle { prevent_destroy }` would be stronger, but it cannot take a
  # variable, so it would block `terraform destroy` in dev too.)
  deletion_protection_enabled = var.environment == "production"
}
