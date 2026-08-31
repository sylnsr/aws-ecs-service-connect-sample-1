"""DynamoDB store for ECS and Lambda.

One item per customer:

    customerId (S, partition key)   the only key
    document   (S)                  the whole customer document, JSON encoded

JSON in a single string attribute rather than a mapped DynamoDB item, on
purpose. The document holds floats (balances, transaction amounts) and
DynamoDB's Number type maps to Decimal in boto3, so a mapped item would round
trip 42.5 as Decimal('42.5') and then fail to serialise back to JSON without a
custom encoder on every response. Storing an opaque JSON blob keeps the two
adapters byte-for-byte interchangeable, which is the property the contract
suite depends on.

The cost is that the table cannot be queried by anything except customerId.
For a demo whose access pattern is "fetch one customer, write one customer",
that costs nothing.

No table creation here. Terraform owns the table (stub-tf/dynamodb.tf), the
same way it owns every other piece of machinery -- see the ownership boundary
in docs/release-process.md section 5.
"""

from __future__ import annotations

import json
from typing import Any


class DynamoDbStore:
    def __init__(self, table_name: str, region: str) -> None:
        # Imported lazily so that a local `STORE=yaml` run does not need boto3
        # installed or any AWS credentials present.
        import boto3

        self._table_name = table_name
        self._table = boto3.resource("dynamodb", region_name=region).Table(table_name)

    def get(self, customer_id: str) -> dict[str, Any] | None:
        response = self._table.get_item(
            Key={"customerId": customer_id},
            # Strongly consistent: a token request writes the seed and the very
            # next request reads it back. Under the default eventually
            # consistent read that lookup can miss, and the caller would get a
            # spurious 401/404 on their first authenticated call.
            ConsistentRead=True,
        )
        item = response.get("Item")
        if item is None:
            return None
        return json.loads(item["document"])

    def put(self, customer_id: str, document: dict[str, Any]) -> None:
        self._table.put_item(
            Item={
                "customerId": customer_id,
                "document": json.dumps(document, separators=(",", ":")),
            }
        )

    def describe(self) -> str:
        return f"dynamodb:{self._table_name}"
