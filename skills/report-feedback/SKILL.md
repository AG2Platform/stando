# report-feedback

Voice-callable feedback capture. Sends a structured record to the cloud
`/api/feedback` endpoint so triage happens on `/admin/feedback` rather
than in a Discord DM that everyone forgets about.

## Tool

`report_feedback(kind, title, body?, severity?, withScreen?)`:

| Arg        | Type                                                 | Default   |
|------------|------------------------------------------------------|-----------|
| kind       | `bug` \| `feature` \| `other`                        | required  |
| title      | short summary                                        | required  |
| body       | longer body                                          | optional  |
| severity   | `low` \| `medium` \| `high` \| `critical`            | `medium`  |
| withScreen | capture a screenshot path into context.last_screen   | `false`   |

Captures `app_version` automatically from `package.json`. When `withScreen`
is true, hits `localhost:7845/capture` (the existing screen-capture
server) and includes the resulting path in the context payload — handy
when reporting a UI bug. Bytes stay local; only the path is sent.

## Closing the loop

Admin marks the record `shipped` on `/admin/feedback`; future work fires
a Discord DM back to the user ("your bug X is fixed in v0.X.Y"). Hook
isn't wired yet — track on the open feedback row's status field.
