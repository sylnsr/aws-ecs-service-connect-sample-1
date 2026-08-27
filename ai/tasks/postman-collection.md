# Postman Collection

(../../CLAUDE.md needs to be read before this file)

In the `postman` dir, we need postman JSON files which can be imported into a Postman Collection in Postman.

The collection is for a set of APIs for a water utility company's customer facing app. This API set allows customers to do the following:

1. Get data (use LI) from a landing page when they are not authenticated.
2. Authenticate and get authorization to access billing and balance data for the number of accounts specified by the `x-account-count` header.
3. List accounts with account status (open/closed)
4. Retrieve read-only address data specific to a selected account.
5. List and update payment methods billing including addresses related to payment methods.
6. Sign up for a customer loyalty program ID (get loyalty ID; set loyalty ID)
7. Get per account payment history (debit and credit list)
8. Close account request (POST request to close account; GET for status to close account which will be "Pending")