"""Route modules, one per domain.

The split is not cosmetic: `loyalty` is the AWS Lambda workload and everything
else is ECS (README section 2A). app.py assembles them differently for each
entrypoint.
"""
