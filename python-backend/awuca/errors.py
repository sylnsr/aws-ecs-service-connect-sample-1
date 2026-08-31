"""Error responses.

Every error in the collection has the same body:

    {"error": "<slug>", "message": "<human readable>"}

FastAPI's defaults do not: HTTPException produces {"detail": ...} and a
validation failure produces a 422 with a list. Both would fail the generated
contract suite, which checks the shape of the 400/401/404 examples as strictly
as the success ones. So all three are normalised here.
"""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


class ApiError(Exception):
    """Raise this rather than HTTPException, so the slug is explicit at the
    call site instead of being inferred from a status code."""

    def __init__(self, status_code: int, error: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error = error
        self.message = message


def unauthorized(message: str = "Missing or invalid bearer token") -> ApiError:
    return ApiError(401, "unauthorized", message)


def not_found(message: str) -> ApiError:
    return ApiError(404, "not_found", message)


def bad_request(message: str) -> ApiError:
    return ApiError(400, "bad_request", message)


def _body(error: str, message: str) -> dict[str, str]:
    return {"error": error, "message": message}


# Slugs for the statuses Starlette raises on our behalf -- 405 on a method that
# does not exist for a matched path, 404 on an unmatched path.
_STATUS_SLUGS = {
    400: "bad_request",
    401: "unauthorized",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
    500: "internal_error",
}


def register_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        headers = {"WWW-Authenticate": "Bearer"} if exc.status_code == 401 else None
        return JSONResponse(
            status_code=exc.status_code,
            content=_body(exc.error, exc.message),
            headers=headers,
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        slug = _STATUS_SLUGS.get(exc.status_code, "error")
        detail = exc.detail if isinstance(exc.detail, str) else slug
        return JSONResponse(status_code=exc.status_code, content=_body(slug, detail))

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        # Collapse pydantic's list into one sentence. The collection documents a
        # flat error body and clients should not have to parse two formats.
        first = exc.errors()[0] if exc.errors() else {}
        location = ".".join(str(part) for part in first.get("loc", ()) if part != "body")
        reason = first.get("msg", "invalid request")
        message = f"{location}: {reason}" if location else reason
        return JSONResponse(status_code=422, content=_body("unprocessable_entity", message))
