{goal}

## Scope

{scope}

## Verification

{verification}

## Provenance

| | |
|---|---|
| Queue entry | `{entry_id}` |
| Session | `{session_id}` |
| Branch | `{branch}` |
| Brief | `{brief_path}` |
| Work order | `{work_order_id}` |
| Close-time re-verification | {reverified} |

<sub>Opened by the Repo OS operator automation layer (Decision t-0057). The
verification list above is read from the brief and from the session's criteria
verdicts at the moment the pull request was opened — it is a record of what the
session claimed, not an assertion by the reviewer. Repo OS tracks this pull
request until it merges; `queue-cli.sh pr refresh {entry_id}` re-reads its
checks.</sub>
