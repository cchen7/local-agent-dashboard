# M3 deterministic status inference

SPEC §10.4 / DEV-002. The engine consumes typed activity signals in file
order and returns a status, a reason, and evidence. It takes the current time
as an input and performs no file access, process inspection, or inference from
message text. Distinct reasons preserve the qualification of inferred approval.
Explicit requests for different calls remain independent; resolving one leaves
the other as the reason for waiting. Requests without a call ID keep the separate
resumed-activity behavior. The newest outstanding request supplies the evidence.

Synthetic tests cover status precedence, resumed activity, normal turn end
versus explicit session end, correlated tool results, approval and idle
boundaries, missing/nonmonotone/future times, and custom thresholds. The full
package suite passed 76 test functions, including 34 status functions and
61 status cases. API/dependency guards passed. Runtime adaptation of agent
events and status badges is a separate integration task.

Review follow-up: 77 package tests passed, including 35 status functions. The
new regression runs both approval resolution orders, with and without an
unscoped request.
