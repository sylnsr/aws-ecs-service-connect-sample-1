# Postman Collection

(../../CLAUDE.md needs to be read before this file, if not read already)

In the `postman` dir, we need postman JSON files which can be imported into a Postman Collection in Postman.

## Purpose
The collection is for a set of APIs for a water utility company's customer facing app. This API set allows customers to do the following:

1. Get data (use LI) from a landing page when they are not authenticated.
2. Authenticate and get authorization to access billing and balance data for the number of accounts specified by the `x-account-count` header.
3. List accounts with account status (open/closed)
4. Retrieve read-only address data specific to a selected account.
5. List and update payment methods billing including addresses related to payment methods.
6. Sign up for a customer loyalty program ID (get loyalty ID; set loyalty ID)
7. Get per account payment history (debit and credit list)
8. Close account request (POST request to close account; GET for status to close account which will be "Pending")

## Task: Backend app
Create / update the Postman Collection to fulfill this purpose. Then create a Python based app in the `python-backend` dir, based on the Postman Collection. This Python app must be launchable locally and also be ECS deployable, thus meeting the requirement to run the app locally or in AWS. Locally, the app can store data in a YAML file since this project is just an architecture and capability demo. When deployed to ECS where would it be idiomatic to store the data, for this demo app?

Include a README.md file for user instructions and MEMORY.md for Claude to reference to keep this app maintained.

## Task: Frontend app
Create / update the front-end app for this, in the `vue-frontend` dir, which uses the Vue framework and connects to the Python backend locally, or can be deployed to CloudFront, to connect to the ECS deployed Python backend, thus meeting the requirement to run the app locally or in AWS.

## Task: Testing Tool
Create / update an implementation of Playwright to test the **Prism container instance** (no Node install) running the Postman Collection as a baseline for mock based testing. The same Playwright implementation should then also run against the Python implementation to ensure that the Python based ECS deployable app is functional before it gets deployed to ECS.

Include a README.md file for user instructions and MEMORY.md for Claude to reference to keep this app maintained.

## Result

The result of having this setup of the frontend and backend and app, and the test harness, is to demonstrate to an engineer that:

1. a Prism container can be launched for mock testing based on a Postman Collection
2. a Playwright test pattern can be created based on the Postman Collection and run in the Prism container to establish a baseline test for Playwright testing.
3. the Playwright tests can also be used to test the app running locally or in AWS
4. we can make an incremental change to the Postman Collection, rerun this task then once again meet objectives 1 through 4, thusly establishing a simple incremental development cycle, with a Postman Collection as the basis.

The accuracy and implementation of data specifics of the app is not really of concern because we're demonstrating the development **PARADIGM** not so much the app itself.

## Side Notes

- The target hosts for "local" parts of the stack are Debian and Mac
- We need to containerize everything we run locally to keep artifact clean-up as simple as removing a continer image
