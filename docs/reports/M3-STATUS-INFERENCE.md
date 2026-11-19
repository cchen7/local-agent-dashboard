# M3 deterministic status inference

SPEC §10.4 / DEV-002. The engine consumes typed activity signals in file
order and returns a status, a reason, and evidence. It takes the current time
as an input and performs no file access, process inspection, or inference from
message text. Distinct reasons preserve the qualification of inferred approval.

Synthetic tests cover status precedence, resumed activity, normal turn end
versus explicit session end, correlated tool results, approval and idle
boundaries, missing/nonmonotone/future times, and custom thresholds. The full
package suite passed 76 test functions, including 34 status functions and
61 status cases. API/dependency guards passed. Runtime adaptation of agent
events and status badges is a separate integration task.
