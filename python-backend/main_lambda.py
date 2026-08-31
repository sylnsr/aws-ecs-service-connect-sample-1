"""AWS Lambda entrypoint. Serves the loyalty routes only.

Mangum adapts the ASGI app to the Lambda event/response shape, so the same
FastAPI handlers run unchanged in both places. That is the point of README
section 2E: a function stub and an ECS-backed service must be interchangeable
from the caller's perspective.

Fronted by an ALB Lambda target group, not API Gateway -- the ALB is the single
deployment control point (README section 3), and adding API Gateway here would
create a second place where traffic could be routed.
"""

from __future__ import annotations

import os

from mangum import Mangum

from awuca.app import create_app

# Forced to `lambda` rather than read from APP_MODE: this file is only ever the
# function's handler, and a misconfigured environment variable should not be
# able to turn the Lambda into a copy of the ECS service.
app = create_app("lambda")

# The ALB invokes Lambda with an "alb" style event, not an API Gateway one.
handler = Mangum(app, lifespan="off", api_gateway_base_path=os.environ.get("BASE_PATH", "/"))
