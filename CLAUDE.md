# Claude

(README.md should be read as well)

## Rules

- This repo must remain generic and unrelated to any legal entity other than "ACME Water Utility"
- The repo is for a fictional app named "ACME Water Utility Customer App" or "AWUCA"
- Read the README.md file
- Always output a clear confirmation message (e.g., "Task complete" or "Done") when finished executing commands or making code changes.
- Never leave a task hanging without a final summary status.
- Always respond to the user in natural language and formatted Markdown.
- Keep explanations concise, clear, and direct.

## HITL+

User may direct that you use `HITL+` in which case whenever commands need to be executed OUTSIDE your container or against infrastructure you can't reach, create a script at `ai/work/ask.sh` with those commands. For my review, notify me when that file has been edited by you. For your review, have the script also pipe out all the answers you're seeking, to `ai/work/answer.md`. For commands which run in your own container with your own tooling, we don't need to follow this custom flow. When I've run the `ask.sh` script, I will inform you with "done". You should not have more than 500 lines of code in `ai/work/ask.sh`. If you're ever unsure whether a command is actually reachable from your own sandbox instead of needing this flow, ask rather than assuming either way - your own network/tool access can change between sessions. To access the containers this app, make sure they run in the same network and use HITL+ with the `podman network connect` command to join your `claude-aws-ecs-service-connect-sample-1` container to that network.

## Security
- Script permissions MUST only ever be `0700`. If you encounter a script in a repo (workspace) that does not have these permissions, ask to fix it.

## Ansible, Terraform and other tools you don't have

You should use HITL+ when you need a human operator to run a playbook; Terraform etc.

## Acronyms

- LI - Lorem ipsum
